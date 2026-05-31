#!/usr/bin/env bash
set -euo pipefail

# hms.sh - Hermes Agent 全能安装/管理助手
# 参考 ocm.sh 的交互式菜单风格，为 Hermes Agent 提供安装、配置、Gateway、Telegram、模型、工具、技能、Cron、更新/卸载等常用管理功能。

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
CONFIG="$HERMES_HOME/config.yaml"
ENV_FILE="$HERMES_HOME/.env"
LOG_DIR="$HERMES_HOME/logs"
LOG_FILE="$LOG_DIR/gateway.log"
BACKUP_DIR="$HERMES_HOME/backups"
SCRIPT_NAME="hms"

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

pause(){ read -r -p "回车继续..." _ || true; }
need_cmd(){ command -v "$1" >/dev/null 2>&1; }
cmd_path(){ command -v "$1" 2>/dev/null || true; }
quiet_run(){ "$@" >/dev/null 2>&1; }
safe_clear(){ if [ -t 1 ] && [ -n "${TERM:-}" ]; then clear || true; fi; }
os_name(){ uname -s 2>/dev/null || echo unknown; }
is_macos(){ [[ "$(os_name)" == "Darwin" ]]; }
is_linux(){ [[ "$(os_name)" == "Linux" ]]; }
has_systemd(){ is_linux && need_cmd systemctl && systemctl list-unit-files >/dev/null 2>&1; }
has_user_systemd(){ is_linux && need_cmd systemctl && systemctl --user list-unit-files >/dev/null 2>&1; }
has_launchctl(){ is_macos && need_cmd launchctl; }


ensure_dirs(){ mkdir -p "$HERMES_HOME" "$BACKUP_DIR" "$LOG_DIR"; }

run_sudo(){
 if [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then
  "$@"
 elif need_cmd sudo; then
  sudo "$@"
 else
  echo "❌ 需要 root 权限或 sudo: $*"
  return 1
 fi
}

resolve_script_path(){
 local src dir base
 src="${BASH_SOURCE[0]:-$0}"
 if need_cmd realpath; then realpath "$src" 2>/dev/null && return 0; fi
 # GNU readlink has -f; macOS/BSD readlink does not. Try it only as an optimization.
 if need_cmd readlink; then readlink -f "$src" 2>/dev/null && return 0; fi
 case "$src" in
  */*) dir=${src%/*}; base=${src##*/} ;;
  *) dir=.; base=$src ;;
 esac
 (cd "$dir" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$base") || printf '%s\n' "$src"
}

choose_bin_dir(){
 if is_macos && [ -d "/opt/homebrew/bin" ]; then
  echo "/opt/homebrew/bin"
 elif [ -d "/usr/local/bin" ]; then
  echo "/usr/local/bin"
 else
  echo "$HOME/.local/bin"
 fi
}

install_hms_command(){
 local target script_path dir
 script_path=$(resolve_script_path)
 target="$(choose_bin_dir)/$SCRIPT_NAME"
 [ -f "$script_path" ] || return 0
 if [ "$script_path" = "$target" ]; then
  return 0
 fi
 dir=$(dirname "$target")
 if mkdir -p "$dir" 2>/dev/null && cat > "$target" 2>/dev/null <<EOF
#!/usr/bin/env bash
exec bash "$script_path" "\$@"
EOF
 then
  chmod +x "$target" 2>/dev/null || true
  return 0
 fi
 if need_cmd sudo; then
  sudo mkdir -p "$dir" >/dev/null 2>&1 || true
  sudo tee "$target" >/dev/null 2>&1 <<EOF
#!/usr/bin/env bash
exec bash "$script_path" "\$@"
EOF
  sudo chmod +x "$target" 2>/dev/null || true
 fi
}

check_dep(){
 local missing=()
 for c in curl python3; do need_cmd "$c" || missing+=("$c"); done
 [ ${#missing[@]} -eq 0 ] && return 0
 echo "⚙️ 正在安装基础依赖: ${missing[*]}"
 if is_macos; then
  need_cmd brew || { echo "❌ Mac 缺少 Homebrew，请先安装: https://brew.sh/"; return 1; }
  for c in "${missing[@]}"; do
   case "$c" in python3) brew install python >/dev/null || true ;; *) brew install "$c" >/dev/null || true ;; esac
  done
 elif need_cmd apt-get; then
  run_sudo apt-get update -y >/dev/null
  run_sudo apt-get install -y curl python3 python3-venv python3-pip >/dev/null
 elif need_cmd dnf; then
  run_sudo dnf install -y curl python3 python3-pip >/dev/null
 elif need_cmd yum; then
  run_sudo yum install -y curl python3 python3-pip >/dev/null
 elif need_cmd pacman; then
  run_sudo pacman -Sy --noconfirm --needed curl python python-pip >/dev/null
 elif need_cmd apk; then
  run_sudo apk add --no-cache curl python3 py3-pip >/dev/null
 elif need_cmd zypper; then
  run_sudo zypper --non-interactive install curl python3 python3-pip >/dev/null
 else
  echo "❌ 无法自动安装依赖，请手动安装: ${missing[*]}"
  return 1
 fi
}

hermes_bin(){ cmd_path hermes; }
hermes_exists(){ need_cmd hermes; }

backup_file(){
 local f="$1" base ts old_backups
 [ -f "$f" ] || return 0
 ensure_dirs
 base=$(basename "$f")
 ts="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
 cp "$f" "$BACKUP_DIR/$base.$ts.bak"
 old_backups=$(find "$BACKUP_DIR" -type f -name "$base.*.bak" -print 2>/dev/null | sort -r | tail -n +16 || true)
 if [ -n "$old_backups" ]; then
  printf '%s\n' "$old_backups" | while IFS= read -r old; do [ -n "$old" ] && rm -f "$old"; done
 fi
}

backup_config(){ backup_file "$CONFIG"; backup_file "$ENV_FILE"; }

HMS_CONFIG_BATCH=0
config_batch_start(){ backup_file "$CONFIG"; HMS_CONFIG_BATCH=1; }
config_batch_end(){ HMS_CONFIG_BATCH=0; }

check_hermes(){
 if ! hermes_exists; then
  echo -e "\n❌ 未检测到 hermes 命令！请先选择 [1] 安装 Hermes。"
  pause
  return 1
 fi
 return 0
}

hermes_version(){ hermes --version 2>/dev/null | head -n1 || echo "unknown"; }

print_status(){
 echo -e "\n--- Hermes 状态 ---"
 if hermes_exists; then
  echo "命令: $(cmd_path hermes)"
  echo "版本: $(hermes_version)"
 else
  echo "命令: 未安装"
 fi
 echo "平台: $(os_name) $(uname -m 2>/dev/null || true)"
 echo "HERMES_HOME: $HERMES_HOME"
 echo "配置文件: $CONFIG $([ -f "$CONFIG" ] && echo '(存在)' || echo '(不存在)')"
 echo "环境文件: $ENV_FILE $([ -f "$ENV_FILE" ] && echo '(存在)' || echo '(不存在)')"
 echo "------------------------------------------------"
 if hermes_exists; then
  hermes status --all 2>/dev/null || hermes doctor 2>/dev/null || true
 fi
}

install_hermes(){
 echo -e "\n🚀 开始安装 Hermes Agent..."
 check_dep
 ensure_dirs
 if hermes_exists; then
  echo "✅ 检测到 Hermes 已安装: $(cmd_path hermes)"
  echo "版本: $(hermes_version)"
 else
  echo "⚙️ 正在执行官方安装脚本..."
  curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
  hash -r
  hermes_exists || { echo "❌ 安装后仍未检测到 hermes 命令，请检查 PATH。"; pause; return 1; }
  echo "✅ Hermes 安装完成: $(cmd_path hermes)"
 fi
 install_hms_command || true
 echo "⚙️ 正在检查配置..."
 hermes config check 2>/dev/null || true
 read -r -p "是否运行 Hermes 交互式 setup 向导？(y/N): " ans
 if [[ "$ans" =~ ^[Yy]$ ]]; then hermes setup || true; fi
 read -r -p "是否安装 Gateway 后台服务？(y/N): " gw
 if [[ "$gw" =~ ^[Yy]$ ]]; then install_gateway_service; fi
 echo -e "${GREEN}✅ 安装流程完成。以后可直接输入 ${YELLOW}hms${GREEN} 启动本脚本。${RESET}"
 pause
}

update_hermes(){
 echo -e "\n🔄 正在升级 Hermes Agent..."
 check_hermes || return 1
 local before after
 before=$(hermes_version)
 backup_config
 if hermes update; then
  after=$(hermes_version)
  echo "✅ 升级完成: $before → $after"
 else
  echo "❌ hermes update 执行失败。可尝试重新运行安装脚本。"
 fi
 pause
}

safe_pkill_gateway(){
 if need_cmd pkill; then
  pkill -f 'hermes gateway run' 2>/dev/null || true
  pkill -f 'hermes-gateway' 2>/dev/null || true
 elif need_cmd pgrep; then
  pgrep -f 'hermes gateway run|hermes-gateway' 2>/dev/null | while read -r pid; do kill "$pid" 2>/dev/null || true; done
 else
  echo "⚠️ 未找到 pkill/pgrep，无法自动清理遗留 Gateway 进程。"
 fi
}

gateway_status_ok(){ check_hermes >/dev/null 2>&1 && hermes gateway status 2>/dev/null | grep -Eiq 'running|active|connected'; }

gateway_plist_path(){ printf '%s\n' "$HOME/Library/LaunchAgents/com.hermes.gateway.plist"; }

install_macos_gateway_service(){
 local plist hermes_path log_out log_err
 has_launchctl || { echo "❌ macOS 缺少 launchctl，无法安装 LaunchAgent。"; return 1; }
 hermes_path=$(cmd_path hermes)
 [ -n "$hermes_path" ] || { echo "❌ 未找到 hermes 命令。"; return 1; }
 plist=$(gateway_plist_path)
 mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"
 log_out="$LOG_DIR/gateway.log"
 log_err="$LOG_DIR/gateway.err.log"
 cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.hermes.gateway</string>
  <key>ProgramArguments</key>
  <array>
    <string>$hermes_path</string>
    <string>gateway</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$log_out</string>
  <key>StandardErrorPath</key>
  <string>$log_err</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HERMES_HOME</key>
    <string>$HERMES_HOME</string>
    <key>PATH</key>
    <string>$PATH</string>
  </dict>
</dict>
</plist>
EOF
 launchctl unload "$plist" >/dev/null 2>&1 || true
 launchctl load "$plist"
 echo "✅ macOS LaunchAgent 已安装: $plist"
}

install_gateway_service(){
 check_hermes || return 1
 echo "⚙️ 正在安装 Hermes Gateway 服务..."
 if is_macos; then
  install_macos_gateway_service || echo "⚠️ LaunchAgent 安装失败，稍后仍会尝试启动。"
 elif hermes gateway install; then
  echo "✅ Gateway 服务已安装"
 else
  echo "⚠️ Gateway 服务安装命令返回失败，仍会尝试启动。"
 fi
 start_gateway
}

start_gateway(){
 check_hermes || return 1
 echo "⚙️ 正在启动 Gateway..."
 if hermes gateway start >/dev/null 2>&1; then
  sleep 2
  echo "✅ Gateway 启动命令已执行"
 elif is_macos && has_launchctl && [ -f "$(gateway_plist_path)" ] && launchctl load "$(gateway_plist_path)" >/dev/null 2>&1; then
  sleep 2
  echo "✅ macOS LaunchAgent 已启动"
 elif has_systemd && systemctl start hermes-gateway.service >/dev/null 2>&1; then
  sleep 2
  echo "✅ systemd Gateway 已启动"
 elif has_user_systemd && systemctl --user start hermes-gateway >/dev/null 2>&1; then
  sleep 2
  echo "✅ user systemd Gateway 已启动"
 else
  echo "⚠️ 服务启动失败，尝试后台运行模式..."
  ensure_dirs
  if need_cmd setsid; then setsid hermes gateway run </dev/null >> "$LOG_FILE" 2>&1 & else nohup hermes gateway run </dev/null >> "$LOG_FILE" 2>&1 & fi
  disown >/dev/null 2>&1 || true
  sleep 3
 fi
 hermes gateway status 2>/dev/null || true
}

stop_gateway(){
 check_hermes || return 1
 echo "⚙️ 正在停止 Gateway..."
 hermes gateway stop >/dev/null 2>&1 || true
 if is_macos && has_launchctl && [ -f "$(gateway_plist_path)" ]; then
  launchctl unload "$(gateway_plist_path)" >/dev/null 2>&1 || true
 fi
 if has_systemd; then systemctl stop hermes-gateway.service >/dev/null 2>&1 || true; fi
 if has_user_systemd; then systemctl --user stop hermes-gateway >/dev/null 2>&1 || true; fi
 safe_pkill_gateway
 echo "✅ Gateway 已停止"
}

restart_gateway(){ stop_gateway; sleep 1; start_gateway; }

gateway_logs(){
 echo -e "\n--- Gateway 日志 ---"
 if is_macos && [ -f "$(gateway_plist_path)" ] && [ -f "$LOG_FILE" ]; then
  tail -n 120 "$LOG_FILE" 2>/dev/null || true
 elif has_systemd && need_cmd journalctl; then
  journalctl -u hermes-gateway.service -n 120 --no-pager 2>/dev/null || true
 elif has_user_systemd && need_cmd journalctl; then
  journalctl --user -u hermes-gateway -n 120 --no-pager 2>/dev/null || true
 elif [ -f "$LOG_FILE" ]; then
  tail -n 120 "$LOG_FILE" 2>/dev/null || true
 elif [ -f "$HERMES_HOME/logs/gateway.err.log" ]; then
  tail -n 120 "$HERMES_HOME/logs/gateway.err.log" 2>/dev/null || true
 else
  echo "暂无 Gateway 日志。"
 fi
}

gateway_manage(){
 check_hermes || return 1
 while true; do
  echo -e "\n--- Gateway 管理 ---"
  hermes gateway status 2>/dev/null || true
  echo "1) 安装 Gateway 服务"
  echo "2) 启动 Gateway"
  echo "3) 重启 Gateway"
  echo "4) 停止 Gateway"
  echo "5) 查看日志"
  echo "6) 配置 Gateway 平台向导"
  echo "0) 返回"
  echo "------------------------------------------------"
  read -r -p "请选择操作: " gw_choice
  case "${gw_choice:-}" in
   1) install_gateway_service; pause ;;
   2) start_gateway; pause ;;
   3) restart_gateway; pause ;;
   4) stop_gateway; pause ;;
   5) gateway_logs; pause ;;
   6) hermes gateway setup; pause ;;
   0|"") return ;;
   *) echo "❌ 无效选择" ;;
  esac
 done
}

set_env_var(){
 local key="$1" val="$2"
 ensure_dirs
 touch "$ENV_FILE"
 backup_file "$ENV_FILE"
 python3 - "$ENV_FILE" "$key" "$val" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1]); key = sys.argv[2]; val = sys.argv[3]
lines = path.read_text(errors='ignore').splitlines() if path.exists() else []
prefix = key + '='
lines = [line for line in lines if not line.startswith(prefix)]
lines.append(f'{key}={val}')
path.write_text('\n'.join(lines) + '\n')
PY
 chmod 600 "$ENV_FILE" 2>/dev/null || true
}

unset_env_var(){
 local key="$1"
 [ -f "$ENV_FILE" ] || return 0
 backup_file "$ENV_FILE"
 python3 - "$ENV_FILE" "$key" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1]); key = sys.argv[2]
lines = path.read_text(errors='ignore').splitlines()
lines = [line for line in lines if not line.startswith(key + '=')]
path.write_text('\n'.join(lines) + ('\n' if lines else ''))
PY
}

hermes_config_set(){
 local key="$1" val="$2"
 check_hermes || return 1
 if [ "${HMS_CONFIG_BATCH:-0}" != "1" ]; then
  backup_file "$CONFIG"
 fi
 hermes config set "$key" "$val"
}

uppercase(){ printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'; }

provider_env_name(){
 case "$1" in
  openrouter) echo "OPENROUTER_API_KEY" ;;
  anthropic) echo "ANTHROPIC_API_KEY" ;;
  openai) echo "OPENAI_API_KEY" ;;
  deepseek) echo "DEEPSEEK_API_KEY" ;;
  google|gemini) echo "GEMINI_API_KEY" ;;
  xai|grok) echo "XAI_API_KEY" ;;
  groq) echo "GROQ_API_KEY" ;;
  mistral) echo "MISTRAL_API_KEY" ;;
  kimi|moonshot) echo "KIMI_API_KEY" ;;
  minimax) echo "MINIMAX_API_KEY" ;;
  dashscope|aliyun|qwen) echo "DASHSCOPE_API_KEY" ;;
  zhipu|glm) echo "GLM_API_KEY" ;;
  huggingface|hf) echo "HF_TOKEN" ;;
  *) echo "" ;;
 esac
}

model_value(){
 local field="$1"
 [ -f "$CONFIG" ] || return 0
 python3 - "$CONFIG" "$field" <<'PY' 2>/dev/null || true
import sys, pathlib
path = pathlib.Path(sys.argv[1])
field = sys.argv[2]
lines = path.read_text(errors='ignore').splitlines()
in_model = False
for line in lines:
    if line.startswith('model:'):
        in_model = True
        continue
    if in_model and line and not line.startswith((' ', '\t')):
        break
    if in_model:
        stripped = line.strip()
        if stripped.startswith(field + ':'):
            print(stripped.split(':', 1)[1].strip().strip('"').strip("'"))
            break
PY
}

show_model_summary(){
 local provider model base_url api_mode api_key api_mode_desc
 provider=$(model_value provider)
 model=$(model_value default)
 base_url=$(model_value base_url)
 api_mode=$(model_value api_mode)
 api_key=$(model_value api_key)
 api_mode_desc=$(api_mode_label "$api_mode")
 echo "当前模型:"
 echo "  Provider : ${provider:-未设置}"
 echo "  Model    : ${model:-未设置}"
 echo "  Base URL : ${base_url:-默认官方地址}"
 if [ -n "$api_mode" ]; then
  echo "  API Mode : $api_mode ($api_mode_desc)"
 else
  echo "  API Mode : 默认/自动"
 fi
 if [ -n "$api_key" ]; then
  echo "  API Key  : 已写入 config.yaml"
 else
  echo "  API Key  : 未在 config.yaml 明文配置（可能在 .env）"
 fi
}

finish_model_change(){
 echo "✅ 模型配置已保存。"
 echo "ℹ️ 已运行中的 CLI 需要退出重开；Gateway 需要重启后生效。"
 read -r -p "是否立即测试一次？(y/N): " test_now
 if [[ "${test_now:-}" =~ ^[Yy]$ ]]; then
  hermes chat -q "请只回复 OK" || true
 fi
 read -r -p "是否立即重启 Gateway？(y/N): " r
 [[ "$r" =~ ^[Yy]$ ]] && restart_gateway
 pause
}

api_mode_label(){
 case "${1:-}" in
  chat_completions) echo "OpenAI Chat Completions" ;;
  codex_responses) echo "OpenAI Responses / Codex" ;;
  anthropic_messages) echo "Anthropic Messages" ;;
  bedrock_converse) echo "AWS Bedrock Converse" ;;
  codex_app_server) echo "Codex App Server" ;;
  "") echo "默认/自动" ;;
  *) echo "$1" ;;
 esac
}

choose_api_mode(){
 local current="${1:-chat_completions}" choice
 echo "协议类型 / API Mode:" >&2
 echo "  1) OpenAI Chat Completions   /v1/chat/completions（大多数中转默认）" >&2
 echo "  2) OpenAI Responses / Codex  /v1/responses" >&2
 echo "  3) Anthropic Messages        /v1/messages 或 /anthropic" >&2
 echo "  4) AWS Bedrock Converse" >&2
 echo "  5) Codex App Server" >&2
 echo "  0) 保持当前: $(api_mode_label "$current")" >&2
 read -r -p "请选择协议类型 [0]: " choice
 case "${choice:-0}" in
  1) echo "chat_completions" ;;
  2) echo "codex_responses" ;;
  3) echo "anthropic_messages" ;;
  4) echo "bedrock_converse" ;;
  5) echo "codex_app_server" ;;
  0|"") echo "$current" ;;
  *) echo "❌ 无效选择" >&2; return 1 ;;
 esac
}

openai_compatible_model_config(){
 local provider current_model current_base current_mode current_key model base_url api_key api_mode
 echo -e "\n--- OpenAI 兼容 / 中转模型配置 ---"
 provider="custom"
 current_model=$(model_value default)
 current_base=$(model_value base_url)
 current_mode=$(model_value api_mode)
 current_key=$(model_value api_key)
 echo "适合 subapi、one-api、new-api、LiteLLM、OpenRouter 兼容地址等。"
 read -r -p "Base URL [${current_base:-https://example.com/v1}]: " base_url
 base_url=${base_url:-$current_base}
 read -r -p "模型 ID [${current_model:-deepseek-v4-flash}]: " model
 model=${model:-${current_model:-deepseek-v4-flash}}
 api_mode=$(choose_api_mode "${current_mode:-chat_completions}") || { pause; return; }
 if [ -n "$current_key" ]; then
  read -r -p "API Key 已存在，回车沿用；输入新 key 则覆盖: " api_key
 else
  read -r -p "API Key（可回车跳过）: " api_key
 fi
 [ -z "${base_url:-}" ] && { echo "❌ Base URL 不能为空"; pause; return; }
 [ -z "${model:-}" ] && { echo "❌ 模型 ID 不能为空"; pause; return; }
 config_batch_start
 hermes_config_set model.provider "$provider"
 hermes_config_set model.base_url "$base_url"
 hermes_config_set model.default "$model"
 hermes_config_set model.api_mode "$api_mode"
 [ -n "${api_key:-}" ] && hermes_config_set model.api_key "$api_key"
 config_batch_end
 finish_model_change
}

switch_model_id(){
 local current_model model
 current_model=$(model_value default)
 echo -e "\n--- 切换当前模型 ID ---"
 echo "当前模型 ID: ${current_model:-未设置}"
 read -r -p "新的模型 ID（回车返回）: " model
 [ -z "${model:-}" ] && return
 config_batch_start
 hermes_config_set model.default "$model"
 config_batch_end
 finish_model_change
}

preset_provider(){
 local choice provider model base_url env_name key custom_model
 echo -e "\n--- 官方 Provider 快捷配置 ---"
 printf "%-22s %-22s %-22s\n" "1) OpenRouter" "2) Anthropic" "3) OpenAI"
 printf "%-22s %-22s %-22s\n" "4) DeepSeek" "5) Google Gemini" "6) xAI/Grok"
 printf "%-22s %-22s %-22s\n" "7) Groq" "8) Mistral" "9) Kimi/Moonshot"
 printf "%-22s %-22s %-22s\n" "10) DashScope/Qwen" "11) MiniMax" "12) 返回"
 read -r -p "请选择编号: " choice
 case "${choice:-}" in
  1) provider="openrouter"; base_url=""; model="anthropic/claude-sonnet-4" ;;
  2) provider="anthropic"; base_url=""; model="claude-sonnet-4" ;;
  3) provider="openai"; base_url=""; model="gpt-5" ;;
  4) provider="deepseek"; base_url=""; model="deepseek-chat" ;;
  5) provider="google"; base_url=""; model="gemini-2.5-pro" ;;
  6) provider="xai"; base_url=""; model="grok-4" ;;
  7) provider="groq"; base_url=""; model="llama-3.3-70b-versatile" ;;
  8) provider="mistral"; base_url=""; model="mistral-large-latest" ;;
  9) provider="kimi"; base_url=""; model="kimi-k2-latest" ;;
  10) provider="dashscope"; base_url=""; model="qwen-max" ;;
  11) provider="minimax"; base_url=""; model="minimax-text-01" ;;
  0|12|"") return ;;
  *) echo "❌ 无效选择"; return ;;
 esac
 read -r -p "模型 ID [$model]: " custom_model
 model=${custom_model:-$model}
 env_name=$(provider_env_name "$provider")
 read -r -p "API Key（写入 $ENV_FILE 的 $env_name，回车跳过）: " key
 [ -n "${key:-}" ] && set_env_var "$env_name" "$key"
 config_batch_start
 hermes_config_set model.provider "$provider"
 hermes_config_set model.default "$model"
 hermes_config_set model.base_url "${base_url:-}"
 hermes_config_set model.api_mode ""
 hermes_config_set model.api_key ""
 config_batch_end
 finish_model_change
}

manual_model_config(){
 local provider model base_url api_key env_name current_provider current_model current_base current_mode api_mode
 echo -e "\n--- 高级手动配置 ---"
 current_provider=$(model_value provider)
 current_model=$(model_value default)
 current_base=$(model_value base_url)
 current_mode=$(model_value api_mode)
 read -r -p "Provider 名称 [${current_provider:-custom}]: " provider
 provider=${provider:-${current_provider:-custom}}
 read -r -p "模型 ID [${current_model:-deepseek-v4-flash}]: " model
 model=${model:-${current_model:-deepseek-v4-flash}}
 read -r -p "Base URL [${current_base:-可留空使用官方默认}]: " base_url
 base_url=${base_url:-$current_base}
 api_mode=$(choose_api_mode "${current_mode:-chat_completions}") || { pause; return; }
 [ -z "${provider:-}" ] && { echo "❌ Provider 不能为空"; pause; return; }
 [ -z "${model:-}" ] && { echo "❌ 模型 ID 不能为空"; pause; return; }
 env_name=$(provider_env_name "$provider")
 if [ -z "$env_name" ]; then env_name="HERMES_$(uppercase "$provider")_API_KEY"; env_name=$(echo "$env_name" | tr -c 'A-Z0-9_' '_'); fi
 read -r -p "API Key（写入 $env_name，回车跳过）: " api_key
 [ -n "${api_key:-}" ] && set_env_var "$env_name" "$api_key"
 config_batch_start
 hermes_config_set model.provider "$provider"
 hermes_config_set model.default "$model"
 hermes_config_set model.base_url "${base_url:-}"
 hermes_config_set model.api_mode "$api_mode"
 config_batch_end
 finish_model_change
}

model_manage(){
 check_hermes || return 1
 while true; do
  echo -e "\n--- 大模型配置 ---"
  show_model_summary
  echo "1) 配置/修改 OpenAI 兼容中转（推荐）"
  echo "2) 只切换当前模型 ID"
  echo "3) 官方 Provider 快捷配置"
  echo "4) 高级手动配置"
  echo "5) 打开 Hermes 官方模型选择器"
  echo "6) 测试当前模型"
  echo "7) 运行 hermes doctor 检查"
  echo "0) 返回"
  echo "------------------------------------------------"
  read -r -p "请选择操作: " c
  case "${c:-}" in
   1) openai_compatible_model_config ;;
   2) switch_model_id ;;
   3) preset_provider ;;
   4) manual_model_config ;;
   5) hermes model; pause ;;
   6) hermes chat -q "请只回复 OK"; pause ;;
   7) hermes doctor; pause ;;
   0|"") return ;;
   *) echo "❌ 无效选择" ;;
  esac
 done
}

configure_telegram(){
 check_hermes || return 1
 local token uid send_test
 echo -e "\n--- 配置 Telegram Bot ---"
 read -r -p "Telegram Bot Token: " token
 read -r -p "Telegram 用户/Chat ID: " uid
 [[ -z "${token:-}" ]] && { echo "❌ Bot Token 不能为空"; pause; return; }
 [[ -z "${uid:-}" ]] && { echo "❌ 用户/Chat ID 不能为空"; pause; return; }
 [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]{20,}$ ]] || { echo "❌ Bot Token 格式不正确，应类似 123456789:AA..."; pause; return; }
 set_env_var TELEGRAM_BOT_TOKEN "$token"
 config_batch_start
 hermes_config_set telegram.allowed_chats "$uid"
 hermes_config_set telegram.allow_from "[\"$uid\"]"
 # 某些版本会读取 home channel，用这个命令失败也不影响 allowlist。
 hermes config set gateway.home_channel.telegram "$uid" >/dev/null 2>&1 || true
 config_batch_end
 echo "⚙️ 正在重启 Gateway..."
 restart_gateway
 echo "✅ Telegram 配置已保存并重启。"
 read -r -p "是否发送测试消息？(Y/n): " send_test
 if [[ ! "$send_test" =~ ^[Nn]$ ]]; then
  if hermes chat -q "请通过 messaging/send_message 工具给 telegram:$uid 发送一条内容为：Hermes Telegram 配置测试成功 ✅ 的消息。只需要执行发送，不要解释。" --toolsets messaging -Q 2>/dev/null; then
   echo "✅ 已尝试发送测试消息。"
  else
   echo "⚠️ 测试消息发送失败。请确认用户已先向机器人发过 /start，然后在 Hermes 中使用 send_message 工具测试。"
  fi
 fi
 pause
}

configure_proxy(){
 check_hermes || return 1
 local proxy apply_service tmp
 echo -e "\n--- 配置网络代理 ---"
 echo "当前 network proxy:"
 hermes config 2>/dev/null | grep -E 'http_proxy|https_proxy|force_ipv4' || true
 read -r -p "请输入代理 URL（例如 http://127.0.0.1:7890，留空表示删除）: " proxy
 config_batch_start
 if [ -n "${proxy:-}" ]; then
  hermes_config_set network.http_proxy "$proxy"
  hermes_config_set network.https_proxy "$proxy"
  config_batch_end
  set_env_var HTTP_PROXY "$proxy"
  set_env_var HTTPS_PROXY "$proxy"
  set_env_var ALL_PROXY "$proxy"
 else
  hermes_config_set network.http_proxy ""
  hermes_config_set network.https_proxy ""
  config_batch_end
  unset_env_var HTTP_PROXY; unset_env_var HTTPS_PROXY; unset_env_var ALL_PROXY
 fi
 read -r -p "是否同时写入后台服务代理环境？Linux systemd 支持，macOS LaunchAgent 会在重装服务时继承 .env/PATH；继续写入 systemd？(y/N): " apply_service
 if [[ "$apply_service" =~ ^[Yy]$ ]]; then
  if ! has_systemd; then
   echo "⚠️ 当前系统未检测到 systemd 系统服务，已跳过 systemd drop-in。"
  elif [ -n "${proxy:-}" ]; then
   run_sudo mkdir -p /etc/systemd/system/hermes-gateway.service.d
   if need_cmd mktemp; then tmp=$(mktemp); else ensure_dirs; tmp="$HERMES_HOME/proxy.$$"; : > "$tmp"; fi
   cat > "$tmp" <<EOF
[Service]
Environment="HTTP_PROXY=$proxy"
Environment="HTTPS_PROXY=$proxy"
Environment="ALL_PROXY=$proxy"
Environment="NO_PROXY=127.0.0.1,localhost,::1"
EOF
   run_sudo cp "$tmp" /etc/systemd/system/hermes-gateway.service.d/proxy.conf
   rm -f "$tmp"
   systemctl daemon-reload 2>/dev/null || true
   restart_gateway
  else
   run_sudo rm -f /etc/systemd/system/hermes-gateway.service.d/proxy.conf
   systemctl daemon-reload 2>/dev/null || true
   restart_gateway
  fi
 fi
 echo "✅ 代理配置已处理。"
 pause
}

telegram_manage(){
 check_hermes || return 1
 while true; do
  echo -e "\n--- Telegram / 消息平台管理 ---"
  echo "1) 配置 Telegram Bot Token 和允许用户"
  echo "2) 配置网络代理"
  echo "3) Gateway 平台配置向导"
  echo "4) 查看可用发送目标"
  echo "5) 发送 Telegram 测试消息"
  echo "0) 返回"
  echo "------------------------------------------------"
  read -r -p "请选择操作: " c
  case "${c:-}" in
   1) configure_telegram ;;
   2) configure_proxy ;;
   3) hermes gateway setup; pause ;;
   4) hermes chat -q "列出当前 messaging/send_message 工具可用目标，只输出目标列表。" --toolsets messaging -Q || true; pause ;;
   5)
    read -r -p "目标 Telegram chat/user ID: " uid
    read -r -p "测试消息 [Hermes 测试消息 ✅]: " msg
    msg=${msg:-Hermes 测试消息 ✅}
    if [ -n "$uid" ]; then
     hermes chat -q "请通过 messaging/send_message 工具给 telegram:$uid 发送这条消息：$msg" --toolsets messaging -Q || true
    fi
    pause
    ;;
   0|"") return ;;
   *) echo "❌ 无效选择" ;;
  esac
 done
}

tools_skills_manage(){
 check_hermes || return 1
 while true; do
  echo -e "\n--- Tools / Skills 管理 ---"
  echo "1) 查看工具列表"
  echo "2) 启用工具集"
  echo "3) 禁用工具集"
  echo "4) 交互式工具管理"
  echo "5) 查看技能列表"
  echo "6) 搜索技能"
  echo "7) 安装技能"
  echo "8) 更新技能"
  echo "0) 返回"
  echo "------------------------------------------------"
  read -r -p "请选择操作: " c
  case "${c:-}" in
   1) hermes tools list; pause ;;
   2) read -r -p "工具集名称: " n; [ -n "$n" ] && hermes tools enable "$n"; pause ;;
   3) read -r -p "工具集名称: " n; [ -n "$n" ] && hermes tools disable "$n"; pause ;;
   4) hermes tools; pause ;;
   5) hermes skills list; pause ;;
   6) read -r -p "搜索关键词: " q; [ -n "$q" ] && hermes skills search "$q"; pause ;;
   7) read -r -p "技能 ID 或 SKILL.md URL: " sid; [ -n "$sid" ] && hermes skills install "$sid"; pause ;;
   8) hermes skills update; pause ;;
   0|"") return ;;
   *) echo "❌ 无效选择" ;;
  esac
 done
}

cron_manage(){
 check_hermes || return 1
 while true; do
  echo -e "\n--- Cron 定时任务管理 ---"
  echo "1) 列出任务"
  echo "2) 创建任务"
  echo "3) 编辑任务"
  echo "4) 暂停任务"
  echo "5) 恢复任务"
  echo "6) 立即运行任务"
  echo "7) 删除任务"
  echo "8) Scheduler 状态"
  echo "0) 返回"
  echo "------------------------------------------------"
  read -r -p "请选择操作: " c
  case "${c:-}" in
   1) hermes cron list --all 2>/dev/null || hermes cron list; pause ;;
   2) read -r -p "计划表达式（如 30m / every 2h / 0 9 * * *）: " s; [ -n "$s" ] && hermes cron create "$s"; pause ;;
   3) read -r -p "任务 ID: " id; [ -n "$id" ] && hermes cron edit "$id"; pause ;;
   4) read -r -p "任务 ID: " id; [ -n "$id" ] && hermes cron pause "$id"; pause ;;
   5) read -r -p "任务 ID: " id; [ -n "$id" ] && hermes cron resume "$id"; pause ;;
   6) read -r -p "任务 ID: " id; [ -n "$id" ] && hermes cron run "$id"; pause ;;
   7) read -r -p "任务 ID: " id; [ -n "$id" ] && hermes cron remove "$id"; pause ;;
   8) hermes cron status; pause ;;
   0|"") return ;;
   *) echo "❌ 无效选择" ;;
  esac
 done
}

profile_manage(){
 check_hermes || return 1
 while true; do
  echo -e "\n--- Profile 管理 ---"
  echo "1) 列出 profiles"
  echo "2) 创建 profile"
  echo "3) 切换默认 profile"
  echo "4) 查看 profile"
  echo "5) 删除 profile"
  echo "0) 返回"
  echo "------------------------------------------------"
  read -r -p "请选择操作: " c
  case "${c:-}" in
   1) hermes profile list; pause ;;
   2) read -r -p "新 profile 名称: " n; [ -n "$n" ] && hermes profile create "$n"; pause ;;
   3) read -r -p "profile 名称: " n; [ -n "$n" ] && hermes profile use "$n"; pause ;;
   4) read -r -p "profile 名称: " n; [ -n "$n" ] && hermes profile show "$n"; pause ;;
   5) read -r -p "确认删除的 profile 名称: " n; [ -n "$n" ] && hermes profile delete "$n"; pause ;;
   0|"") return ;;
   *) echo "❌ 无效选择" ;;
  esac
 done
}

config_manage(){
 check_hermes || return 1
 while true; do
  echo -e "\n--- 配置文件管理 ---"
  echo "1) 显示 config 路径"
  echo "2) 显示 env 路径"
  echo "3) 查看当前 config"
  echo "4) 编辑 config"
  echo "5) 设置 config 键值"
  echo "6) 备份 config 和 .env"
  echo "7) 运行 config check/migrate"
  echo "0) 返回"
  echo "------------------------------------------------"
  read -r -p "请选择操作: " c
  case "${c:-}" in
   1) hermes config path; pause ;;
   2) hermes config env-path; pause ;;
   3) hermes config; pause ;;
   4) hermes config edit; pause ;;
   5) read -r -p "Key（如 model.default）: " k; read -r -p "Value: " v; [ -n "$k" ] && hermes_config_set "$k" "$v"; pause ;;
   6) backup_config; echo "✅ 已备份到 $BACKUP_DIR"; pause ;;
   7) hermes config check || true; hermes config migrate || true; pause ;;
   0|"") return ;;
   *) echo "❌ 无效选择" ;;
  esac
 done
}

safe_remove_hms_commands(){
 for p in /usr/local/bin/hms /opt/homebrew/bin/hms "$HOME/.local/bin/hms"; do
  [ -e "$p" ] || continue
  if rm -f "$p" 2>/dev/null; then
   :
  elif need_cmd sudo; then
   sudo rm -f "$p" 2>/dev/null || true
  fi
 done
}

reset_or_uninstall(){
 check_hermes || true
 echo -e "\n--- 升级 / 重置 / 卸载管理 ---"
 echo "1) 升级 Hermes 到最新版本"
 echo "2) 备份配置"
 echo "3) 运行 Hermes doctor --fix"
 echo "4) 停止 Gateway"
 echo "5) 仅卸载 Hermes 程序（保留 ~/.hermes 数据）"
 echo "6) 彻底卸载 Hermes（删除 ~/.hermes 全部数据）"
 echo "0) 返回"
 echo "------------------------------------------------"
 read -r -p "请选择操作: " c
 case "${c:-}" in
  1) update_hermes ;;
  2) backup_config; echo "✅ 已备份到 $BACKUP_DIR"; pause ;;
  3) hermes doctor --fix || true; pause ;;
  4) stop_gateway; pause ;;
  5)
   read -r -p "确认仅卸载 Hermes 程序，并保留 $HERMES_HOME 数据？(y/N): " confirm
   if [[ "$confirm" =~ ^[Yy]$ ]]; then
    stop_gateway || true
    if hermes_exists; then hermes uninstall || true; fi
    safe_remove_hms_commands
    echo "✅ 已执行卸载命令，数据已保留。"
   else echo "已取消。"; fi
   pause
   ;;
  6)
   read -r -p "确认彻底卸载 Hermes 并删除 $HERMES_HOME 全部数据？(y/N): " confirm
   if [[ "$confirm" =~ ^[Yy]$ ]]; then
    stop_gateway || true
    if hermes_exists; then hermes uninstall || true; fi
    rm -rf "$HERMES_HOME"
    safe_remove_hms_commands
    echo "✅ Hermes 已彻底卸载。"
   else echo "已取消。"; fi
   pause
   ;;
  *) return ;;
 esac
}

show_help(){
 cat <<EOF
hms.sh - Hermes Agent 管理脚本

用法:
  bash hms.sh              进入交互菜单
  bash hms.sh status       显示状态
  bash hms.sh install      安装 Hermes
  bash hms.sh model        模型 / Provider 管理菜单
  bash hms.sh gateway      Gateway 管理菜单
  bash hms.sh telegram     Telegram 配置菜单
  bash hms.sh update       升级 Hermes
  bash hms.sh doctor       运行 hermes doctor
  bash hms.sh help         显示帮助

安装快捷命令后可直接运行: hms
EOF
}

menu(){
 safe_clear
 echo "🪽 Hermes Agent 全能管理助手 hms"
 echo "------------------------------------------------"
 printf "%-3s %s\n" "1."  "🚀 安装 Hermes Agent"
 printf "%-3s %s\n" "2."  "📊 查看状态 / Doctor"
 printf "%-3s %s\n" "3."  "🧠 模型 / Provider 管理"
 printf "%-3s %s\n" "4."  "📱 Telegram / 消息平台管理"
 printf "%-3s %s\n" "5."  "🔄 Gateway 管理"
 printf "%-3s %s\n" "6."  "🛠️  Tools / Skills 管理"
 printf "%-3s %s\n" "7."  "⏰ Cron 定时任务管理"
 printf "%-3s %s\n" "8."  "👤 Profile 管理"
 printf "%-3s %s\n" "9."  "⚙️  配置文件管理"
 printf "%-3s %s\n" "10." "🔄 升级 / 重置 / 卸载管理"
 printf "%-3s %s\n" "0."  "退出"
 echo "------------------------------------------------"
 read -r -p "请选择操作: " choice
 case "${choice:-}" in
  1) install_hermes ;;
  2) print_status; pause ;;
  3) model_manage ;;
  4) telegram_manage ;;
  5) gateway_manage ;;
  6) tools_skills_manage ;;
  7) cron_manage ;;
  8) profile_manage ;;
  9) config_manage ;;
  10) reset_or_uninstall ;;
  0) exit 0 ;;
  *) echo "❌ 无效选择"; pause ;;
 esac
}

main(){
 case "${1:-}" in
  help|-h|--help) show_help; exit 0 ;;
  status) print_status; exit 0 ;;
  install) install_hermes; exit 0 ;;
  model|models) model_manage; exit 0 ;;
  gateway) gateway_manage; exit 0 ;;
  telegram) telegram_manage; exit 0 ;;
  update) update_hermes; exit 0 ;;
  doctor) check_hermes && hermes doctor; exit 0 ;;
 esac
 install_hms_command >/dev/null 2>&1 || true
 check_dep
 while true; do menu; done
}

main "$@"
