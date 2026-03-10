Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptUrl = 'https://in.cnno.de/ocm.ps1'
$IsWindowsCompat = ($env:OS -eq 'Windows_NT')
$HomeDir = [Environment]::GetFolderPath('UserProfile')
$OpenClawDir = Join-Path $HomeDir '.openclaw'
$Config = Join-Path $OpenClawDir 'openclaw.json'
$LogFile = Join-Path $OpenClawDir 'gateway.log'
$BackupDir = Join-Path $OpenClawDir 'backups'
$DirtyModelsFile = Join-Path $OpenClawDir '.ocm-dirty-models'

function Pause-OCM {
    Read-Host '回车继续...'
}

function Test-Cmd {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-PwshCmd {
    $candidates = @()
    foreach ($name in @('pwsh.exe','pwsh')) {
        try {
            $cmd = Get-Command $name -ErrorAction SilentlyContinue
            if ($cmd -and $cmd.Source) { $candidates += $cmd.Source }
        } catch {}
    }
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
    }
    foreach ($candidate in $candidates | Select-Object -Unique) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    return ''
}

function Install-PowerShell7 {
    Write-Host '⚙️ 当前为 Windows PowerShell 5.1，正在准备 PowerShell 7 ...'
    if (Test-Cmd 'winget') {
        try {
            & winget install Microsoft.PowerShell --silent --accept-package-agreements --accept-source-agreements | Out-Null
        } catch {
            Write-Host "⚠️ winget 安装 PowerShell 7 失败，尝试改用 Chocolatey: $($_.Exception.Message)"
        }
    }
    if ((-not (Get-PwshCmd)) -and (Test-Cmd 'choco')) {
        try {
            & choco install powershell-core -y --no-progress | Out-Null
        } catch {
            Write-Host "❌ Chocolatey 安装 PowerShell 7 失败: $($_.Exception.Message)"
            return $false
        }
    }
    return -not [string]::IsNullOrWhiteSpace((Get-PwshCmd))
}

function Ensure-PowerShell7 {
    return $true
}

function Invoke-Quiet {
    param([scriptblock]$Script)
    try {
        & $Script | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Ensure-Dirs {
    New-Item -ItemType Directory -Force -Path $OpenClawDir | Out-Null
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    if (-not (Test-Path $DirtyModelsFile)) {
        New-Item -ItemType File -Force -Path $DirtyModelsFile | Out-Null
    }
}

function Backup-Config {
    if (Test-Path $Config) {
        Ensure-Dirs
        $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item $Config (Join-Path $BackupDir "openclaw.json.$ts.bak") -Force
        $backups = @(Get-ChildItem $BackupDir -Filter 'openclaw.json.*.bak' | Sort-Object LastWriteTime -Descending)
        if (@($backups).Count -gt 10) {
            $backups | Select-Object -Skip 10 | Remove-Item -Force
        }
    }
}

function Mark-ProviderDirty {
    param([string]$Provider)
    Ensure-Dirs
    $lines = @()
    if (Test-Path $DirtyModelsFile) {
        $lines = Get-Content $DirtyModelsFile -ErrorAction SilentlyContinue
    }
    if ($lines -notcontains $Provider) {
        Add-Content -Path $DirtyModelsFile -Value $Provider
    }
}

function Test-ProviderDirty {
    param([string]$Provider)
    if (-not (Test-Path $DirtyModelsFile)) { return $false }
    return (Get-Content $DirtyModelsFile -ErrorAction SilentlyContinue) -contains $Provider
}

function Clear-DirtyProviders {
    Ensure-Dirs
    Set-Content -Path $DirtyModelsFile -Value ''
}

function Get-JsonConfig {
    if (-not (Test-Path $Config)) {
        throw '配置文件不存在'
    }
    $raw = Get-Content $Config -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw '配置文件为空'
    }
    return $raw | ConvertFrom-Json
}

function Save-JsonConfig {
    param([Parameter(Mandatory = $true)]$JsonObj)
    Ensure-Dirs
    Backup-Config
    $tmp = "$Config.tmp"
    $JsonObj | ConvertTo-Json -Depth 100 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Force $tmp $Config
}

function Ensure-ObjectPath {
    param(
        [Parameter(Mandatory = $true)]$Root,
        [Parameter(Mandatory = $true)][string[]]$Path
    )
    $cur = $Root
    foreach ($segment in $Path) {
        $prop = $cur.PSObject.Properties[$segment]
        if (-not $prop) {
            $child = [pscustomobject]@{}
            $cur | Add-Member -NotePropertyName $segment -NotePropertyValue $child
            $cur = $child
        } elseif ($null -eq $prop.Value) {
            $child = [pscustomobject]@{}
            $cur.$segment = $child
            $cur = $child
        } else {
            $cur = $prop.Value
        }
    }
    return $cur
}

function Test-Config {
    if (-not (Test-Path $Config)) {
        Write-Host "`n❌ 未检测到 OpenClaw 配置文件！请先选择 [1] 安装 OpenClaw。"
        Pause-OCM
        return $false
    }
    return $true
}

function Get-GatewayPort {
    try {
        $cfg = Get-JsonConfig
        if ($cfg.gateway -and $cfg.gateway.port) { return [int]$cfg.gateway.port }
    } catch {}
    return 52525
}

function Get-GatewayToken {
    try {
        $cfg = Get-JsonConfig
        if ($cfg.gateway -and $cfg.gateway.auth -and $cfg.gateway.auth.token) { return [string]$cfg.gateway.auth.token }
    } catch {}
    return ''
}

function Test-GatewayHealth {
    $port = Get-GatewayPort
    $urls = @(
        "http://127.0.0.1:$port/health",
        "http://127.0.0.1:$port/",
        "http://127.0.0.1:$port/v1/models"
    )
    foreach ($url in $urls) {
        try {
            Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 4 | Out-Null
            return $true
        } catch {}
    }
    return $false
}

function Get-GatewayStatusText {
    $openclawCmd = Get-OpenClawCmd
    if ([string]::IsNullOrWhiteSpace($openclawCmd)) { return '' }
    try {
        return (& $openclawCmd gateway status 2>&1 | Out-String)
    } catch {
        return ''
    }
}

function Get-OpenClawCmd {
    $candidates = @()

    if ($IsWindowsCompat) {
        foreach ($name in @('openclaw.cmd','openclaw.exe')) {
            try {
                $cmd = Get-Command $name -ErrorAction SilentlyContinue
                if ($cmd -and $cmd.Source) { $candidates += $cmd.Source }
            } catch {}
        }
        if ($env:AppData) {
            $npmBin = Join-Path $env:AppData 'npm'
            $candidates += (Join-Path $npmBin 'openclaw.cmd')
        }
        if ($env:ProgramFiles) {
            $nodeDir = Join-Path $env:ProgramFiles 'nodejs'
            $candidates += (Join-Path $nodeDir 'openclaw.cmd')
        }
    } else {
        foreach ($name in @('openclaw','openclaw.cmd','openclaw.ps1','openclaw.exe')) {
            try {
                $cmd = Get-Command $name -ErrorAction SilentlyContinue
                if ($cmd -and $cmd.Source) { $candidates += $cmd.Source }
            } catch {}
        }
        if ($env:AppData) {
            $npmBin = Join-Path $env:AppData 'npm'
            $candidates += (Join-Path $npmBin 'openclaw.cmd')
            $candidates += (Join-Path $npmBin 'openclaw.ps1')
        }
        if ($env:ProgramFiles) {
            $nodeDir = Join-Path $env:ProgramFiles 'nodejs'
            $candidates += (Join-Path $nodeDir 'openclaw.cmd')
        }
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }
    return ''
}

function Ensure-GatewayWrapper {
    $openclawCmd = Get-OpenClawCmd
    if ([string]::IsNullOrWhiteSpace($openclawCmd)) { return $false }
    if (-not $IsWindowsCompat) { return $true }

    $wrapperPath = Join-Path $OpenClawDir 'gateway.cmd'
    $wrapperDir = Split-Path $wrapperPath -Parent
    if (-not (Test-Path $wrapperDir)) {
        New-Item -ItemType Directory -Force -Path $wrapperDir | Out-Null
    }

    $escapedOpenClawCmd = $openclawCmd.Replace("'", "''")
    $content = @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Start-Process -FilePath '$escapedOpenClawCmd' -ArgumentList 'gateway','run' -WindowStyle Hidden"
"@
    Set-Content -Path $wrapperPath -Value $content -Encoding ASCII
    return (Test-Path $wrapperPath)
}

function Test-GatewayServiceInstalled {
    $txt = Get-GatewayStatusText
    return $txt -match 'Service:\s+(systemd|launchd|windows|service|scheduled task)'
}

function Test-GatewayRuntimeRunning {
    if (Test-GatewayHealth) { return $true }
    $txt = Get-GatewayStatusText
    if ([string]::IsNullOrWhiteSpace($txt)) { return $false }
    if ($txt -match 'Runtime:\s+running') { return $true }
    if ($txt -match 'Listening:\s+127\.0\.0\.1:' -or $txt -match 'Port\s+\d+\s+is already in use\.' -or $txt -match 'Gateway already running locally\.' -or $txt -match 'pairing required') { return $true }
    return $false
}

function Stop-OpenClaw {
    if (Test-Cmd 'openclaw') {
        try { & openclaw gateway stop | Out-Null } catch {}
    }
    Get-Process | Where-Object { $_.ProcessName -match 'openclaw' } | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Show-LogTail {
    param(
        [string]$Path,
        [int]$Tail = 80
    )
    if (Test-Path $Path) {
        Write-Host ("---- 日志尾部: {0} ----" -f $Path)
        Get-Content -Path $Path -Tail $Tail -ErrorAction SilentlyContinue
        Write-Host '----------------------------------------'
    }
}

function Show-ExceptionDetails {
    param($ErrorRecord)
    if (-not $ErrorRecord) { return }
    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Message) {
        Write-Host ("↳ {0}" -f $ErrorRecord.Exception.Message)
    }
    $detail = $null
    try { $detail = $ErrorRecord | Out-String } catch {}
    if ($detail) {
        $detail = $detail.Trim()
        if (-not [string]::IsNullOrWhiteSpace($detail)) {
            Write-Host $detail
        }
    }
}

function Start-OpenClaw {
    $openclawCmd = Get-OpenClawCmd
    if ([string]::IsNullOrWhiteSpace($openclawCmd)) {
        Write-Host '❌ 未检测到 openclaw 命令，无法启动 Gateway'
        return $false
    }
    if (Test-GatewayRuntimeRunning) { return $true }

    try {
        $startOutput = (& $openclawCmd gateway start 2>&1 | Out-String)
        if (-not [string]::IsNullOrWhiteSpace($startOutput)) {
            Write-Host $startOutput.Trim()
        }
    } catch {
        Write-Host '⚠️ openclaw gateway start 执行失败，尝试以前台方式拉起...'
        Show-ExceptionDetails $_
    }

    foreach ($i in 1..12) {
        if (Test-GatewayRuntimeRunning -or (Test-GatewayHealth)) { return $true }
        Start-Sleep -Seconds 1
    }

    try {
        Start-Process -FilePath $openclawCmd -ArgumentList 'gateway','run' -WindowStyle Hidden
    } catch {
        Write-Host "❌ Gateway 启动失败: $($_.Exception.Message)"
        Show-LogTail -Path $LogFile
        return $false
    }

    foreach ($i in 1..15) {
        if (Test-GatewayRuntimeRunning -or (Test-GatewayHealth)) { return $true }
        Start-Sleep -Seconds 1
    }

    Write-Host "❌ Gateway 启动失败，请检查日志: $LogFile"
    Show-LogTail -Path $LogFile
    return $false
}

function Test-GatewayReady {
    if (Test-GatewayHealth) { return $true }
    $status = Get-GatewayStatusText
    if ([string]::IsNullOrWhiteSpace($status)) { return $false }
    if ($status -match 'Listening:\s+127\.0\.0\.1:') { return $true }
    if ($status -match 'Port\s+\d+\s+is already in use\.' -or $status -match 'Gateway already running locally\.' -or $status -match 'pairing required') { return $true }
    return $false
}

function Restart-OpenClaw {
    Stop-OpenClaw
    foreach ($i in 1..8) {
        if (-not (Test-GatewayHealth)) { break }
        Start-Sleep -Seconds 1
    }
    if (Start-OpenClaw) {
        Clear-DirtyProviders
        return $true
    }
    return (Test-GatewayReady)
}

function Get-OpenClawVersion {
    if (-not (Test-Cmd 'openclaw')) { return 'unknown' }
    try {
        return ((& openclaw --version) | Select-Object -First 1).Trim()
    } catch {
        return 'unknown'
    }
}

function New-Token {
    return ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')).Substring(0,32)
}

function Write-DefaultConfig {
    $currentVersion = Get-OpenClawVersion
    $currDate = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.000Z")
    $genToken = New-Token
    $obj = [ordered]@{
        meta = [ordered]@{
            lastTouchedVersion = $currentVersion
            lastTouchedAt = $currDate
        }
        wizard = [ordered]@{
            lastRunAt = $currDate
            lastRunVersion = $currentVersion
            lastRunCommand = 'onboard'
            lastRunMode = 'local'
        }
        auth = @{ profiles = @{} }
        models = @{ providers = @{} }
        agents = [ordered]@{
            defaults = [ordered]@{
                model = @{ primary = ''; fallbacks = @() }
                models = @{}
                workspace = "$OpenClawDir\workspace"
                maxConcurrent = 4
                subagents = @{ maxConcurrent = 8 }
            }
        }
        messages = @{ ackReactionScope = 'group-mentions' }
        commands = @{ native = 'auto'; nativeSkills = 'auto'; restart = $true }
        hooks = @{ internal = @{ enabled = $true; entries = @{ 'boot-md' = @{ enabled = $true }; 'session-memory' = @{ enabled = $true } } } }
        channels = @{}
        gateway = [ordered]@{
            port = 52525
            mode = 'local'
            bind = 'loopback'
            auth = @{ mode = 'token'; token = $genToken }
            tailscale = @{ mode = 'off'; resetOnExit = $false }
            http = @{ endpoints = @{ chatCompletions = @{ enabled = $true } } }
            controlUi = @{ allowedOrigins = @('http://127.0.0.1:52525','http://localhost:52525') }
            trustedProxies = @('127.0.0.1/32','::1/128')
        }
        skills = @{ install = @{ nodeManager = 'npm' } }
        plugins = @{ entries = @{} }
    }
    return $obj
}

function Get-NodeMajorVersion {
    if (-not (Test-Cmd 'node')) { return 0 }
    try {
        $v = ((& node -v) -replace '^v','').Split('.')[0]
        return [int]$v
    } catch { return 0 }
}

function Test-IsAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Refresh-PathEnv {
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path','Machine')
    $userPath = [System.Environment]::GetEnvironmentVariable('Path','User')
    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($machinePath)) { $parts += $machinePath }
    if (-not [string]::IsNullOrWhiteSpace($userPath)) { $parts += $userPath }

    $extraPaths = @()
    if ($env:AppData) {
        $npmBin = Join-Path $env:AppData 'npm'
        if (Test-Path $npmBin) { $extraPaths += $npmBin }
    }
    if ($env:ProgramFiles) {
        $nodeDir = Join-Path $env:ProgramFiles 'nodejs'
        if (Test-Path $nodeDir) { $extraPaths += $nodeDir }
    }

    foreach ($p in $extraPaths) {
        if ($parts -notcontains $p) { $parts += $p }
    }

    if ($parts.Count -gt 0) {
        $env:Path = ($parts -join ';')
    }
}

function Install-Chocolatey {
    if (Test-Cmd 'choco') { return $true }
    if (-not (Test-IsAdmin)) {
        Write-Host '❌ 自动安装 Chocolatey 需要管理员权限，请使用“以管理员身份运行”的 PowerShell。'
        return $false
    }

    Write-Host '⚙️ 未检测到 winget/choco，正在自动安装 Chocolatey...'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
        $env:ChocolateyUseWindowsCompression = 'false'
        $script = Invoke-RestMethod -Uri 'https://community.chocolatey.org/install.ps1' -TimeoutSec 30
        Invoke-Expression $script
    } catch {
        Write-Host "❌ Chocolatey 安装失败: $($_.Exception.Message)"
        Show-ExceptionDetails $_
        return $false
    }

    Refresh-PathEnv
    if (Test-Cmd 'choco') {
        Write-Host '✅ Chocolatey 安装完成。'
        return $true
    }

    Write-Host '❌ Chocolatey 安装后仍不可用，请检查系统策略或网络环境。'
    return $false
}

function Ensure-PackageManager {
    if ((Test-Cmd 'winget') -or (Test-Cmd 'choco')) { return $true }
    return (Install-Chocolatey)
}

function Install-Git {
    if (Test-Cmd 'git') { return $true }
    Write-Host '⚙️ 未检测到 Git，正在自动安装...'
    if (-not (Ensure-PackageManager)) { return $false }

    if (Test-Cmd 'winget') {
        Write-Host 'ℹ️ 使用 winget 安装 Git ...'
        try {
            $wingetGitOutput = (& winget install Git.Git --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-String)
            if (-not [string]::IsNullOrWhiteSpace($wingetGitOutput)) {
                Write-Host $wingetGitOutput.Trim()
            }
        } catch {
            Write-Host "⚠️ winget 安装 Git 失败，尝试改用 Chocolatey: $($_.Exception.Message)"
            Show-ExceptionDetails $_
        }
    }

    if ((-not (Test-Cmd 'git')) -and (Test-Cmd 'choco')) {
        Write-Host 'ℹ️ 使用 Chocolatey 安装 Git ...'
        try {
            $chocoGitOutput = (& choco install git -y --no-progress 2>&1 | Out-String)
            if (-not [string]::IsNullOrWhiteSpace($chocoGitOutput)) {
                Write-Host $chocoGitOutput.Trim()
            }
        } catch {
            Write-Host "❌ Chocolatey 安装 Git 失败: $($_.Exception.Message)"
            Show-ExceptionDetails $_
            return $false
        }
    }

    Refresh-PathEnv
    if (Test-Cmd 'git') {
        try { Write-Host ("✅ Git 已就绪: {0}" -f ((& git --version) | Out-String).Trim()) } catch {}
        return $true
    }

    Write-Host '❌ Git 安装后仍不可用，请检查系统安装状态后重试。'
    return $false
}

function Prepare-NodeEnv {
    $nodeVer = Get-NodeMajorVersion
    if ((Test-Cmd 'npm') -and $nodeVer -ge 22) { return $true }

    Write-Host '⚙️ 正在准备 Node.js 22+ ...'
    if (-not (Ensure-PackageManager)) { return $false }

    if (Test-Cmd 'winget') {
        Write-Host 'ℹ️ 使用 winget 安装 Node.js LTS ...'
        try {
            $wingetOutput = (& winget install OpenJS.NodeJS.LTS --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-String)
            if (-not [string]::IsNullOrWhiteSpace($wingetOutput)) {
                Write-Host $wingetOutput.Trim()
            }
        } catch {
            Write-Host "⚠️ winget 安装 Node.js 失败，尝试改用 Chocolatey: $($_.Exception.Message)"
            Show-ExceptionDetails $_
        }
    }

    if (((-not (Test-Cmd 'npm')) -or ((Get-NodeMajorVersion) -lt 22)) -and (Test-Cmd 'choco')) {
        Write-Host 'ℹ️ 使用 Chocolatey 安装 Node.js LTS ...'
        try {
            $chocoOutput = (& choco install nodejs-lts -y --no-progress 2>&1 | Out-String)
            if (-not [string]::IsNullOrWhiteSpace($chocoOutput)) {
                Write-Host $chocoOutput.Trim()
            }
        } catch {
            Write-Host "❌ Chocolatey 安装 Node.js 失败: $($_.Exception.Message)"
            Show-ExceptionDetails $_
            return $false
        }
    }

    Refresh-PathEnv
    $nodeVer = Get-NodeMajorVersion
    if ((Test-Cmd 'npm') -and $nodeVer -ge 22) {
        Write-Host ("✅ Node.js 环境已就绪，当前版本: v{0}" -f $nodeVer)
        return $true
    }

    Write-Host '❌ Node.js 环境准备失败，当前 Node 版本不足 22，请检查系统安装状态后重试。'
    if (Test-Cmd 'node') {
        try { Write-Host ((& node -v) | Out-String).Trim() } catch {}
    }
    return $false
}

function Show-NpmDebugLog {
    $npmCache = $null
    try {
        $npmCache = ((& npm config get cache) | Out-String).Trim()
    } catch {}
    if ([string]::IsNullOrWhiteSpace($npmCache)) { return }

    Write-Host ("ℹ️ npm cache: {0}" -f $npmCache)
    $logsDir = Join-Path $npmCache '_logs'
    if (-not (Test-Path $logsDir)) { return }

    $latestLog = Get-ChildItem $logsDir -Filter '*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($latestLog) {
        Show-LogTail -Path $latestLog.FullName -Tail 120
    }
}

function Get-NpmCmd {
    $candidates = @()

    foreach ($name in @('npm.cmd','npm.ps1','npm.exe','npm')) {
        try {
            $cmd = Get-Command $name -ErrorAction SilentlyContinue
            if ($cmd -and $cmd.Source) { $candidates += $cmd.Source }
        } catch {}
    }

    if ($env:ProgramFiles) {
        $nodeDir = Join-Path $env:ProgramFiles 'nodejs'
        $candidates += (Join-Path $nodeDir 'npm.cmd')
        $candidates += (Join-Path $nodeDir 'npm')
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }
    return ''
}

function Install-OpenClawPackage {
    $log = Join-Path $env:TEMP 'ocm-npm-install.log'
    $ok = $false
    Write-Host ("ℹ️ npm 安装日志: {0}" -f $log)

    if (-not (Install-Git)) {
        Write-Host '❌ 安装失败：Git 依赖未准备完成。'
        return $false
    }

    $npmCmd = Get-NpmCmd
    if ([string]::IsNullOrWhiteSpace($npmCmd)) {
        Write-Host '❌ 未找到 npm 可执行文件。'
        return $false
    }
    Write-Host ("ℹ️ 使用 npm 命令: {0}" -f $npmCmd)

    try {
        $stdoutLog = Join-Path $env:TEMP 'ocm-npm-install.stdout.log'
        $stderrLog = Join-Path $env:TEMP 'ocm-npm-install.stderr.log'
        if (Test-Path $stdoutLog) { Remove-Item $stdoutLog -Force -ErrorAction SilentlyContinue }
        if (Test-Path $stderrLog) { Remove-Item $stderrLog -Force -ErrorAction SilentlyContinue }

        $proc = Start-Process -FilePath $npmCmd -ArgumentList 'install','-g','openclaw@latest' -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -PassThru -Wait -WindowStyle Hidden
        $combined = @()
        if (Test-Path $stdoutLog) { $combined += Get-Content $stdoutLog -ErrorAction SilentlyContinue }
        if (Test-Path $stderrLog) { $combined += Get-Content $stderrLog -ErrorAction SilentlyContinue }
        $combinedText = ($combined -join [Environment]::NewLine)
        $combinedText | Set-Content -Path $log -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($combinedText)) {
            Write-Host $combinedText.Trim()
        }

        Refresh-PathEnv
        $openclawCmd = Get-OpenClawCmd
        if (($proc.ExitCode -eq 0) -and (-not [string]::IsNullOrWhiteSpace($openclawCmd))) {
            Write-Host ("✅ OpenClaw 命令已安装: {0}" -f $openclawCmd)
            $ok = $true
        }
    } catch {
        Show-ExceptionDetails $_
        $content = if (Test-Path $log) { Get-Content $log -Raw -ErrorAction SilentlyContinue } else { '' }
        if ($content -match 'ENOTEMPTY') {
            Write-Host '⚠️ 检测到旧的 npm 全局安装残留，正在自动清理后重试...'
            try { & npm uninstall -g openclaw | Out-Null } catch {}
            try { Remove-Item -Recurse -Force (Join-Path ((& npm root -g).Trim()) 'openclaw') -ErrorAction SilentlyContinue } catch {}
            try { Get-ChildItem ((& npm root -g).Trim()) -Filter '.openclaw-*' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue } catch {}
            try { & npm cache verify | Out-Null } catch {}
            try {
                $retryStdout = Join-Path $env:TEMP 'ocm-npm-install.retry.stdout.log'
                $retryStderr = Join-Path $env:TEMP 'ocm-npm-install.retry.stderr.log'
                if (Test-Path $retryStdout) { Remove-Item $retryStdout -Force -ErrorAction SilentlyContinue }
                if (Test-Path $retryStderr) { Remove-Item $retryStderr -Force -ErrorAction SilentlyContinue }
                $retryProc = Start-Process -FilePath $npmCmd -ArgumentList 'install','-g','openclaw@latest' -RedirectStandardOutput $retryStdout -RedirectStandardError $retryStderr -PassThru -Wait -WindowStyle Hidden
                $retryCombined = @()
                if (Test-Path $retryStdout) { $retryCombined += Get-Content $retryStdout -ErrorAction SilentlyContinue }
                if (Test-Path $retryStderr) { $retryCombined += Get-Content $retryStderr -ErrorAction SilentlyContinue }
                $retryText = ($retryCombined -join [Environment]::NewLine)
                $retryText | Set-Content -Path $log -Encoding UTF8
                if (-not [string]::IsNullOrWhiteSpace($retryText)) {
                    Write-Host $retryText.Trim()
                }
                Refresh-PathEnv
                $openclawCmd = Get-OpenClawCmd
                if (($retryProc.ExitCode -eq 0) -and (-not [string]::IsNullOrWhiteSpace($openclawCmd))) {
                    Write-Host ("✅ OpenClaw 命令已安装: {0}" -f $openclawCmd)
                    $ok = $true
                }
            } catch {
                Show-ExceptionDetails $_
            }
        }
    }
    if (-not $ok) {
        $openclawCmd = Get-OpenClawCmd
        if ([string]::IsNullOrWhiteSpace($openclawCmd)) {
            Write-Host '⚠️ npm 命令执行后仍未找到 openclaw，可执行文件可能尚未生成或安装失败。'
            if ($env:AppData) {
                Write-Host ("ℹ️ 预期 npm 全局 bin 目录: {0}" -f (Join-Path $env:AppData 'npm'))
            }
        }
        Write-Host '❌ npm 安装 OpenClaw 失败。'
        Show-LogTail -Path $log -Tail 120
        Show-NpmDebugLog
        Write-Host 'ℹ️ 若错误码为 128，通常与 Git/网络/证书链有关。'
        return $false
    }
    return $true
}

function Install-OpenClaw {
    Write-Host "`n🚀 开始安装 OpenClaw..."
    Ensure-Dirs

    $installerUrl = 'https://in.cnno.de/install.ps1'
    $installerPath = Join-Path $env:TEMP 'openclaw-install.ps1'

    try {
        Invoke-WebRequest -Uri $installerUrl -UseBasicParsing -OutFile $installerPath
    } catch {
        Write-Host '❌ 下载官方安装脚本失败。'
        Show-ExceptionDetails $_
        Pause-OCM
        return
    }

    try {
        $installerContent = Get-Content $installerPath -Raw -Encoding UTF8
        $installerContent = $installerContent -replace "(?m)^\s*Refresh-GatewayServiceIfLoaded\s*$", "# Refresh-GatewayServiceIfLoaded (disabled by ocm)"
        Set-Content -Path $installerPath -Value $installerContent -Encoding UTF8
    } catch {
        Write-Host '⚠️ 无法预处理官方安装脚本，将继续原样执行。'
    }

    try {
        $existingOpenClawCmd = Get-OpenClawCmd
        if (-not [string]::IsNullOrWhiteSpace($existingOpenClawCmd)) {
            try { & $existingOpenClawCmd gateway stop | Out-Null } catch {}
        }
        Get-Process | Where-Object { $_.ProcessName -match 'openclaw' } | Stop-Process -Force -ErrorAction SilentlyContinue
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installerPath -NoOnboard
    } catch {
        Write-Host '❌ 官方安装脚本执行失败。'
        Show-ExceptionDetails $_
        Pause-OCM
        return
    }

    Refresh-PathEnv
    $openclawCmd = Get-OpenClawCmd
    if ([string]::IsNullOrWhiteSpace($openclawCmd)) {
        Write-Host '❌ 官方安装完成后仍未定位到 openclaw 可执行文件。'
        Pause-OCM
        return
    }

    Write-Host ("ℹ️ 使用命令: {0}" -f $openclawCmd)
    if (-not (Ensure-GatewayWrapper)) {
        Write-Host '⚠️ 未能生成 Windows Gateway 启动包装器，计划任务可能无法正常启动。'
    }

    Write-Host ("✅ 安装完成，当前 Gateway 端口: {0}" -f (Get-GatewayPort))
    Write-Host "`n📂 接下来配置大模型..."
    Add-PresetModel
    Write-Host "`n📱 接下来配置 channel..."
    Manage-Channels
    Write-Host '🎉 安装流程结束。'
}

function Get-ProviderDefaultApi {
    param([string]$Name)
    switch ($Name) {
        {$_ -in @('openai','openai-codex','openrouter','xai','mistral','deepseek','siliconflow','groq','cerebras','vercel-ai-gateway','github-copilot','synthetic','aliyun','qwen-portal','yi','moonshot','kimi-coding','volcengine','baichuan','ollama','google-gemini-cli')} { 'openai-responses'; break }
        {$_ -in @('anthropic','minimax','zai')} { 'anthropic-messages'; break }
        default { 'openai-completions' }
    }
}

function Ensure-ProvidersContainer {
    param($cfg)
    $models = Ensure-ObjectPath -Root $cfg -Path @('models')
    if (-not $models.PSObject.Properties['providers']) {
        $models | Add-Member -NotePropertyName 'providers' -NotePropertyValue ([pscustomobject]@{})
    }
}

function Get-Providers {
    if (-not (Test-Config)) { return @() }
    $cfg = Get-JsonConfig
    if (-not $cfg.models -or -not $cfg.models.providers) { return @() }
    return @($cfg.models.providers.PSObject.Properties.Name | Sort-Object)
}

function Get-Models {
    if (-not (Test-Config)) { return @() }
    $cfg = Get-JsonConfig
    $result = @()
    if ($cfg.models -and $cfg.models.providers) {
        foreach ($p in $cfg.models.providers.PSObject.Properties.Name) {
            $provider = $cfg.models.providers.$p
            if ($provider.models) {
                foreach ($m in $provider.models) {
                    $result += "$p/$($m.id)"
                }
            }
        }
    }
    return @($result | Sort-Object -Unique)
}

function Show-Providers {
    $providers = Get-Providers
    $i = 1
    foreach ($p in $providers) {
        Write-Host "$i) $p"
        $i++
    }
}

function Show-Models {
    $models = Get-Models
    $i = 1
    foreach ($m in $models) {
        Write-Host "$i) $m"
        $i++
    }
}

function Get-ProviderByIndex {
    param([string]$Index)
    $providers = @(Get-Providers)
    $i = [int]$Index - 1
    if ($i -lt 0 -or $i -ge @($providers).Count) { return $null }
    return @($providers)[$i]
}

function Get-ModelByIndex {
    param([string]$Index)
    $models = @(Get-Models)
    $i = [int]$Index - 1
    if ($i -lt 0 -or $i -ge @($models).Count) { return $null }
    return @($models)[$i]
}

function Save-ModelLogic {
    param(
        [string]$Provider,
        [string]$BaseUrl,
        [string]$ApiKey,
        [string]$Api,
        [string]$ModelId
    )
    $cfg = Get-JsonConfig
    Ensure-ProvidersContainer $cfg
    $providers = $cfg.models.providers
    $reasoning = ($ModelId -match 'r[1-9]|o[1-9]|reasoner|thinking')
    $modelObj = [pscustomobject]@{
        id = $ModelId
        name = $ModelId
        reasoning = $reasoning
        input = @('text','image')
        contextWindow = 200000
        maxTokens = 32000
        cost = @{ input = 0; output = 0; cacheRead = 0; cacheWrite = 0 }
    }
    $providerObj = [ordered]@{
        api = $Api
        apiKey = $ApiKey
        models = @($modelObj)
    }
    if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
        $providerObj.baseUrl = $BaseUrl
    }
    if ($providers.PSObject.Properties[$Provider]) {
        $cfg.models.providers.$Provider = [pscustomobject]$providerObj
    } else {
        $cfg.models.providers | Add-Member -NotePropertyName $Provider -NotePropertyValue ([pscustomobject]$providerObj)
    }

    $defaults = Ensure-ObjectPath -Root $cfg -Path @('agents','defaults','model')
    if (-not $defaults.primary) {
        $defaults.primary = "$Provider/$ModelId"
        $defaults.fallbacks = @("$Provider/$ModelId")
    }

    Save-JsonConfig $cfg
    Mark-ProviderDirty $Provider
    Write-Host '✅ 大模型配置已保存。'
    Write-Host 'ℹ️ 当前 provider 已标记为待生效；测试该模型或切换主模型时会自动重启。'
}

function Get-ProviderTestEndpoint {
    param([string]$Api,[string]$BaseUrl)
    $u = $BaseUrl.TrimEnd('/')
    switch ($Api) {
        'openai-responses' { return "$u/responses" }
        'anthropic-messages' { return "$u/v1/messages" }
        default { return "$u/chat/completions" }
    }
}

function New-TestPayload {
    param([string]$Api,[string]$Model)
    switch ($Api) {
        'openai-responses' { return @{ model = $Model; input = 'hi'; max_output_tokens = 16 } }
        'anthropic-messages' { return @{ model = $Model; max_tokens = 16; messages = @(@{ role = 'user'; content = 'hi' }) } }
        default { return @{ model = $Model; messages = @(@{ role = 'user'; content = 'hi' }); max_tokens = 16 } }
    }
}

function Validate-ApiConnectivity {
    param([string]$Provider)
    $cfg = Get-JsonConfig
    $p = $cfg.models.providers.$Provider
    if (-not $p) {
        Write-Host '❌ Provider 不存在'
        return $false
    }
    $modelId = $p.models[0].id
    $api = if ($p.api) { [string]$p.api } else { 'openai-completions' }
    $baseUrl = [string]$p.baseUrl
    $apiKey = [string]$p.apiKey

    if ([string]::IsNullOrWhiteSpace($modelId)) {
        Write-Host '❌ 未找到模型 ID'
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        Write-Host '❌ 未找到 BaseURL'
        return $false
    }

    Write-Host "`n🔍 开始测试 API 连通性: $Provider ..."
    $endpoint = Get-ProviderTestEndpoint -Api $api -BaseUrl $baseUrl
    $payload = New-TestPayload -Api $api -Model $modelId | ConvertTo-Json -Depth 10
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($api -eq 'anthropic-messages') {
        if ($apiKey) { $headers['x-api-key'] = $apiKey }
        $headers['anthropic-version'] = '2023-06-01'
    } elseif ($apiKey) {
        $headers['Authorization'] = "Bearer $apiKey"
    }

    try {
        $resp = Invoke-WebRequest -Method POST -Uri $endpoint -Headers $headers -Body $payload -TimeoutSec 30 -UseBasicParsing
        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
            Write-Host '✅ 连通性测试通过。'
            return $true
        }
        Write-Host ("❌ 上游请求失败 (HTTP {0})" -f $resp.StatusCode)
        return $false
    } catch {
        $ex = $_.Exception
        if ($ex.Response -and $ex.Response.StatusCode) {
            Write-Host ("❌ 上游请求失败 (HTTP {0})" -f [int]$ex.Response.StatusCode)
        } else {
            if ($baseUrl -match '127\.0\.0\.1|localhost|::1') {
                Write-Host "❌ 本地模型服务不可达：$baseUrl"
            } else {
                Write-Host "❌ 上游接口不可达：$baseUrl"
            }
        }
        if ($ex.Message) {
            Write-Host ("↳ {0}" -f $ex.Message)
        }
        return $false
    }
}

function Add-PresetModel {
    Write-Host "`n--- 快捷添加大模型 ---"
    Write-Host ' 1) OpenAI                 2) Anthropic             3) Google                4) xAI'
    Write-Host ' 5) Mistral                6) DeepSeek              7) SiliconFlow           8) Groq'
    Write-Host ' 9) Cerebras              10) OpenRouter          11) Vercel Gateway      12) OpenAI Codex'
    Write-Host '13) OpenCode              14) Ollama              15) Google Vertex       16) Gemini CLI'
    Write-Host '17) GitHub Copilot        18) Z.AI                19) Aliyun/Qwen         20) ZhiPu'
    Write-Host '21) Yi                    22) Moonshot            23) MiniMax             24) Tencent'
    Write-Host '25) Volcengine            26) Baichuan'
    Write-Host ' 0) 自定义中转'
    $choice = Read-Host '请选择编号 (回车跳过)'
    if ([string]::IsNullOrWhiteSpace($choice)) { return }

    $map = @{
        '1' = @('openai','https://api.openai.com/v1')
        '2' = @('anthropic','https://api.anthropic.com')
        '3' = @('google','https://generativelanguage.googleapis.com/v1beta/openai')
        '4' = @('xai','https://api.x.ai/v1')
        '5' = @('mistral','https://api.mistral.ai/v1')
        '6' = @('deepseek','https://api.deepseek.com/v1')
        '7' = @('siliconflow','https://api.siliconflow.cn/v1')
        '8' = @('groq','https://api.groq.com/openai/v1')
        '9' = @('cerebras','https://api.cerebras.ai/v1')
        '10' = @('openrouter','https://openrouter.ai/api/v1')
        '11' = @('vercel-ai-gateway','https://pro.api.vercel.com/v1')
        '12' = @('openai-codex','https://api.openai.com/v1')
        '13' = @('opencode','https://api.opencode.com/v1')
        '14' = @('ollama','http://127.0.0.1:11434/v1')
        '15' = @('google-vertex','https://us-central1-aiplatform.googleapis.com/v1')
        '16' = @('google-gemini-cli','http://127.0.0.1:9041/v1')
        '17' = @('github-copilot','https://api.githubcopilot.com/v1')
        '18' = @('zai','https://api.z.ai/api/anthropic')
        '19' = @('aliyun','https://dashscope.aliyuncs.com/compatible-mode/v1')
        '20' = @('zhipu','https://open.bigmodel.cn/api/paas/v4')
        '21' = @('yi','https://api.lingyiwanwu.com/v1')
        '22' = @('moonshot','https://api.moonshot.cn/v1')
        '23' = @('minimax','https://api.minimax.io/anthropic')
        '24' = @('tencent','https://api.hunyuan.cloud.tencent.com/v1')
        '25' = @('volcengine','https://ark.cn-beijing.volces.com/api/v3')
        '26' = @('baichuan','https://api.baichuan-ai.com/v1')
    }

    if ($choice -eq '0') { Add-ManualModel; return }
    if (-not $map.ContainsKey($choice)) { return }

    $name = $map[$choice][0]
    $url = $map[$choice][1]
    $api = Get-ProviderDefaultApi $name

    Write-Host "`n已选择: $name"
    Write-Host "API URL: $url"
    if ($url -match '127\.0\.0\.1|localhost|::1') {
        $confirm = Read-Host '检测到本地模型服务地址，确认继续测试/保存？(y/N)'
        if ($confirm -notmatch '^[Yy]$') { Write-Host '已取消。'; return }
    }
    $key = Read-Host '请输入 API Key (本地服务可回车跳过)'
    $mid = Read-Host '请输入模型 ID'
    if ([string]::IsNullOrWhiteSpace($mid)) { Write-Host '❌ 模型 ID 不能为空'; return }
    Save-ModelLogic -Provider $name -BaseUrl $url -ApiKey $key -Api $api -ModelId $mid
}

function Add-ManualModel {
    Write-Host "`n--- 添加自定义大模型 ---"
    $name = Read-Host 'Provider 名称'
    $url = Read-Host 'API BaseURL'
    $key = Read-Host 'API Key'
    $t = Read-Host '协议类型 (1: openai-responses, 2: openai-completions, 3: anthropic-messages) [默认2]'
    $api = switch ($t) {
        '1' { 'openai-responses' }
        '3' { 'anthropic-messages' }
        default { 'openai-completions' }
    }
    if ($url -match '127\.0\.0\.1|localhost|::1') {
        $confirm = Read-Host '检测到本地模型服务地址，确认继续测试/保存？(y/N)'
        if ($confirm -notmatch '^[Yy]$') { Write-Host '已取消。'; return }
    }
    $mid = Read-Host '模型 ID'
    if ([string]::IsNullOrWhiteSpace($mid)) { Write-Host '❌ 模型 ID 不能为空'; return }
    Save-ModelLogic -Provider $name -BaseUrl $url -ApiKey $key -Api $api -ModelId $mid
}

function Edit-Model {
    $providers = Get-Providers
    if (@($providers).Count -eq 0) { Write-Host '📭 当前未添加任何大模型配置'; Pause-OCM; return }
    Show-Providers
    $num = Read-Host '选择要修改的编号'
    if ([string]::IsNullOrWhiteSpace($num)) { return }
    $target = Get-ProviderByIndex $num
    if (-not $target) { return }

    $cfg = Get-JsonConfig
    $p = $cfg.models.providers.$target
    $cUrl = [string]$p.baseUrl
    $cKey = [string]$p.apiKey
    $cApi = if ($p.api) { [string]$p.api } else { 'openai-completions' }
    $cMid = [string]$p.models[0].id

    Write-Host "`n--- 修改 $target (回车保持原样) ---"
    $nName = Read-Host "Provider 名称 [$target]"
    if ([string]::IsNullOrWhiteSpace($nName)) { $nName = $target }

    if ($nName -ne $target) {
        if ($cfg.models.providers.PSObject.Properties[$nName]) {
            Write-Host "❌ Provider 名称已存在：$nName"
            Pause-OCM
            return
        }
        $providerValue = $cfg.models.providers.$target
        $cfg.models.providers | Add-Member -NotePropertyName $nName -NotePropertyValue $providerValue
        $copy = [ordered]@{}
        foreach ($prop in $cfg.models.providers.PSObject.Properties) {
            if ($prop.Name -ne $target) { $copy[$prop.Name] = $prop.Value }
        }
        $cfg.models.providers = [pscustomobject]$copy
        if ($cfg.agents.defaults.model.primary -like "$target/*") {
            $cfg.agents.defaults.model.primary = $cfg.agents.defaults.model.primary -replace "^$([regex]::Escape($target))/","$nName/"
        }
        if ($cfg.agents.defaults.model.fallbacks) {
            $cfg.agents.defaults.model.fallbacks = @($cfg.agents.defaults.model.fallbacks | ForEach-Object {
                if ($_ -like "$target/*") { $_ -replace "^$([regex]::Escape($target))/","$nName/" } else { $_ }
            })
        }
        Save-JsonConfig $cfg
        $target = $nName
        Write-Host "✅ Provider 名称已修改：$target"
    }

    $nUrl = Read-Host "BaseURL [$cUrl]"
    if ([string]::IsNullOrWhiteSpace($nUrl)) { $nUrl = $cUrl }
    $nKey = Read-Host 'API Key [已隐藏，回车保持]'
    if ([string]::IsNullOrWhiteSpace($nKey)) { $nKey = $cKey }
    $nType = Read-Host "协议 (1:openai-responses, 2:openai-completions, 3:anthropic-messages) [$cApi]"
    $nApi = switch ($nType) {
        '1' { 'openai-responses' }
        '2' { 'openai-completions' }
        '3' { 'anthropic-messages' }
        default { $cApi }
    }
    $nMid = Read-Host "模型ID [$cMid]"
    if ([string]::IsNullOrWhiteSpace($nMid)) { $nMid = $cMid }

    Save-ModelLogic -Provider $target -BaseUrl $nUrl -ApiKey $nKey -Api $nApi -ModelId $nMid
    $runNow = Read-Host '是否立即重启并测试？(y/N)'
    if ($runNow -match '^[Yy]$') {
        Write-Host '⚙️ 正在重启 Gateway 以加载最新模型配置...'
        if (Restart-OpenClaw) {
            [void](Validate-ApiConnectivity $target)
        } else {
            Write-Host '❌ Gateway 重启失败，无法执行测试'
        }
    }
    Pause-OCM
}

function Delete-Model {
    $providers = Get-Providers
    if (@($providers).Count -eq 0) { Write-Host '📭 当前未添加任何大模型配置'; Pause-OCM; return }
    Show-Providers
    $num = Read-Host '选择要删除的编号'
    $target = Get-ProviderByIndex $num
    if (-not $target) { return }

    $cfg = Get-JsonConfig
    $copy = [ordered]@{}
    foreach ($prop in $cfg.models.providers.PSObject.Properties) {
        if ($prop.Name -ne $target) { $copy[$prop.Name] = $prop.Value }
    }
    $cfg.models.providers = [pscustomobject]$copy
    if ($cfg.agents.defaults.model.primary -like "$target/*") {
        $first = Get-Models | Select-Object -First 1
        if ($first) {
            $cfg.agents.defaults.model.primary = $first
            $cfg.agents.defaults.model.fallbacks = @($first)
        } else {
            $cfg.agents.defaults.model.primary = ''
            $cfg.agents.defaults.model.fallbacks = @()
        }
    }
    Save-JsonConfig $cfg
    Mark-ProviderDirty $target
    Write-Host "✅ 已删除: $target"
    Write-Host 'ℹ️ 当前 provider 删除已保存；下次需要加载新配置时会自动重启。'
    Pause-OCM
}

function Manage-Models {
    Write-Host "`n--- 管理大模型配置 ---"
    Write-Host '1) 修改大模型配置'
    Write-Host '2) 删除大模型配置'
    Write-Host '0) 返回'
    Write-Host '------------------------------------------------'
    $c = Read-Host '请选择操作'
    switch ($c) {
        '1' { Edit-Model }
        '2' { Delete-Model }
        default { return }
    }
}

function Test-ApiMenu {
    $providers = Get-Providers
    if (@($providers).Count -eq 0) { Write-Host '📭 当前未添加任何大模型配置，无法测试'; Pause-OCM; return }
    while ($true) {
        Write-Host "`n--- 测试 API 可用性 ---"
        Show-Providers
        Write-Host '0) 返回主菜单'
        $n = Read-Host '测试编号'
        if ([string]::IsNullOrWhiteSpace($n) -or $n -eq '0') { return }
        $target = Get-ProviderByIndex $n
        if (-not $target) { Write-Host '❌ 编号无效，请重试'; continue }
        if (Test-ProviderDirty $target) {
            Write-Host "⚙️ 检测到 $target 有未生效的配置变更，正在重启 Gateway..."
            if (Restart-OpenClaw) {
                [void](Validate-ApiConnectivity $target)
            } else {
                Write-Host '❌ Gateway 重启失败，无法执行测试'
            }
        } else {
            [void](Validate-ApiConnectivity $target)
        }
    }
}

function Switch-Model {
    $models = Get-Models
    if (@($models).Count -eq 0) { Write-Host '📭 当前未添加任何大模型配置'; Pause-OCM; return }
    $cfg = Get-JsonConfig
    $currentModel = $cfg.agents.defaults.model.primary
    if ([string]::IsNullOrWhiteSpace([string]$currentModel)) { $currentModel = '未设置' }
    Write-Host ("当前使用的模型: {0}" -f $currentModel)
    Show-Models
    $num = Read-Host '选择新主模型(回车返回)'
    if ([string]::IsNullOrWhiteSpace($num)) { return }
    $selected = Get-ModelByIndex $num
    if (-not $selected) { return }
    $cfg.agents.defaults.model.primary = $selected
    $cfg.agents.defaults.model.fallbacks = @($selected)
    Save-JsonConfig $cfg
    if (Restart-OpenClaw) {
        Write-Host "✅ 默认主模型已切换为 $selected"
    } else {
        Write-Host '❌ Gateway 重启失败'
    }
    Pause-OCM
}

function Add-CorsOrigin {
    $cfg = Get-JsonConfig
    $allowed = @()
    if ($cfg.gateway.controlUi.allowedOrigins) { $allowed = @($cfg.gateway.controlUi.allowedOrigins) }
    Write-Host ("当前允许跨域请求的域名: [{0}]" -f (($allowed -join ', ')))
    $raw = Read-Host '输入新增域名 (回车跳过)'
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $origin = $raw.Trim()
    if ($origin -notmatch '^https?://') {
        if ($origin -match '^(localhost|127\.0\.0\.1|::1)(:\d+)?') { $origin = "http://$origin" }
        else { $origin = "https://$origin" }
    }
    $cfg.gateway.controlUi.allowedOrigins = @($allowed + $origin | Select-Object -Unique)
    Save-JsonConfig $cfg
    Write-Host "✅ 已添加域名: $origin"
}

function Set-Port {
    $cfg = Get-JsonConfig
    $old = Get-GatewayPort
    $np = Read-Host "当前网关端口 $old, 输入新端口 (回车跳过)"
    if (-not [string]::IsNullOrWhiteSpace($np)) {
        if ($np -notmatch '^\d+$') { Write-Host '❌ 端口必须是数字'; Pause-OCM; return }
        $cfg.gateway.port = [int]$np
        $origins = @($cfg.gateway.controlUi.allowedOrigins)
        $cfg.gateway.controlUi.allowedOrigins = @($origins | ForEach-Object {
            $_ -replace ":$old$",":$np"
        } | Select-Object -Unique)
        Save-JsonConfig $cfg
    }
    Add-CorsOrigin
    [void](Restart-OpenClaw)
    Pause-OCM
}

function Approve-DevicesInternal {
    $openclawCmd = Get-OpenClawCmd
    if ([string]::IsNullOrWhiteSpace($openclawCmd)) { return 0 }
    $txt = (& $openclawCmd devices list 2>$null | Out-String)
    $ids = [regex]::Matches($txt, '[0-9a-fA-F-]{36}') | ForEach-Object { $_.Value } | Select-Object -Unique
    if (-not $ids) { return 0 }
    $count = 0
    foreach ($id in $ids) {
        try { & $openclawCmd devices approve $id | Out-Null; $count++ } catch {}
    }
    return $count
}

function Approve-Devices {
    $openclawCmd = Get-OpenClawCmd
    if ([string]::IsNullOrWhiteSpace($openclawCmd)) { Write-Host '❌ 未检测到 openclaw'; Pause-OCM; return }
    $count = Approve-DevicesInternal
    if ($count -le 0) { Write-Host '📭 当前无待授权设备'; Pause-OCM; return }
    Write-Host "✅ 已批准 $count 台终端设备"
    Pause-OCM
}

function Show-GatewayToken {
    Write-Host "`n--- Gateway Token ---"
    Write-Host ("Token: {0}" -f (Get-GatewayToken))
    Write-Host ("地址: http://127.0.0.1:{0}/v1/chat/completions" -f (Get-GatewayPort))
    Write-Host '------------------------------------------------'
    Pause-OCM
}

function Show-GatewayLogs {
    if (Test-Path $LogFile) {
        Get-Content $LogFile -Tail 120 -ErrorAction SilentlyContinue
    } else {
        try {
            Get-Process | Where-Object { $_.ProcessName -match 'openclaw' } | Format-Table -AutoSize
        } catch {}
    }
}

function Gateway-Manage {
    $gwPort = Get-GatewayPort
    $status = if (Test-GatewayRuntimeRunning) { '运行中' } elseif ((Test-GatewayServiceInstalled) -and (Test-GatewayHealth)) { '运行中（端口可达，但服务未接管）' } elseif (Test-GatewayServiceInstalled) { '未运行（服务已安装但未启动）' } elseif (Test-GatewayHealth) { '运行中（前台/手动启动）' } else { '未运行' }
    Write-Host "`n--- Gateway 管理 ---"
    Write-Host "当前状态: $status (端口: $gwPort)"
    Write-Host '1) 启动 Gateway'
    Write-Host '2) 重启 Gateway'
    Write-Host '3) 停止 Gateway'
    Write-Host '4) 查看日志'
    Write-Host '0) 返回'
    Write-Host '------------------------------------------------'
    $c = Read-Host '请选择操作'
    switch ($c) {
        '1' { if (Start-OpenClaw) { Write-Host '✅ Gateway 已启动' } else { Write-Host '❌ Gateway 启动失败' }; Pause-OCM }
        '2' { if (Restart-OpenClaw) { Write-Host '✅ Gateway 已重启' } else { Write-Host '❌ Gateway 重启失败' }; Pause-OCM }
        '3' { Stop-OpenClaw; Write-Host '✅ Gateway 已停止'; Pause-OCM }
        '4' { Show-GatewayLogs; Pause-OCM }
        default { return }
    }
}

function Get-Channels {
    if (-not (Test-Config)) { return @() }
    $cfg = Get-JsonConfig
    if (-not $cfg.channels) { return @() }
    return @($cfg.channels.PSObject.Properties.Name | Sort-Object)
}

function Show-Channels {
    $cfg = Get-JsonConfig
    $channels = Get-Channels
    $i = 1
    foreach ($c in $channels) {
        $type = $cfg.channels.$c.type
        if ($type) { Write-Host "$i) $c [$type]" } else { Write-Host "$i) $c" }
        $i++
    }
}

function Get-ChannelByIndex {
    param([string]$Index)
    $channels = @(Get-Channels)
    $i = [int]$Index - 1
    if ($i -lt 0 -or $i -ge @($channels).Count) { return $null }
    return @($channels)[$i]
}

function Add-Channel {
    Write-Host "`n--- 添加 channel ---"
    Write-Host '1) WhatsApp'
    Write-Host '2) Telegram Bot'
    Write-Host '3) Discord'
    Write-Host '4) 企业微信 (WeCom)'
    $t = Read-Host '选择 (回车跳过)'
    if ([string]::IsNullOrWhiteSpace($t)) { return }

    $cfg = Get-JsonConfig
    Ensure-ObjectPath -Root $cfg -Path @('channels') | Out-Null
    switch ($t) {
        '1' {
            $cn = Read-Host 'channel 名称'
            $ct = Read-Host 'Access Token'
            $pid = Read-Host 'Phone Number ID'
            $cfg.channels | Add-Member -Force -NotePropertyName $cn -NotePropertyValue ([pscustomobject]@{ type = 'whatsapp'; token = $ct; phoneId = $pid; enabled = $true })
        }
        '2' {
            $ct = Read-Host 'Telegram机器人Token'
            $uid = Read-Host 'Telegram机器人用户ID'
            if ([string]::IsNullOrWhiteSpace($ct) -or [string]::IsNullOrWhiteSpace($uid)) { Write-Host '❌ Telegram 参数不能为空'; return }
            $cfg.channels.telegram = [pscustomobject]@{ botToken = $ct; allowFrom = @($uid); dmPolicy = 'allowlist'; enabled = $true }
        }
        '3' {
            $cn = Read-Host 'channel 名称'
            $ct = Read-Host 'Bot Token'
            $cfg.channels | Add-Member -Force -NotePropertyName $cn -NotePropertyValue ([pscustomobject]@{ type = 'discord'; token = $ct; enabled = $true })
        }
        '4' {
            $cn = Read-Host 'channel 名称'
            $aid = Read-Host 'AgentId'
            $sec = Read-Host 'Secret'
            $cfg.channels | Add-Member -Force -NotePropertyName $cn -NotePropertyValue ([pscustomobject]@{ type = 'wecom'; agentId = $aid; secret = $sec; enabled = $true })
        }
        default { return }
    }
    Save-JsonConfig $cfg
    [void](Restart-OpenClaw)
    Write-Host '✅ channel 已保存！'
}

function Delete-Channel {
    $channels = Get-Channels
    if (@($channels).Count -eq 0) { Write-Host '📭 当前未添加任何 channel'; Pause-OCM; return }
    Show-Channels
    $num = Read-Host '选择要删除的 channel 编号'
    $target = Get-ChannelByIndex $num
    if (-not $target) { return }
    $cfg = Get-JsonConfig
    $copy = [ordered]@{}
    foreach ($prop in $cfg.channels.PSObject.Properties) {
        if ($prop.Name -ne $target) { $copy[$prop.Name] = $prop.Value }
    }
    $cfg.channels = [pscustomobject]$copy
    Save-JsonConfig $cfg
    [void](Restart-OpenClaw)
    Write-Host "✅ 已删除 channel: $target"
    Pause-OCM
}

function Manage-Channels {
    Write-Host "`n--- 管理设置 channel ---"
    Write-Host '1) 添加 channel'
    Write-Host '2) 删除 channel'
    Write-Host '回车) 返回主菜单'
    Write-Host '------------------------------------------------'
    $c = Read-Host '请选择操作'
    switch ($c) {
        '1' { Add-Channel; Pause-OCM }
        '2' { Delete-Channel }
        default { return }
    }
}

function Upgrade-OpenClaw {
    Write-Host "`n🔄 正在升级 OpenClaw..."
    if (-not (Test-Cmd 'npm')) { Write-Host '❌ npm 不存在'; return }
    if (Install-OpenClawPackage) {
        [void](Restart-OpenClaw)
        Write-Host '✅ 升级完成。'
    } else {
        Write-Host '❌ 升级失败。'
    }
}

function Manage-Installation {
    Write-Host "`n--- 升级/重置/卸载管理 ---"
    Write-Host '1) 备份后重建默认配置'
    Write-Host '2) 升级 OpenClaw 到最新版本'
    Write-Host '3) 直接重置 OpenClaw'
    Write-Host '4) 仅卸载 OpenClaw 程序（保留 ~/.openclaw 数据）'
    Write-Host '5) 彻底卸载 OpenClaw（删除 ~/.openclaw 全部数据）'
    Write-Host '0) 取消并返回主菜单'
    Write-Host '------------------------------------------------'
    $c = Read-Host '请选择操作'
    switch ($c) {
        '1' {
            $confirm = Read-Host '确认备份当前配置并重建默认配置？(y/N)'
            if ($confirm -match '^[Yy]$') {
                Ensure-Dirs
                Backup-Config
                Save-JsonConfig (Write-DefaultConfig)
                [void](Restart-OpenClaw)
                Write-Host '✅ 默认配置已重建。'
            }
            Pause-OCM
        }
        '2' { Upgrade-OpenClaw; Pause-OCM }
        '3' {
            $confirm = Read-Host '确认直接重置 OpenClaw？(y/N)'
            if ($confirm -match '^[Yy]$') {
                try { & openclaw reset | Out-Null } catch {
                    Backup-Config
                    if (Test-Path $Config) { Remove-Item $Config -Force }
                    Save-JsonConfig (Write-DefaultConfig)
                }
                [void](Restart-OpenClaw)
                Write-Host '✅ 已重置。'
            }
            Pause-OCM
        }
        '4' {
            $confirm = Read-Host '确认仅卸载 OpenClaw 程序，并保留 ~/.openclaw 数据？(y/N)'
            if ($confirm -match '^[Yy]$') {
                Stop-OpenClaw
                try { & npm uninstall -g openclaw | Out-Null } catch {}
                Write-Host '✅ OpenClaw 程序已卸载，数据已保留。'
            }
            Pause-OCM
        }
        '5' {
            $confirm = Read-Host '确认彻底卸载 OpenClaw 并删除 ~/.openclaw 全部数据？(y/N)'
            if ($confirm -match '^[Yy]$') {
                Stop-OpenClaw
                try { & npm uninstall -g openclaw | Out-Null } catch {}
                Remove-Item -Recurse -Force $OpenClawDir -ErrorAction SilentlyContinue
                Write-Host '✅ OpenClaw 已彻底卸载完成。'
            }
            Pause-OCM
        }
        default { return }
    }
}

function Show-Menu {
    Clear-Host
    Write-Host '🍀 OpenClaw 全能管理助手 stable+ (Windows PowerShell)'
    Write-Host '------------------------------------------------'
    Write-Host '1.  🚀 安装 OpenClaw'
    Write-Host '2.  📂 快捷添加大模型'
    Write-Host '3.  ⚙️ 管理大模型配置'
    Write-Host '4.  🤖 切换默认主模型'
    Write-Host '5.  📱 管理设置 channel'
    Write-Host '6.  🛠️ 测试 API 可用性'
    Write-Host '7.  🔌 修改端口/添加域名'
    Write-Host '8.  🔑 一键批准终端设备'
    Write-Host '9.  🔄 Gateway 管理'
    Write-Host '10. 🔎 查询 Gateway Token'
    Write-Host '11. ⚠️ 升级/重置/卸载管理'
    Write-Host '0.  退出'
    Write-Host '------------------------------------------------'
}

if (-not (Ensure-PowerShell7)) { return }
Ensure-Dirs
if (-not $env:OCM_NO_LOOP) {
    while ($true) {
        Show-Menu
        $choice = Read-Host '请选择操作'
        switch ($choice) {
            '1' { Install-OpenClaw }
            '2' { if (Test-Config) { Add-PresetModel; Pause-OCM } }
            '3' { if (Test-Config) { Manage-Models } }
            '4' { if (Test-Config) { Switch-Model } }
            '5' { if (Test-Config) { Manage-Channels } }
            '6' { if (Test-Config) { Test-ApiMenu } }
            '7' { if (Test-Config) { Set-Port } }
            '8' { if (Test-Config) { Approve-Devices } }
            '9' { if (Test-Config) { Gateway-Manage } }
            '10' { if (Test-Config) { Show-GatewayToken } }
            '11' { Manage-Installation }
            '0' { return }
            default { }
        }
    }
}
