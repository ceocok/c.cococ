#!/usr/bin/env bash
set -euo pipefail

CONFIG="$HOME/.openclaw/openclaw.json"
OPENCLAW_DIR="$HOME/.openclaw"
LOG_FILE="$OPENCLAW_DIR/gateway.log"
BACKUP_DIR="$OPENCLAW_DIR/backups"

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RESET='\033[0m'

pause(){ read -r -p "回车继续..." ; }
need_cmd(){ command -v "$1" >/dev/null 2>&1; }
cmd_path(){ command -v "$1" 2>/dev/null || true; }
cmd_exists(){ local p; p=$(cmd_path "$1"); [[ -n "$p" && -x "$p" ]]; }
quiet_run(){ "$@" >/dev/null 2>&1; }

safe_pkill_gateway(){
 if need_cmd pkill; then
  pkill -f 'openclaw gateway' 2>/dev/null || true
 else
  ps aux 2>/dev/null | grep 'openclaw gateway' | grep -v grep | awk '{print $2}' | while read -r pid; do
   kill "$pid" 2>/dev/null || true
  done
 fi
}

count_openclaw_processes(){
 ps aux 2>/dev/null | grep -E 'openclaw|openclaw-gateway' | grep -v grep | wc -l | awk '{print $1}'
}

check_dep(){
 if ! need_cmd jq || ! need_cmd curl; then
  echo "⚙️ 正在安装基础依赖..."
  if [[ "${OSTYPE:-}" == darwin* ]]; then
   need_cmd brew || { echo "❌ Mac 缺少 Homebrew，请先安装: https://brew.sh/"; exit 1; }
   need_cmd jq || brew install jq >/dev/null
   need_cmd curl || brew install curl >/dev/null
  elif need_cmd apt-get; then
   sudo apt-get update -y >/dev/null
   need_cmd jq || sudo apt-get install -y jq >/dev/null
   need_cmd curl || sudo apt-get install -y curl >/dev/null
  elif need_cmd dnf; then
   need_cmd jq || sudo dnf install -y jq >/dev/null
   need_cmd curl || sudo dnf install -y curl >/dev/null
  elif need_cmd yum; then
   need_cmd jq || sudo yum install -y epel-release jq >/dev/null
   need_cmd curl || sudo yum install -y curl >/dev/null
  elif need_cmd pacman; then
   sudo pacman -Sy --noconfirm jq curl >/dev/null
  elif need_cmd apk; then
   sudo apk add --no-cache jq curl >/dev/null
  elif need_cmd zypper; then
   sudo zypper --non-interactive install jq curl >/dev/null
  else
   echo "❌ 无法自动安装依赖，请手动安装 jq 和 curl！"
   exit 1
  fi
 fi
}

ensure_dirs(){
 mkdir -p "$OPENCLAW_DIR" "$BACKUP_DIR"
}

resolve_script_path(){
 local src
 src="${BASH_SOURCE[0]:-$0}"

 if need_cmd readlink; then
  readlink -f "$src" 2>/dev/null && return 0
 fi

 if need_cmd realpath; then
  realpath "$src" 2>/dev/null && return 0
 fi

 case "$src" in
  /*) echo "$src" ;;
  *) echo "$(pwd)/$src" ;;
 esac
}

install_ocm_command(){
 local target script_path
 script_path=$(resolve_script_path)

 # macOS 优先放到 Homebrew 前缀（Apple Silicon 常见）
 if [[ "${OSTYPE:-}" == darwin* ]] && [ -d "/opt/homebrew/bin" ]; then
  target="/opt/homebrew/bin/ocm"
 else
  target="/usr/local/bin/ocm"
 fi

 if [ ! -f "$script_path" ]; then
  return 0
 fi

 # 尝试直接写入
 if cat > "$target" 2>/dev/null <<EOF
#!/usr/bin/env bash
exec bash "$script_path" "\$@"
EOF
 then
  chmod +x "$target" 2>/dev/null || true
  return 0
 fi

 # 需要 sudo 权限
 if need_cmd sudo; then
  sudo mkdir -p "$(dirname "$target")" >/dev/null 2>&1 || true
  sudo tee "$target" >/dev/null 2>&1 <<EOF
#!/usr/bin/env bash
exec bash "$script_path" "\$@"
EOF
  sudo chmod +x "$target" 2>/dev/null || true
 fi

 return 0
}

backup_config(){
 if [[ -f "$CONFIG" ]]; then
  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  cp "$CONFIG" "$BACKUP_DIR/openclaw.json.$ts.bak"
  ls -t "$BACKUP_DIR"/openclaw.json.*.bak 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true
 fi
}

node_major_version(){
 if ! need_cmd node; then
  echo 0
  return 0
 fi

 local node_ver
 node_ver=$(node -v 2>/dev/null | sed 's/v//' | cut -d'.' -f1)
 if [[ "$node_ver" =~ ^[0-9]+$ ]]; then
  echo "$node_ver"
 else
  echo 0
 fi
}

prepare_node_env() {
 local node_ver
 node_ver=$(node_major_version)
 if need_cmd npm && [ "$node_ver" -ge 22 ]; then
  return 0
 fi

 echo "⚙️ 正在准备 Node.js 22+ ..."
 if [[ "${OSTYPE:-}" == darwin* ]]; then
  need_cmd brew && {
   brew install node@22 >/dev/null
   brew link --overwrite --force node@22 >/dev/null 2>&1 || true
   if [[ -d "/opt/homebrew/opt/node@22/bin" ]]; then
    export PATH="/opt/homebrew/opt/node@22/bin:$PATH"
   elif [[ -d "/usr/local/opt/node@22/bin" ]]; then
    export PATH="/usr/local/opt/node@22/bin:$PATH"
   fi
  }
 elif need_cmd apt-get; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >/dev/null 2>&1
  sudo apt-get install -y nodejs >/dev/null
 elif need_cmd dnf; then
  curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash - >/dev/null 2>&1
  sudo dnf install -y nodejs >/dev/null
 elif need_cmd yum; then
  curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash - >/dev/null 2>&1
  sudo yum install -y nodejs >/dev/null
 elif need_cmd pacman; then
  sudo pacman -S --noconfirm --needed nodejs npm >/dev/null
 elif need_cmd apk; then
  sudo apk add --no-cache nodejs npm >/dev/null
 elif need_cmd zypper; then
  sudo zypper --non-interactive install nodejs22 npm22 >/dev/null 2>&1 || \
  sudo zypper --non-interactive install nodejs npm >/dev/null 2>&1 || true
 fi

 hash -r
 node_ver=$(node_major_version)
 if need_cmd npm && [ "$node_ver" -ge 22 ]; then
  return 0
 fi

 echo "❌ Node.js 环境准备失败，当前 Node 版本不足 22，请手动安装 Node v22+！"
 return 1
}

check_config() {
 if [ ! -f "$CONFIG" ]; then
  echo -e "\n❌ 未检测到 OpenClaw 配置文件！请先选择 [1] 安装 OpenClaw。"
  pause
  return 1
 fi
 return 0
}

save_config() {
 local content="$1"
 echo "$content" | jq '.' > "$CONFIG.tmp" || {
  echo "❌ JSON 格式错误！保存取消。"
  rm -f "$CONFIG.tmp"
  return 1
 }
 backup_config
 mv "$CONFIG.tmp" "$CONFIG"
 return 0
}

gateway_is_listening(){
 local gw_port
 gw_port=$(jq -r '.gateway.port // 52525' "$CONFIG" 2>/dev/null || echo "52525")

 if need_cmd lsof; then
  lsof -nP -iTCP:"$gw_port" -sTCP:LISTEN >/dev/null 2>&1 && return 0
 fi

 if need_cmd ss; then
  ss -ltn 2>/dev/null | grep -q ":$gw_port " && return 0
 fi

 if need_cmd netstat; then
  netstat -an 2>/dev/null | grep -E "[\.:]$gw_port[[:space:]].*LISTEN|LISTEN[[:space:]].*[\.:]$gw_port" >/dev/null 2>&1 && return 0
 fi

 if need_cmd curl; then
  curl -s -o /dev/null --connect-timeout 2 "http://127.0.0.1:$gw_port/" >/dev/null 2>&1 && return 0
 fi

 return 1
}

mac_gateway_label(){
 echo "ai.openclaw.gateway"
}

mac_gateway_plist(){
 echo "$HOME/Library/LaunchAgents/$(mac_gateway_label).plist"
}

mac_gateway_service_loaded(){
 [[ "${OSTYPE:-}" == darwin* ]] || return 1
 launchctl print "gui/$(id -u)/$(mac_gateway_label)" >/dev/null 2>&1
}

mac_gateway_service_fix(){
 [[ "${OSTYPE:-}" == darwin* ]] || return 1

 local uid label plist_path
 uid=$(id -u)
 label=$(mac_gateway_label)
 plist_path=$(mac_gateway_plist)

 [ -f "$plist_path" ] || return 1

 launchctl bootstrap "gui/$uid" "$plist_path" >/dev/null 2>&1 || true
 launchctl enable "gui/$uid/$label" >/dev/null 2>&1 || true
 launchctl kickstart -k "gui/$uid/$label" >/dev/null 2>&1 || true

 mac_gateway_service_loaded
}

start_openclaw(){
 if ! cmd_exists openclaw; then
  echo "❌ 未检测到 openclaw 命令，无法启动 Gateway"
  return 1
 fi

 local i openclaw_bin
 openclaw_bin=$(cmd_path openclaw)

 if [[ "${OSTYPE:-}" == darwin* ]]; then
  if ! mac_gateway_service_loaded; then
   mac_gateway_service_fix || true
  fi
 fi

 if gateway_is_listening; then
  return 0
 fi

 # 先尝试系统服务（macOS launchd / Linux systemd）
 if quiet_run openclaw gateway start; then
  for i in {1..10}; do
   if gateway_is_listening; then
    return 0
   fi
   sleep 1
  done
 fi

 # macOS: service 未加载则再次修复 launchd
 if [[ "${OSTYPE:-}" == darwin* ]]; then
  if mac_gateway_service_fix; then
   for i in {1..10}; do
    if gateway_is_listening; then
     return 0
    fi
    sleep 1
   done
  fi
 fi

 # 服务不可用时，回退到后台托管模式
 if need_cmd setsid; then
  setsid "$openclaw_bin" gateway run </dev/null >> "$LOG_FILE" 2>&1 &
 else
  nohup "$openclaw_bin" gateway run </dev/null >> "$LOG_FILE" 2>&1 &
 fi

 disown >/dev/null 2>&1 || true

 for i in {1..15}; do
  if gateway_is_listening; then
   return 0
  fi
  sleep 1
 done

 echo "❌ Gateway 启动失败，请检查日志: $LOG_FILE"
 tail -n 20 "$LOG_FILE" 2>/dev/null || true
 return 1
}

restart_openclaw(){
 if ! cmd_exists openclaw; then
  echo "❌ 未检测到 openclaw 命令，无法重启 Gateway"
  return 1
 fi

 local i
 stop_openclaw
 for i in {1..10}; do
  if ! gateway_is_listening; then
   break
  fi
  sleep 1
 done

 start_openclaw
}

stop_openclaw(){
 if cmd_exists openclaw; then
  quiet_run openclaw gateway stop || true
 fi
 safe_pkill_gateway
 pkill -f 'openclaw-gateway' 2>/dev/null || true
 pkill -f '/openclaw gateway run' 2>/dev/null || true
}

gateway_json_check(){
 jq empty "$CONFIG" >/dev/null 2>&1 || {
  echo "❌ 当前配置 JSON 有误，未执行 Gateway 操作。"
  return 1
 }
 return 0
}

current_install_method(){
 local method
 method=$(openclaw update status 2>/dev/null | awk -F'│' '/Install/{gsub(/^ +| +$/, "", $3); print $3; exit}')
 if [[ -n "${method:-}" ]]; then
  echo "$method"
  return 0
 fi

 if need_cmd pnpm; then
  echo "pnpm"
 elif need_cmd npm; then
  echo "npm"
 else
  echo ""
 fi
}

upgrade_openclaw(){
 echo -e "\n🔄 正在升级 OpenClaw..."
 quiet_run openclaw update status || true

 local method
 method=$(current_install_method || true)

 case "$method" in
  pnpm)
   if ! need_cmd pnpm; then
    if need_cmd npm; then
     method="npm"
    else
     echo "❌ 未找到 pnpm 或 npm，无法升级。"
     return 1
    fi
   fi
   ;;
 esac

 case "$method" in
  pnpm)
   pnpm add -g openclaw@latest >/dev/null
   ;;
  npm|"")
   npm install -g openclaw@latest >/dev/null || sudo npm install -g openclaw@latest >/dev/null
   ;;
  *)
   echo "⚠️ 无法识别安装方式，改用 npm 尝试升级。"
   npm install -g openclaw@latest >/dev/null || sudo npm install -g openclaw@latest >/dev/null
   ;;
 esac

 hash -r
 restart_openclaw
 echo "✅ 升级完成。"
}

generate_token(){
 if need_cmd openssl; then
  openssl rand -hex 16
 else
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
 fi
}

get_openclaw_version(){
 local openclaw_bin v
 openclaw_bin=$(cmd_path openclaw)
 if [[ -z "$openclaw_bin" || ! -x "$openclaw_bin" ]]; then
  echo "unknown"
  return 0
 fi

 v=$("$openclaw_bin" --version 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
 if [[ -n "$v" ]]; then
  echo "$v"
 else
  echo "unknown"
 fi
}

write_default_config(){
 local gen_token curr_date current_version
 gen_token=$(generate_token)
 curr_date=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
 current_version=$(get_openclaw_version)
 cat <<EOF
{
 "meta": {
  "lastTouchedVersion": "$current_version",
  "lastTouchedAt": "$curr_date"
 },
 "wizard": {
  "lastRunAt": "$curr_date",
  "lastRunVersion": "$current_version",
  "lastRunCommand": "onboard",
  "lastRunMode": "local"
 },
 "auth": { "profiles": {} },
 "models": { "providers": {} },
 "agents": {
  "defaults": {
   "model": { "primary": "", "fallbacks": [] },
   "models": {},
   "workspace": "$HOME/.openclaw/workspace",
   "maxConcurrent": 4,
   "subagents": { "maxConcurrent": 8 }
  }
 },
 "messages": { "ackReactionScope": "group-mentions" },
 "commands": { "native": "auto", "nativeSkills": "auto", "restart": true },
 "hooks": {
  "internal": {
   "enabled": true,
   "entries": {
    "boot-md": { "enabled": true },
    "session-memory": { "enabled": true }
   }
  }
 },
 "channels": {},
 "gateway": {
  "port": 52525,
  "mode": "local",
  "bind": "loopback",
  "auth": { "mode": "token", "token": "$gen_token" },
  "tailscale": { "mode": "off", "resetOnExit": false },
  "http": { "endpoints": { "chatCompletions": { "enabled": true } } },
  "controlUi": {
   "allowedOrigins": [
    "http://127.0.0.1:52525",
    "http://localhost:52525"
   ]
  },
  "trustedProxies": ["127.0.0.1/32", "::1/128"]
 },
 "skills": { "install": { "nodeManager": "npm" } },
 "plugins": { "entries": {} }
}
EOF
}

provider_defaults(){
 case "$1" in
  openai|openai-codex|openrouter|xai|mistral|deepseek|siliconflow|groq|cerebras|vercel-ai-gateway|github-copilot|synthetic|aliyun|qwen-portal|yi|moonshot|kimi-coding|volcengine|baichuan|ollama|google-gemini-cli)
   echo "openai-responses"
   ;;
  anthropic)
   echo "anthropic-messages"
   ;;
  minimax|zai)
   echo "anthropic-messages"
   ;;
  google|google-vertex|google-antigravity|opencode|tencent|zhipu)
   echo "openai-completions"
   ;;
  *)
   echo "openai-completions"
   ;;
 esac
}

normalize_origin(){
 local raw="$1"
 local host port scheme path rest

 raw=$(echo "$raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
 [[ -z "$raw" ]] && return 1

 if [[ "$raw" =~ ^https?:// ]]; then
  echo "$raw"
  return 0
 fi

 host="$raw"
 path=""

 if [[ "$host" == */* ]]; then
  path="/${host#*/}"
  host="${host%%/*}"
 fi

 port=""
 if [[ "$host" == *:* ]]; then
  rest="${host##*:}"
  if [[ "$rest" =~ ^[0-9]+$ ]]; then
   port=":$rest"
   host="${host%:*}"
  fi
 fi

 if [[ "$host" == "localhost" || "$host" == "127.0.0.1" || "$host" == "::1" ]]; then
  scheme="http"
 else
  scheme="https"
 fi

 echo "${scheme}://${host}${port}${path}"
}

add_cors_origin(){
 local old_o raw_origin origin new_json
 old_o=$(jq -r '(.gateway.controlUi.allowedOrigins // []) | join(", ")' "$CONFIG")
 read -r -p "当前允许跨域请求的域名: [$old_o], 输入新增域名 (回车跳过): " raw_origin
 [[ -z "$raw_origin" ]] && return 0

 origin=$(normalize_origin "$raw_origin") || {
  echo "❌ 域名格式无效"
  pause
  return 1
 }

 new_json=$(jq --arg d "$origin" '
  .gateway.controlUi = (.gateway.controlUi // {}) |
  .gateway.controlUi.allowedOrigins = (((.gateway.controlUi.allowedOrigins // []) + [$d]) | unique)
 ' "$CONFIG")
 save_config "$new_json"
 echo "✅ 已添加域名: $origin"
}

post_install_setup(){
 echo -e "\n🚀 安装完成，接下来配置大模型..."
 add_preset_model
 echo -e "\n📱 接下来配置 channel..."
 manage_channels
}

install_openclaw() {
 echo -e "\n🚀 开始安装 OpenClaw..."
 check_dep
 ensure_dirs

 if [ ! -f "$CONFIG" ]; then
  echo "📦 正在生成默认配置..."
  write_default_config > "$CONFIG"
  echo "✅ 默认配置已写入。"
 else
  echo "✅ 检测到已有配置。"
 fi

 if cmd_exists openclaw; then
  echo "✅ 检测到 OpenClaw 已安装。"
 else
  prepare_node_env || return 1
  echo "⚙️ 正在安装 OpenClaw..."
  npm install -g openclaw@latest >/dev/null || sudo npm install -g openclaw@latest >/dev/null || { echo "❌ 安装失败"; pause; return 1; }
  hash -r
  cmd_exists openclaw || { echo "❌ OpenClaw 安装后仍不可用，请检查 npm 全局 PATH。"; pause; return 1; }
 fi

 install_ocm_command || true

 # 安装 Gateway 系统服务（macOS launchd / Linux systemd）
 echo "⚙️ 正在安装 Gateway 系统服务..."
 if openclaw gateway install >/dev/null 2>&1; then
  echo "✅ Gateway 系统服务已安装"

  # macOS: 立即加载并启动，避免“安装了但未运行”
  if [[ "${OSTYPE:-}" == darwin* ]]; then
   if mac_gateway_service_fix; then
    echo "✅ launchd 服务已加载并激活"
   else
    echo "⚠️ launchd 已写入但未激活，将回退后台托管模式"
   fi
  else
   echo "✅ Gateway 系统服务已安装（开机自启，不依赖终端）"
  fi
 else
  echo "⚠️ Gateway 系统服务安装失败，将使用后台托管模式"
 fi

 restart_openclaw || { pause; return 1; }
 echo -e "${GREEN}✅ Gateway 已启动，监听端口: $(jq -r '.gateway.port // 52525' "$CONFIG")，以后可直接输入 ${YELLOW}ocm${GREEN} 启动本脚本${RESET}"
 echo -e "${CYAN}🎉 安装完成。${RESET}"
 post_install_setup
}

validate_api_connectivity() {
 local provider=$1
 echo -e "\n🔍 开始测试 API 连通性: $provider ..."

 local port token p_mid p_api target_model is_enabled local_url payload gw_resp gw_body gw_code err_msg curl_exit
 local original_primary original_fallbacks switched_for_test=false
 port=$(jq -r '.gateway.port' "$CONFIG")
 token=$(jq -r '.gateway.auth.token // ""' "$CONFIG")
 p_mid=$(jq -r --arg p "$provider" '.models.providers[$p].models[0].id' "$CONFIG")
 p_api=$(jq -r --arg p "$provider" '.models.providers[$p].api // "openai-completions"' "$CONFIG")
 target_model="$provider/$p_mid"

 original_primary=$(jq -r '.agents.defaults.model.primary // ""' "$CONFIG")
 original_fallbacks=$(jq -c '.agents.defaults.model.fallbacks // []' "$CONFIG")

 is_enabled=$(jq -r '.gateway.http.endpoints.chatCompletions.enabled' "$CONFIG")
 if [ "$is_enabled" != "true" ]; then
  save_config "$(jq '.gateway.http.endpoints.chatCompletions.enabled = true' "$CONFIG")"
 fi

 if [[ "$original_primary" != "$target_model" ]]; then
  save_config "$(jq --arg m "$target_model" '.agents.defaults.model.primary=$m | .agents.defaults.model.fallbacks=[$m]' "$CONFIG")"
  switched_for_test=true
 fi

 if ! gateway_is_listening; then
  echo "⚙️ 检测到 Gateway 未运行，正在后台启动..."
  restart_openclaw || {
   if [ "$switched_for_test" = true ]; then
    save_config "$(jq --arg p "$original_primary" --argjson f "$original_fallbacks" '.agents.defaults.model.primary=$p | .agents.defaults.model.fallbacks=$f' "$CONFIG")" || true
   fi
   echo "❌ Gateway 启动失败，无法执行 API 测试。"
   return 1
  }
 elif [ "$switched_for_test" = true ]; then
  restart_openclaw || true
 fi

 local_url="http://127.0.0.1:$port/v1/chat/completions"
 payload=$(jq -nc --arg model "$target_model" '{model:$model,messages:[{role:"user",content:"hi"}],max_tokens:16}')

 set +e
 gw_resp=$(curl -s -w "\n%{http_code}" -X POST "$local_url" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $token" \
  --connect-timeout 15 \
  -d "$payload")
 curl_exit=$?
 set -e

 if [ "$switched_for_test" = true ]; then
  save_config "$(jq --arg p "$original_primary" --argjson f "$original_fallbacks" '.agents.defaults.model.primary=$p | .agents.defaults.model.fallbacks=$f' "$CONFIG")" || true
  restart_openclaw || true
 fi

 gw_body=$(echo "$gw_resp" | sed '$d')
 gw_code=$(echo "$gw_resp" | tail -n1)
 echo ""

 if [ "$curl_exit" -ne 0 ] && [ -z "$gw_code" ]; then
  gw_code="000"
 fi

 if [ "$gw_code" = "200" ]; then
  echo "✅ 连通性测试通过。"
  if [ "$p_api" != "openai-completions" ]; then
   echo "ℹ️ 当前协议为 $p_api，本次为通过 Gateway chat/completions 做的兼容性连通测试。"
  fi
  return 0
 elif [ "$gw_code" = "000" ] || [ "$curl_exit" -ne 0 ]; then
  echo "❌ 无法连接到本地 Gateway 或请求发送失败。"
  tail -n 8 "$LOG_FILE" 2>/dev/null | sed 's/^/ /'
  return 1
 else
  echo "❌ 上游请求失败 (HTTP $gw_code)"
  err_msg=$(echo "$gw_body" | jq -r '.error.message // .message // empty' 2>/dev/null || true)
  if [ -n "$err_msg" ]; then
   echo "↳ $err_msg"
  fi
  return 1
 fi
}

save_model_logic() {
 local p_name=$1 p_url=$2 p_key=$3 p_api=$4 p_mid=$5
 local is_reasoning="false"
 local new_json full_model current_primary

 if [[ "$p_mid" =~ (r[1-9]|o[1-9]|reasoner|thinking) ]]; then
  is_reasoning="true"
 fi

 if [ -z "$p_url" ]; then
  new_json=$(jq --arg p "$p_name" --arg k "$p_key" --arg a "$p_api" --arg m "$p_mid" --argjson r "$is_reasoning" \
   '.models.providers[$p]={apiKey:$k, api:$a, models:[{id:$m, name:$m, reasoning:$r, input:["text","image"], contextWindow:200000, maxTokens:32000, cost:{input:0,output:0,cacheRead:0,cacheWrite:0}}]}' "$CONFIG")
 else
  new_json=$(jq --arg p "$p_name" --arg u "$p_url" --arg k "$p_key" --arg a "$p_api" --arg m "$p_mid" --argjson r "$is_reasoning" \
   '.models.providers[$p]={baseUrl:$u, apiKey:$k, api:$a, models:[{id:$m, name:$m, reasoning:$r, input:["text","image"], contextWindow:200000, maxTokens:32000, cost:{input:0,output:0,cacheRead:0,cacheWrite:0}}]}' "$CONFIG")
 fi

 full_model="$p_name/$p_mid"
 current_primary=$(echo "$new_json" | jq -r '.agents.defaults.model.primary // empty')
 if [[ -z "$current_primary" ]]; then
  new_json=$(echo "$new_json" | jq --arg m "$full_model" '.agents.defaults.model.primary=$m | .agents.defaults.model.fallbacks=[$m]')
 fi

 if save_config "$new_json" && restart_openclaw; then
  if validate_api_connectivity "$p_name"; then
   echo "👉 大模型配置完毕。"
  else
   echo "⚠️ 大模型已保存，但测试未通过，请检查上游接口或协议类型。"
  fi
 else
  echo "❌ 大模型保存或 Gateway 重启失败。"
  return 1
 fi
}

add_preset_model() {
 echo -e "\n--- 快捷添加大模型 ---"
 printf "%-22s %-22s %-22s %-22s\n" " 1) OpenAI" " 2) Anthropic" " 3) Google" " 4) xAI"
 printf "%-22s %-22s %-22s %-22s\n" " 5) Mistral" " 6) DeepSeek" " 7) SiliconFlow" " 8) Groq"
 printf "%-22s %-22s %-22s %-22s\n" " 9) Cerebras" "10) OpenRouter" "11) Vercel Gateway" "12) OpenAI Codex"
 printf "%-22s %-22s %-22s %-22s\n" "13) OpenCode" "14) Ollama" "15) Google Vertex" "16) Gemini CLI"
 printf "%-22s %-22s %-22s %-22s\n" "17) GitHub Copilot" "18) Z.AI" "19) Aliyun/Qwen" "20) ZhiPu"
 printf "%-22s %-22s %-22s %-22s\n" "21) Yi" "22) Moonshot" "23) MiniMax" "24) Tencent"
 printf "%-22s %-22s\n" "25) Volcengine" "26) Baichuan"
 echo " 0) 自定义中转"
 read -r -p "请选择编号 (回车跳过): " p_choice

 [[ -z "$p_choice" ]] && return

 case $p_choice in
  1) name="openai"; url="https://api.openai.com/v1" ;;
  2) name="anthropic"; url="https://api.anthropic.com" ;;
  3) name="google"; url="https://generativelanguage.googleapis.com/v1beta/openai" ;;
  4) name="xai"; url="https://api.x.ai/v1" ;;
  5) name="mistral"; url="https://api.mistral.ai/v1" ;;
  6) name="deepseek"; url="https://api.deepseek.com/v1" ;;
  7) name="siliconflow"; url="https://api.siliconflow.cn/v1" ;;
  8) name="groq"; url="https://api.groq.com/openai/v1" ;;
  9) name="cerebras"; url="https://api.cerebras.ai/v1" ;;
  10) name="openrouter"; url="https://openrouter.ai/api/v1" ;;
  11) name="vercel-ai-gateway"; url="https://pro.api.vercel.com/v1" ;;
  12) name="openai-codex"; url="https://api.openai.com/v1" ;;
  13) name="opencode"; url="https://api.opencode.com/v1" ;;
  14) name="ollama"; url="http://127.0.0.1:11434/v1" ;;
  15) name="google-vertex"; url="https://us-central1-aiplatform.googleapis.com/v1" ;;
  16) name="google-gemini-cli"; url="http://127.0.0.1:9041/v1" ;;
  17) name="github-copilot"; url="https://api.githubcopilot.com/v1" ;;
  18) name="zai"; url="https://api.z.ai/api/anthropic" ;;
  19) name="aliyun"; url="https://dashscope.aliyuncs.com/compatible-mode/v1" ;;
  20) name="zhipu"; url="https://open.bigmodel.cn/api/paas/v4" ;;
  21) name="yi"; url="https://api.lingyiwanwu.com/v1" ;;
  22) name="moonshot"; url="https://api.moonshot.cn/v1" ;;
  23) name="minimax"; url="https://api.minimax.io/anthropic" ;;
  24) name="tencent"; url="https://api.hunyuan.cloud.tencent.com/v1" ;;
  25) name="volcengine"; url="https://ark.cn-beijing.volces.com/api/v3" ;;
  26) name="baichuan"; url="https://api.baichuan-ai.com/v1" ;;
  0) add_model_manual; return ;;
  *) return ;;
 esac

 api=$(provider_defaults "$name")
 echo -e "\n已选择: $name"
 echo "API URL: $url"
 read -r -p "请输入 API Key (本地服务可回车跳过): " key
 read -r -p "请输入模型 ID: " mid
 [[ -z "$mid" ]] && { echo "❌ 模型 ID 不能为空"; return; }

 save_model_logic "$name" "$url" "$key" "$api" "$mid"
}

add_model_manual() {
 echo -e "\n--- 添加自定义大模型 ---"
 read -r -p "Provider 名称: " name
 read -r -p "API BaseURL: " url
 read -r -p "API Key: " key
 read -r -p "协议类型 (1: openai-responses, 2: openai-completions, 3: anthropic-messages) [默认2]: " t_idx

 case "${t_idx:-2}" in
  1) api="openai-responses" ;;
  3) api="anthropic-messages" ;;
  *) api="openai-completions" ;;
 esac

 read -r -p "模型 ID: " mid
 [[ -z "$mid" ]] && { echo "❌ 模型 ID 不能为空"; return; }

 save_model_logic "$name" "$url" "$key" "$api" "$mid"
}

list_providers(){
 jq -r '.models.providers | keys[]?' "$CONFIG"
}

list_models(){
 jq -r '.models.providers | to_entries[] | .key as $p | .value.models[]? | "\($p)/\(.id)"' "$CONFIG" | sort -u
}

pick_provider_by_index(){
 local idx="$1"
 local i=1 p
 while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  if [ "$i" = "$idx" ]; then
   echo "$p"
   return 0
  fi
  i=$((i+1))
 done <<EOF
$(list_providers)
EOF
 return 1
}

pick_model_by_index(){
 local idx="$1"
 local i=1 m
 while IFS= read -r m; do
  [[ -z "$m" ]] && continue
  if [ "$i" = "$idx" ]; then
   echo "$m"
   return 0
  fi
  i=$((i+1))
 done <<EOF
$(list_models)
EOF
 return 1
}

print_providers_with_index(){
 local i=1 p
 while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  echo "$i) $p"
  i=$((i+1))
 done <<EOF
$(list_providers)
EOF
}

print_models_with_index(){
 local i=1 m
 while IFS= read -r m; do
  [[ -z "$m" ]] && continue
  echo "$i) $m"
  i=$((i+1))
 done <<EOF
$(list_models)
EOF
}

edit_model(){
 local target c_url c_key c_api c_mid n_name n_url n_key n_t n_api n_mid num
 local new_json current_primary fallback_models provider_exists final_target
 if [[ -z "$(list_providers)" ]]; then
  echo "📭 当前未添加任何大模型配置"
  pause
  return
 fi

 print_providers_with_index
 read -r -p "选择要修改的编号: " num
 target=$(pick_provider_by_index "$num" || true)
 [ -z "${target:-}" ] && return

 c_url=$(jq -r --arg p "$target" '.models.providers[$p].baseUrl // ""' "$CONFIG")
 c_key=$(jq -r --arg p "$target" '.models.providers[$p].apiKey // ""' "$CONFIG")
 c_api=$(jq -r --arg p "$target" '.models.providers[$p].api' "$CONFIG")
 c_mid=$(jq -r --arg p "$target" '.models.providers[$p].models[0].id' "$CONFIG")

 echo -e "\n--- 修改 $target (回车保持原样) ---"
 read -r -p "Provider 名称 [$target]: " n_name; n_name=${n_name:-$target}

 if [[ "$n_name" != "$target" ]]; then
  provider_exists=$(jq -r --arg p "$n_name" '.models.providers[$p] != null' "$CONFIG")
  if [[ "$provider_exists" == "true" ]]; then
   echo "❌ Provider 名称已存在：$n_name"
   pause
   return
  fi

  new_json=$(jq --arg old "$target" --arg new "$n_name" '
   .models.providers[$new] = .models.providers[$old] |
   del(.models.providers[$old])
  ' "$CONFIG")

  current_primary=$(echo "$new_json" | jq -r '.agents.defaults.model.primary // ""')
  if [[ "$current_primary" == "$target/"* ]]; then
   current_primary="$n_name/${current_primary#*/}"
   new_json=$(echo "$new_json" | jq --arg m "$current_primary" '.agents.defaults.model.primary=$m')
  fi

  fallback_models=$(echo "$new_json" | jq -c --arg old "$target/" --arg new "$n_name/" '
   (.agents.defaults.model.fallbacks // []) | map(if startswith($old) then ($new + (split("/")[1])) else . end)
  ')
  new_json=$(echo "$new_json" | jq --argjson f "$fallback_models" '.agents.defaults.model.fallbacks=$f')

  save_config "$new_json" || { pause; return; }
  target="$n_name"
  echo "✅ Provider 名称已修改：$target"
 fi

 read -r -p "BaseURL [$c_url]: " n_url; n_url=${n_url:-$c_url}
 read -r -p "API Key [已隐藏，回车保持]: " n_key; n_key=${n_key:-$c_key}
 read -r -p "协议 (1:openai-responses, 2:openai-completions, 3:anthropic-messages) [$c_api]: " n_t
 case "${n_t:-}" in
  1) n_api="openai-responses" ;;
  2) n_api="openai-completions" ;;
  3) n_api="anthropic-messages" ;;
  *) n_api="$c_api" ;;
 esac
 read -r -p "模型ID [$c_mid]: " n_mid; n_mid=${n_mid:-$c_mid}

 save_model_logic "$target" "$n_url" "$n_key" "$n_api" "$n_mid"
 pause
}

delete_model(){
 local num target new_json current_primary fallback_primary
 if [[ -z "$(list_providers)" ]]; then
  echo "📭 当前未添加任何大模型配置"
  pause
  return
 fi

 print_providers_with_index
 read -r -p "选择要删除的编号: " num
 target=$(pick_provider_by_index "$num" || true)
 [[ -z "${target:-}" ]] && return

 new_json=$(jq --arg p "$target" 'del(.models.providers[$p])' "$CONFIG")
 current_primary=$(jq -r '.agents.defaults.model.primary // ""' "$CONFIG")

 if [[ "$current_primary" == "$target/"* ]]; then
  fallback_primary=$(echo "$new_json" | jq -r '.models.providers | to_entries[]? | .key as $p | .value.models[0]? | "\($p)/\(.id)"' | head -n1)
  if [[ -n "$fallback_primary" ]]; then
   new_json=$(echo "$new_json" | jq --arg m "$fallback_primary" '.agents.defaults.model.primary=$m | .agents.defaults.model.fallbacks=[$m]')
  else
   new_json=$(echo "$new_json" | jq '.agents.defaults.model.primary="" | .agents.defaults.model.fallbacks=[]')
  fi
 fi

 save_config "$new_json" && restart_openclaw && echo "✅ 已删除: $target"
 pause
}

manage_models(){
 echo -e "\n--- 管理大模型配置 ---"
 echo "1) 修改大模型配置"
 echo "2) 删除大模型配置"
 echo "0) 返回"
 echo "------------------------------------------------"
 read -r -p "请选择操作: " sub_choice

 case $sub_choice in
  1) edit_model ;;
  2) delete_model ;;
  *) return ;;
 esac
}

list_channels(){
 jq -r '.channels | keys[]?' "$CONFIG"
}

pick_channel_by_index(){
 local idx="$1"
 local i=1 c
 while IFS= read -r c; do
  [[ -z "$c" ]] && continue
  if [ "$i" = "$idx" ]; then
   echo "$c"
   return 0
  fi
  i=$((i+1))
 done <<EOF
$(list_channels)
EOF
 return 1
}

print_channels_with_index(){
 local i=1 c ctype
 while IFS= read -r c; do
  [[ -z "$c" ]] && continue
  ctype=$(jq -r --arg n "$c" '.channels[$n].type // ""' "$CONFIG")
  if [[ -n "$ctype" ]]; then
   echo "$i) $c [$ctype]"
  else
   echo "$i) $c"
  fi
  i=$((i+1))
 done <<EOF
$(list_channels)
EOF
}

add_channel() {
 local c_type cn ct pid aid sec tg_uid new_json pre_backup

 echo -e "\n--- 添加 channel ---"
 echo "1) WhatsApp"
 echo "2) Telegram Bot"
 echo "3) Discord"
 echo "4) 企业微信 (WeCom)"
 read -r -p "选择 (回车跳过): " c_type

 [[ -z "$c_type" ]] && return

 case $c_type in
  1)
   read -r -p "channel 名称: " cn
   read -r -p "Access Token: " ct
   read -r -p "Phone Number ID: " pid
   new_json=$(jq --arg n "$cn" --arg t "$ct" --arg p "$pid" '.channels[$n]={type:"whatsapp", token:$t, phoneId:$p, enabled:true}' "$CONFIG")
   save_config "$new_json" && restart_openclaw && echo "✅ channel 已保存！"
   ;;
  2)
   echo -e "\n--- 添加 Telegram Bot ---"
   read -r -p "Telegram机器人Token: " ct
   read -r -p "Telegram机器人用户ID: " tg_uid

   [[ -z "${ct:-}" ]] && { echo "❌ Bot Token 不能为空"; return; }
   [[ -z "${tg_uid:-}" ]] && { echo "❌ Telegram 用户ID不能为空"; return; }

   if [[ ! "$ct" =~ ^[0-9]+:[A-Za-z0-9_-]{20,}$ ]]; then
    echo "❌ Bot Token 格式不正确，应类似 123456789:AA..."
    return
   fi

   if [[ ! "$tg_uid" =~ ^[0-9]+$ ]]; then
    echo "❌ Telegram 用户ID应为纯数字"
    return
   fi

   pre_backup="$BACKUP_DIR/openclaw.json.pre-telegram.$(date +%Y%m%d-%H%M%S).bak"
   cp "$CONFIG" "$pre_backup" 2>/dev/null || true

   new_json=$(jq --arg t "$ct" --arg uid "$tg_uid" '
    .channels = (.channels // {}) |
    .channels.telegram = {
      botToken: $t,
      allowFrom: [$uid],
      dmPolicy: "allowlist",
      enabled: true
    }
   ' "$CONFIG")

   if ! save_config "$new_json"; then
    echo "❌ Telegram 配置保存失败"
    return
   fi

   if need_cmd timeout; then
    if ! timeout 20s openclaw config validate >/dev/null 2>&1; then
     cp "$pre_backup" "$CONFIG" 2>/dev/null || true
     echo "❌ Telegram 配置校验失败（或超时），已回滚"
     return
    fi
   else
    if ! openclaw config validate >/dev/null 2>&1; then
     cp "$pre_backup" "$CONFIG" 2>/dev/null || true
     echo "❌ Telegram 配置校验失败，已回滚"
     return
    fi
   fi

   if restart_openclaw; then
    echo "✅ Telegram Bot 已配置并重启成功"
    if openclaw message send --channel telegram --target "$tg_uid" --message "测试消息：Telegram 已通过 ocm 脚本配置成功。" >/dev/null 2>&1; then
     echo "✅ 已发送 Telegram 测试消息"
    else
     echo "⚠️ 配置成功，但测试消息发送失败（请检查机器人是否已先与用户发起对话）"
    fi
   else
    cp "$pre_backup" "$CONFIG" 2>/dev/null || true
    restart_openclaw >/dev/null 2>&1 || true
    echo "❌ Gateway 重启失败，已回滚到修改前配置"
    return
   fi
   ;;
  3)
   read -r -p "channel 名称: " cn
   read -r -p "Bot Token: " ct
   new_json=$(jq --arg n "$cn" --arg t "$ct" '.channels[$n]={type:"discord", token:$t, enabled:true}' "$CONFIG")
   save_config "$new_json" && restart_openclaw && echo "✅ channel 已保存！"
   ;;
  4)
   read -r -p "channel 名称: " cn
   read -r -p "AgentId: " aid
   read -r -p "Secret: " sec
   new_json=$(jq --arg n "$cn" --arg ai "$aid" --arg s "$sec" '.channels[$n]={type:"wecom", agentId:$ai, secret:$s, enabled:true}' "$CONFIG")
   save_config "$new_json" && restart_openclaw && echo "✅ channel 已保存！"
   ;;
  *)
   return
   ;;
 esac
}

edit_channel(){
 local num target c_type n_name ct pid aid sec enabled new_json
 if [[ -z "$(list_channels)" ]]; then
  echo "📭 当前未添加任何 channel"
  pause
  return
 fi

 print_channels_with_index
 read -r -p "选择要修改的 channel 编号: " num
 target=$(pick_channel_by_index "$num" || true)
 [[ -z "${target:-}" ]] && return

 c_type=$(jq -r --arg n "$target" '.channels[$n].type // ""' "$CONFIG")
 enabled=$(jq -r --arg n "$target" '.channels[$n].enabled // true' "$CONFIG")
 echo -e "\n--- 修改 channel: $target [$c_type] ---"
 read -r -p "新的 channel 名称 [$target] (回车保持): " n_name
 n_name=${n_name:-$target}

 case "$c_type" in
  whatsapp)
   ct=$(jq -r --arg n "$target" '.channels[$n].token // ""' "$CONFIG")
   pid=$(jq -r --arg n "$target" '.channels[$n].phoneId // ""' "$CONFIG")
   read -r -p "Access Token [已隐藏，回车保持]: " new_ct; new_ct=${new_ct:-$ct}
   read -r -p "Phone Number ID [$pid]: " new_pid; new_pid=${new_pid:-$pid}
   new_json=$(jq --arg old "$target" --arg new "$n_name" --arg t "$new_ct" --arg p "$new_pid" --argjson e "$enabled" 'del(.channels[$old]) | .channels[$new]={type:"whatsapp", token:$t, phoneId:$p, enabled:$e}' "$CONFIG")
   ;;
  telegram)
   ct=$(jq -r --arg n "$target" '.channels[$n].token // ""' "$CONFIG")
   read -r -p "Bot Token [已隐藏，回车保持]: " new_ct; new_ct=${new_ct:-$ct}
   new_json=$(jq --arg old "$target" --arg new "$n_name" --arg t "$new_ct" --argjson e "$enabled" 'del(.channels[$old]) | .channels[$new]={type:"telegram", token:$t, enabled:$e}' "$CONFIG")
   ;;
  discord)
   ct=$(jq -r --arg n "$target" '.channels[$n].token // ""' "$CONFIG")
   read -r -p "Bot Token [已隐藏，回车保持]: " new_ct; new_ct=${new_ct:-$ct}
   new_json=$(jq --arg old "$target" --arg new "$n_name" --arg t "$new_ct" --argjson e "$enabled" 'del(.channels[$old]) | .channels[$new]={type:"discord", token:$t, enabled:$e}' "$CONFIG")
   ;;
  wecom)
   aid=$(jq -r --arg n "$target" '.channels[$n].agentId // ""' "$CONFIG")
   sec=$(jq -r --arg n "$target" '.channels[$n].secret // ""' "$CONFIG")
   read -r -p "AgentId [$aid]: " new_aid; new_aid=${new_aid:-$aid}
   read -r -p "Secret [已隐藏，回车保持]: " new_sec; new_sec=${new_sec:-$sec}
   new_json=$(jq --arg old "$target" --arg new "$n_name" --arg ai "$new_aid" --arg s "$new_sec" --argjson e "$enabled" 'del(.channels[$old]) | .channels[$new]={type:"wecom", agentId:$ai, secret:$s, enabled:$e}' "$CONFIG")
   ;;
  *)
   echo "❌ 暂不支持该 channel 类型修改"
   pause
   return
   ;;
 esac

 save_config "$new_json" && restart_openclaw && echo "✅ channel 已更新！"
 pause
}

delete_channel(){
 local num target new_json
 if [[ -z "$(list_channels)" ]]; then
  echo "📭 当前未添加任何 channel"
  pause
  return
 fi

 print_channels_with_index
 read -r -p "选择要删除的 channel 编号: " num
 target=$(pick_channel_by_index "$num" || true)
 [[ -z "${target:-}" ]] && return

 new_json=$(jq --arg n "$target" 'del(.channels[$n])' "$CONFIG")
 save_config "$new_json" && restart_openclaw && echo "✅ 已删除 channel: $target"
 pause
}

manage_channels(){
 echo -e "\n--- 管理设置 channel ---"
 echo "1) 添加 channel"
 echo "2) 编辑 channel"
 echo "3) 删除 channel"
 echo "回车) 返回主菜单"
 echo "------------------------------------------------"
 read -r -p "请选择操作: " sub_choice

 case $sub_choice in
  1) add_channel; pause ;;
  2) edit_channel ;;
  3) delete_channel ;;
  ""|0) return ;;
  *) return ;;
 esac
}

switch_model(){
 local num selected new_json current_model
 if [[ -z "$(list_models)" ]]; then
  echo "📭 当前未添加任何大模型配置"
  pause
  return
 fi

 current_model=$(jq -r '.agents.defaults.model.primary // "未设置"' "$CONFIG")
 echo "当前使用的模型: $current_model"
 print_models_with_index
 read -r -p "选择新的默认主模型: " num
 selected=$(pick_model_by_index "$num" || true)
 [[ -z "${selected:-}" ]] && return

 new_json=$(jq --arg m "$selected" '.agents.defaults.model.primary=$m | .agents.defaults.model.fallbacks=[$m]' "$CONFIG")
 save_config "$new_json" && restart_openclaw && echo "✅ 默认主模型已切换为 $selected"
 pause
}

set_port(){
 local old_p np new_json
 old_p=$(jq -r '.gateway.port' "$CONFIG")
 read -r -p "当前网关端口 $old_p, 输入新端口 (回车跳过): " np

 if [[ -n "$np" ]]; then
  [[ "$np" =~ ^[0-9]+$ ]] || { echo "❌ 端口必须是数字"; pause; return; }
  new_json=$(jq --argjson oldp "$old_p" --argjson newp "$np" '
   .gateway.port=$newp |
   .gateway.controlUi = (.gateway.controlUi // {}) |
   .gateway.controlUi.allowedOrigins = ((.gateway.controlUi.allowedOrigins // [
    ("http://127.0.0.1:" + ($oldp|tostring)),
    ("http://localhost:" + ($oldp|tostring))
   ])
   | map(
      if . == ("http://127.0.0.1:" + ($oldp|tostring)) then ("http://127.0.0.1:" + ($newp|tostring))
      elif . == ("http://localhost:" + ($oldp|tostring)) then ("http://localhost:" + ($newp|tostring))
      else . end
     )
   | unique)
  ' "$CONFIG")
  save_config "$new_json"
 fi

 add_cors_origin
 restart_openclaw
 pause
}

approve_devices(){
 local ids count id
 count=0
 ids=$(openclaw devices list 2>/dev/null | grep -Eo '[0-9a-fA-F-]{36}' | sort -u || true)

 if [ -z "$ids" ]; then
  echo "📭 当前无待授权设备"
  pause
  return
 fi

 while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  if openclaw devices approve "$id" >/dev/null 2>&1; then
   count=$((count+1))
  fi
 done <<EOF
$ids
EOF

 echo "✅ 已批准 $count 台终端设备"
 pause
}

show_gateway_token(){
 local token port
 token=$(jq -r '.gateway.auth.token // "未设置"' "$CONFIG")
 port=$(jq -r '.gateway.port // "52525"' "$CONFIG")

 echo -e "\n--- Gateway Token ---"
 echo "Token: $token"
 echo "地址: http://127.0.0.1:$port/v1/chat/completions"
 echo "------------------------------------------------"
 pause
}

gateway_manage(){
 local gw_port gw_status
 gw_port=$(jq -r '.gateway.port // 52525' "$CONFIG" 2>/dev/null || echo "52525")

 if [[ "${OSTYPE:-}" == darwin* ]]; then
  if mac_gateway_service_loaded && gateway_is_listening; then
   gw_status="运行中（launchd 已加载）"
  elif mac_gateway_service_loaded; then
   gw_status="异常（launchd 已加载，但端口未监听）"
  elif [ -f "$(mac_gateway_plist)" ]; then
   gw_status="未运行（LaunchAgent 已安装但未加载）"
  else
   gw_status="未运行（LaunchAgent 未安装）"
  fi
 else
  if gateway_is_listening; then
   gw_status="运行中"
  else
   gw_status="未运行"
  fi
 fi

 echo -e "\n--- Gateway 管理 ---"
 echo "当前状态: $gw_status (端口: $gw_port)"
 echo "1) 启动 Gateway"
 echo "2) 重启 Gateway"
 echo "3) 停止 Gateway"
 echo "0) 返回"
 echo "------------------------------------------------"
 read -r -p "请选择操作: " gw_choice

 case $gw_choice in
  1)
   if gateway_json_check; then
    if start_openclaw; then
     echo "✅ Gateway 已启动"
    else
     echo "❌ Gateway 启动失败"
    fi
   fi
   pause
   ;;
  2)
   if gateway_json_check; then
    if restart_openclaw; then
     echo "✅ Gateway 已重启"
    else
     echo "❌ Gateway 重启失败"
    fi
   fi
   pause
   ;;
  3)
   if gateway_json_check; then
    stop_openclaw
    echo "✅ Gateway 已停止"
   fi
   pause
   ;;
  *)
   return
   ;;
 esac
}

manage_installation(){
 echo -e "\n--- 升级/重置/卸载管理 ---"
 echo "1) 备份后重建默认配置"
 echo "2) 升级 OpenClaw 到最新版本"
 echo "3) 直接重置 OpenClaw"
 echo "4) 仅卸载 OpenClaw 程序（保留 ~/.openclaw 数据）"
 echo "5) 彻底卸载 OpenClaw（删除 ~/.openclaw 全部数据）"
 echo "0) 取消并返回主菜单"
 echo "------------------------------------------------"
 read -r -p "请选择操作: " mi_choice

 case $mi_choice in
  1)
   read -r -p "确认备份当前配置并重建默认配置？(y/N): " confirm
   if [[ "$confirm" =~ ^[Yy]$ ]]; then
    ensure_dirs
    backup_config
    write_default_config > "$CONFIG"
    restart_openclaw
    echo "✅ 默认配置已重建。"
   else
    echo "已取消。"
   fi
   pause
   ;;
  2)
   upgrade_openclaw
   pause
   ;;
  3)
   read -r -p "确认直接重置 OpenClaw？(y/N): " confirm
   if [[ "$confirm" =~ ^[Yy]$ ]]; then
    if need_cmd openclaw && quiet_run openclaw reset; then
     echo "✅ 已重置。"
    else
     safe_pkill_gateway
     backup_config
     rm -f "$CONFIG"
     write_default_config > "$CONFIG"
     restart_openclaw
     echo "✅ 已重置为默认配置。"
    fi
   else
    echo "已取消。"
   fi
   pause
   ;;
  4)
   read -r -p "确认仅卸载 OpenClaw 程序，并保留 ~/.openclaw 数据？(y/N): " confirm
   if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "卸载中..."

    if cmd_exists openclaw; then
     quiet_run openclaw gateway stop || true
    fi
    safe_pkill_gateway
    pkill -f 'openclaw-gateway' 2>/dev/null || true
    pkill -f '/openclaw ' 2>/dev/null || true
    if need_cmd pnpm; then
     pnpm remove -g openclaw >/dev/null 2>&1 || true
    fi
    if need_cmd npm; then
     npm uninstall -g openclaw >/dev/null 2>&1 || sudo npm uninstall -g openclaw >/dev/null 2>&1 || true
    fi
    hash -r

    echo "✅ OpenClaw 程序已卸载，数据已保留。"
   else
    echo "已取消。"
   fi
   pause
   ;;
  5)
   read -r -p "确认彻底卸载 OpenClaw 并删除 ~/.openclaw 全部数据？(y/N): " confirm
   if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "卸载中..."

    if cmd_exists openclaw; then
     quiet_run openclaw gateway stop || true
    fi
    safe_pkill_gateway
    pkill -f 'openclaw-gateway' 2>/dev/null || true
    pkill -f '/openclaw ' 2>/dev/null || true
    if need_cmd pnpm; then
     pnpm remove -g openclaw >/dev/null 2>&1 || true
    fi
    if need_cmd npm; then
     npm uninstall -g openclaw >/dev/null 2>&1 || sudo npm uninstall -g openclaw >/dev/null 2>&1 || true
    fi
    hash -r
    rm -rf "$OPENCLAW_DIR"
    rm -f /usr/local/bin/ocm /opt/homebrew/bin/ocm

    echo "✅ OpenClaw 已彻底卸载完成。"
   else
    echo "已取消。"
   fi
   pause
   ;;
  *)
   return
   ;;
 esac
}

menu(){
 clear
 echo "🍀 OpenClaw 全能管理助手 stable"
 echo "------------------------------------------------"
 printf "%-3s %s\n" "1."  "🚀 安装 OpenClaw"
 printf "%-3s %s\n" "2."  "📂 快捷添加大模型"
 printf "%-3s %s\n" "3."  "⚙️ 管理大模型配置"
 printf "%-3s %s\n" "4."  "🤖 切换默认主模型"
 printf "%-3s %s\n" "5."  "📱 管理设置 channel"
 printf "%-3s %s\n" "6."  "🛠️ 测试 API 可用性"
 printf "%-3s %s\n" "7."  "🔌 修改端口/添加域名"
 printf "%-3s %s\n" "8."  "🔑 一键批准终端设备"
 printf "%-3s %s\n" "9."  "🔄 Gateway 管理"
 printf "%-3s %s\n" "10." "🔎 查询 Gateway Token"
 printf "%-3s %s\n" "11." "⚠️ 升级/重置/卸载管理"
 printf "%-3s %s\n" "0."  "退出"
 echo "------------------------------------------------"
 read -r -p "请选择操作: " choice

 case $choice in
  1) install_openclaw ;;
  2) check_config && { add_preset_model; pause; } ;;
  3) check_config && manage_models ;;
  4) check_config && switch_model ;;
  5) check_config && manage_channels ;;
  6)
   if check_config; then
    local providers_exist t_n target
    providers_exist=$(list_providers || true)
    if [[ -z "$providers_exist" ]]; then
     echo "📭 当前未添加任何大模型配置，无法测试"
    else
     print_providers_with_index
     read -r -p "测试编号: " t_n
     target=$(pick_provider_by_index "$t_n" || true)
     [[ -n "${target:-}" ]] && validate_api_connectivity "$target"
    fi
    pause
   fi
   ;;
  7) check_config && set_port ;;
  8) check_config && approve_devices ;;
  9) check_config && gateway_manage ;;
  10) check_config && show_gateway_token ;;
  11) manage_installation ;;
  0) exit 0 ;;
 esac
}

install_ocm_command >/dev/null 2>&1 || true
check_dep
while true; do menu; done

