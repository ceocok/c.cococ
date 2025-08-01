<#
.SYNOPSIS
    A PowerShell script to deploy frpc as a Windows service using a proxied, direct download for NSSM.
.DESCRIPTION
    This custom-tailored script uses a proxy for all GitHub downloads and fetches nssm.exe directly
    from a user-provided URL. It properly uses NSSM to wrap frpc.exe as a robust, auto-restarting
    Windows service. Includes defaults for common settings like server address, proxy name, local IP, and local port.
.AUTHOR
    Generated based on a request.
.VERSION
    5.2 (Interactive LocalIP with Default)
.USAGE
    To run interactively from web:
    powershell -ExecutionPolicy Bypass -Command "iex ((New-Object System.Net.WebClient).DownloadString('https://gh.cococ.co/https://raw.githubusercontent.com/ceocok/c.cococ/refs/heads/main/frpc.ps1'))"

    To run locally:
    .\frpc.ps1
.LINK
    https://github.com/ceocok/c.cococ/
#>

#requires -RunAsAdministrator

#region Script Configuration and Initialization
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Directly perform an action without showing the menu.")]
    [ValidateSet('Install', 'Uninstall', 'Start', 'Stop', 'Restart', 'Status', 'ViewConfig', 'EditConfig', 'ViewLog')]
    [string]$Action
)

# --- IMPORTANT: Force modern TLS for GitHub downloads ---
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Warning "Could not set TLS 1.2. Network operations might fail on older systems."
}

# --- Global Variables ---
$FRP_VERSION    = "0.63.0"
$FRP_BASE_DIR   = "C:\frp"
$SERVICE_NAME   = "frpc"
$ARCH           = "amd64" # or "386" for 32-bit systems

# --- Proxied Download URLs ---
$PROXY_PREFIX   = "https://gh.cococ.co/"
$frpOriginalUrl = "https://github.com/fatedier/frp/releases/download/v$($FRP_VERSION)/frp_${FRP_VERSION}_windows_${ARCH}.zip"
$nssmOriginalUrl= "https://raw.githubusercontent.com/ceocok/c.cococ/refs/heads/main/nssm.exe"

$proxiedFrpUrl  = $PROXY_PREFIX + $frpOriginalUrl
$proxiedNssmUrl = $PROXY_PREFIX + $nssmOriginalUrl

# --- Dynamically generated paths ---
$NSSM_EXE       = Join-Path $FRP_BASE_DIR "nssm.exe"
$FRPC_EXE       = Join-Path $FRP_BASE_DIR "frpc.exe"
$CONFIG_FILE    = Join-Path $FRP_BASE_DIR "frpc.toml"
$LOG_FILE       = Join-Path $FRP_BASE_DIR "frpc.log"
#endregion

#region Helper Functions
function Write-Styled-Header($Title) {
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host ("      $Title") -ForegroundColor White
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host ""
}

function Pause-Script($Message = "Press Enter to return to the menu...") {
    Write-Host ""
    Read-Host -Prompt $Message
}
#endregion

#region Core Functions
function Install-FrpcService {
    Write-Styled-Header "Installing frpc Service (via Proxied NSSM)"
    
    if (Get-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue) {
        $confirm = Read-Host "Frpc service already exists. Do you want to reinstall? (This will overwrite the config) [y/n]"
        if ($confirm -ne 'y') { return }
        Uninstall-FrpcService -Silent
    }

    if (-not (Test-Path $FRP_BASE_DIR)) {
        Write-Host "Creating directory: $FRP_BASE_DIR" -ForegroundColor Yellow
        New-Item -Path $FRP_BASE_DIR -ItemType Directory -Force | Out-Null
    }

    try {
        # Download and extract frp via proxy
        $frpZip = Join-Path $FRP_BASE_DIR "frp.zip"
        Write-Host "Downloading frp from $proxiedFrpUrl..." -ForegroundColor Green
        Invoke-WebRequest -Uri $proxiedFrpUrl -OutFile $frpZip -UseBasicParsing
        Write-Host "Extracting frp..." -ForegroundColor Green
        Expand-Archive -Path $frpZip -DestinationPath $FRP_BASE_DIR -Force
        Move-Item -Path (Join-Path $FRP_BASE_DIR "frp_${FRP_VERSION}_windows_${ARCH}\frpc.exe") -Destination $FRPC_EXE -Force

        # Download nssm.exe directly via proxy
        Write-Host "Downloading nssm.exe from $proxiedNssmUrl..." -ForegroundColor Green
        Invoke-WebRequest -Uri $proxiedNssmUrl -OutFile $NSSM_EXE -UseBasicParsing
    }
    catch {
        Write-Error "A critical error occurred during download or extraction."
        Write-Error "Failing Command: $($_.InvocationInfo.Line.Trim())"
        Write-Error "Error Details: $($_.Exception.Message)"
        Pause-Script
        return
    }

    # --- Configure frpc.toml ---
    Write-Host "`n--- Configuring frpc.toml ---" -ForegroundColor Yellow

    # Server Address with default
    $serverAddrInput = Read-Host "Enter your frps server address [default: 118.31.43.162]"
    $serverAddr = if ([string]::IsNullOrWhiteSpace($serverAddrInput)) { "118.31.43.162" } else { $serverAddrInput }

    # Proxy Name with dynamic default
    $defaultProxyName = "frpc$(Get-Date -Format 'MMddHHmm')"
    $proxyNameInput = Read-Host "Enter a name for this proxy [default: $defaultProxyName]"
    $proxyName = if ([string]::IsNullOrWhiteSpace($proxyNameInput)) { $defaultProxyName } else { $proxyNameInput }

    # Proxy Type with default
    $proxyType = Read-Host "Enter proxy type (tcp/udp/http/https) [default: tcp]"
    if ([string]::IsNullOrWhiteSpace($proxyType)) { $proxyType = "tcp" }

    # <<< NEW: Local IP with default >>>
    $localIpInput = Read-Host "Enter the local IP to forward [default: 127.0.0.1]"
    $localIp = if ([string]::IsNullOrWhiteSpace($localIpInput)) { "127.0.0.1" } else { $localIpInput }

    # Local Port with default
    $localPortInput = Read-Host "Enter the local port to forward (e.g., 3389 for RDP) [default: 3389]"
    $localPort = if ([string]::IsNullOrWhiteSpace($localPortInput)) { "3389" } else { $localPortInput }
    
    # Remote Port (no default, must be specified)
    $remotePort = Read-Host "Enter the remote port on the server"
    
    $configContent = @"
# frpc.toml - Generated by PowerShell script
serverAddr = "$serverAddr"
serverPort = 7000

[[proxies]]
name = "$proxyName"
type = "$proxyType"
localIP = "$localIp"
localPort = $localPort
remotePort = $remotePort
"@
    $utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($CONFIG_FILE, $configContent, $utf8NoBomEncoding)

    Write-Host "Configuration file created at $CONFIG_FILE" -ForegroundColor Green

    # Install the service using nssm
    Write-Host "`n--- Installing frpc as a Windows Service using NSSM ---" -ForegroundColor Yellow
    & $NSSM_EXE install $SERVICE_NAME $FRPC_EXE "-c `"$CONFIG_FILE`""
    & $NSSM_EXE set $SERVICE_NAME DisplayName "FRP Client Service (frpc)"
    & $NSSM_EXE set $SERVICE_NAME Description "Manages the frp client for reverse proxy connections."
    & $NSSM_EXE set $SERVICE_NAME AppDirectory $FRP_BASE_DIR
    & $NSSM_EXE set $SERVICE_NAME Start SERVICE_AUTO_START
    & $NSSM_EXE set $SERVICE_NAME AppStdout $LOG_FILE
    & $NSSM_EXE set $SERVICE_NAME AppStderr $LOG_FILE
    & $NSSM_EXE set $SERVICE_NAME AppRotateFiles 1
    & $NSSM_EXE set $SERVICE_NAME AppRotateBytes 1048576 # 1MB

    # Cleanup
    Write-Host "`nCleaning up temporary files..." -ForegroundColor Yellow
    Remove-Item -Path (Join-Path $FRP_BASE_DIR "frp_${FRP_VERSION}_windows_${ARCH}"), $frpZip -Recurse -Force

    Write-Host "`n--- Installation Complete! ---" -ForegroundColor Green
    Start-FrpcService
    Pause-Script
}

function Uninstall-FrpcService {
    param($Silent = $false)

    if (-not $Silent) { Write-Styled-Header "Uninstalling frpc Service" }
    
    $service = Get-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
    if (-not $service) {
        if (-not $Silent) { Write-Host "frpc service is not installed." -ForegroundColor Yellow }
    } else {
        Write-Host "Stopping and removing service '$SERVICE_NAME'..." -ForegroundColor Yellow
        Stop-Service -Name $SERVICE_NAME -Force -ErrorAction SilentlyContinue
        if(Test-Path $NSSM_EXE) {
            & $NSSM_EXE remove $SERVICE_NAME confirm | Out-Null
        } else {
            sc.exe delete $SERVICE_NAME | Out-Null
        }
    }

    if (Test-Path $FRP_BASE_DIR) {
        Write-Host "Deleting installation directory: $FRP_BASE_DIR" -ForegroundColor Yellow
        Remove-Item -Path $FRP_BASE_DIR -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    if (-not $Silent) {
        Write-Host "`n--- Uninstallation Complete ---" -ForegroundColor Green
        Pause-Script
    }
}

# --- Other functions (Start, Stop, Restart, Status, Config, Log) remain the same ---
function Start-FrpcService {
    Write-Styled-Header "Starting frpc Service"
    Start-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
    Get-FrpcStatus
}

function Stop-FrpcService {
    Write-Styled-Header "Stopping frpc Service"
    Stop-Service -Name $SERVICE_NAME -Force -ErrorAction SilentlyContinue
    Get-FrpcStatus
}

function Restart-FrpcService {
    Write-Styled-Header "Restarting frpc Service"
    Restart-Service -Name $SERVICE_NAME -Force -ErrorAction SilentlyContinue
    Get-FrpcStatus
}

function Get-FrpcStatus {
    $service = Get-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
    if ($service) {
        $service | Format-List -Property Name, DisplayName, Status, StartType
    } else {
        Write-Host "Service '$SERVICE_NAME' is not installed." -ForegroundColor Red
    }
    Pause-Script
}

function Show-FrpcConfig {
    Write-Styled-Header "Configuration: $CONFIG_FILE"
    if (Test-Path $CONFIG_FILE) {
        Get-Content $CONFIG_FILE | Write-Host
    } else {
        Write-Host "Configuration file not found." -ForegroundColor Red
    }
    Pause-Script
}

function Edit-FrpcConfig {
    Write-Styled-Header "Editing Configuration"
    if (Test-Path $CONFIG_FILE) {
        Write-Host "Opening configuration file in Notepad..."
        Start-Process notepad.exe -ArgumentList $CONFIG_FILE
        Write-Host "Please restart the frpc service for changes to take effect." -ForegroundColor Yellow
    } else {
        Write-Host "Configuration file not found." -ForegroundColor Red
    }
    Pause-Script
}

function Show-FrpcLog {
    Write-Styled-Header "Log File: $LOG_FILE"
    if (Test-Path $LOG_FILE) {
        Write-Host "Opening log file in Notepad..."
        Start-Process notepad.exe -ArgumentList $LOG_FILE
    } else {
        Write-Host "Log file not found. It will be created when the service runs." -ForegroundColor Red
    }
    Pause-Script
}

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Styled-Header "FRP Client Manager (v5.2 - Interactive Defaults)"

        Write-Host " [Installation]" -ForegroundColor Magenta
        Write-Host "   1. Install/Reinstall frpc Service (Recommended)" -ForegroundColor Green
        Write-Host "   2. Uninstall frpc Service" -ForegroundColor Red
        Write-Host ""
        Write-Host " [Service Control]" -ForegroundColor Magenta
        Write-Host "   3. Start frpc Service" -ForegroundColor Green
        Write-Host "   4. Stop frpc Service" -ForegroundColor Green
        Write-Host "   5. Restart frpc Service" -ForegroundColor Green
        Write-Host "   6. View Service Status" -ForegroundColor Green
        Write-Host ""
        Write-Host " [Files & Logs]" -ForegroundColor Magenta
        Write-Host "   7. View Configuration" -ForegroundColor Green
        Write-Host "   8. Edit Configuration" -ForegroundColor Green
        Write-Host "   9. View Log" -ForegroundColor Green
        Write-Host ""
        Write-Host "   0. Exit" -ForegroundColor Yellow

        $choice = Read-Host "`nPlease select an option [0-9]"

        switch ($choice) {
            '1' { Install-FrpcService }
            '2' { Uninstall-FrpcService }
            '3' { Start-FrpcService }
            '4' { Stop-FrpcService }
            '5' { Restart-FrpcService }
            '6' { Get-FrpcStatus }
            '7' { Show-FrpcConfig }
            '8' { Edit-FrpcConfig }
            '9' { Show-FrpcLog }
            '0' { return }
            default { Write-Host "'$choice' is not a valid option." -ForegroundColor Red; Pause-Script }
        }
    }
}
#endregion

#region Main Execution
# Main script logic starts here
if ($Action) {
    switch ($Action) {
        'Install'    { Install-FrpcService }
        'Uninstall'  { Uninstall-FrpcService }
        'Start'      { Start-FrpcService; break }
        'Stop'       { Stop-FrpcService; break }
        'Restart'    { Restart-FrpcService; break }
        'Status'     { Get-FrpcStatus; break }
        'ViewConfig' { if(Test-Path $CONFIG_FILE){ Get-Content $CONFIG_FILE } else { Write-Error "Config not found."} }
        'EditConfig' { Edit-FrpcConfig }
        'ViewLog'    { if(Test-Path $LOG_FILE){ Get-Content $LOG_FILE } else { Write-Error "Log not found."}  }
    }
} else {
    Show-Menu
}
#endregion
