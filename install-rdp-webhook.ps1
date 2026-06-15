#Requires -Version 5.1
<#
.SYNOPSIS
    Install RDP session webhook monitor on Windows (Scheduled Task on RDP events).

.PARAMETER WebhookUrl
    n8n webhook URL. If omitted, prompts interactively (prefills from ~/.config/remote-access-watch/install.env).

.EXAMPLE
    irm https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-rdp-webhook.ps1 | iex
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$WebhookUrl,

    [Parameter(Mandatory = $false)]
    [string]$InstallDir = "$env:ProgramData\RemoteAccessWatch",

    [Parameter(Mandatory = $false)]
    [string]$TaskName = "RemoteAccessWatch-RDP"
)

$ErrorActionPreference = "Stop"

$RepoRawBase = 'https://raw.githubusercontent.com/khoazero123/ip-watch/master'
$UserConfigDir = Join-Path $env:USERPROFILE '.config\remote-access-watch'
$UserConfigFile = Join-Path $UserConfigDir 'install.env'
$EventLogName = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'
$EventQuery = '*[System[(EventID=21 or EventID=23 or EventID=24 or EventID=25)]]'

function Get-SavedWebhookUrl {
    if (-not (Test-Path $UserConfigFile)) { return $null }
    $line = Get-Content $UserConfigFile -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '^\s*WEBHOOK_URL=' } |
        Select-Object -First 1
    if ($line -match '^\s*WEBHOOK_URL="([^"]+)"') { return $Matches[1] }
    if ($line -match "^\s*WEBHOOK_URL='([^']+)'") { return $Matches[1] }
    if ($line -match '^\s*WEBHOOK_URL=(.+)$') { return $Matches[1].Trim() }
    return $null
}

function Save-WebhookUrlToUserConfig {
    param([string]$Url)
    New-Item -ItemType Directory -Path $UserConfigDir -Force | Out-Null
    Set-Content -Path $UserConfigFile -Value "WEBHOOK_URL=`"$Url`"" -Encoding UTF8
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-AdminElevation {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow

    $tempScript = Join-Path $env:TEMP "install-rdp-webhook.ps1"
    Invoke-WebRequest -Uri "$RepoRawBase/install-rdp-webhook.ps1" -OutFile $tempScript -UseBasicParsing

    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tempScript)
    if ($WebhookUrl) { $psArgs += @('-WebhookUrl', $WebhookUrl) }

    $proc = Start-Process powershell.exe -Verb RunAs -ArgumentList $psArgs -PassThru -Wait
    exit $proc.ExitCode
}

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Read-WebhookUrl {
    param([string]$DefaultUrl = '')

    if ([Environment]::UserInteractive -eq $false) {
        if ($DefaultUrl) { return $DefaultUrl }
        Write-Error "Webhook URL is required in non-interactive mode. Set `$env:REMOTE_ACCESS_WEBHOOK or use -WebhookUrl."
        exit 1
    }

    Write-Host ""
    Write-Host "Enter your n8n webhook URL for RDP remote access alerts." -ForegroundColor Yellow
    if ($DefaultUrl) {
        Write-Host "Press Enter to use the saved URL." -ForegroundColor DarkGray
    }
    Write-Host "Example: https://example.com/webhook/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    Write-Host ""

    while ($true) {
        $prompt = if ($DefaultUrl) { "Webhook URL [$DefaultUrl]" } else { "Webhook URL" }
        $input = Read-Host $prompt
        $url = if ($input.Trim()) { $input.Trim() } elseif ($DefaultUrl) { $DefaultUrl } else { '' }

        if (-not $url) {
            Write-Host "URL cannot be empty, please try again." -ForegroundColor Yellow
            continue
        }
        if ($url -notmatch '^https?://') {
            Write-Host "URL must start with http:// or https://, please try again." -ForegroundColor Yellow
            continue
        }
        return $url
    }
}

if (-not (Test-IsAdmin)) {
    Request-AdminElevation
}

$savedWebhook = Get-SavedWebhookUrl

if (-not $WebhookUrl -and $env:REMOTE_ACCESS_WEBHOOK) {
    $WebhookUrl = $env:REMOTE_ACCESS_WEBHOOK.Trim()
}

if (-not $WebhookUrl) {
    $WebhookUrl = Read-WebhookUrl -DefaultUrl $savedWebhook
}
else {
    $WebhookUrl = $WebhookUrl.Trim()
    if ($WebhookUrl -notmatch '^https?://') {
        Write-Error "Invalid Webhook URL: $WebhookUrl"
        exit 1
    }
}

Save-WebhookUrlToUserConfig -Url $WebhookUrl
Write-Step "Saved webhook URL -> $UserConfigFile"

$ScriptDir = if ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $null
}
$LocalScript = if ($ScriptDir) { Join-Path $ScriptDir "RDP-Webhook.ps1" } else { $null }

Write-Step "Creating install directory: $InstallDir"
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

$TargetScript = Join-Path $InstallDir "RDP-Webhook.ps1"

if ($LocalScript -and (Test-Path $LocalScript)) {
    Write-Step "Copying script -> $TargetScript"
    Copy-Item -Path $LocalScript -Destination $TargetScript -Force
}
else {
    Write-Step "Downloading RDP-Webhook.ps1 from GitHub -> $TargetScript"
    Invoke-WebRequest -Uri "$RepoRawBase/RDP-Webhook.ps1" -OutFile $TargetScript -UseBasicParsing
}

$config = [ordered]@{
    webhook_url = $WebhookUrl
}

$configPath = Join-Path $InstallDir "config.json"
Write-Step "Writing config -> $configPath"
$config | ConvertTo-Json -Depth 3 | Set-Content -Path $configPath -Encoding UTF8

$taskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TargetScript`""

Write-Step "Registering Scheduled Task: $TaskName"
schtasks /Delete /TN $TaskName /F 2>$null | Out-Null
$schResult = schtasks /Create `
    /TN $TaskName `
    /SC ONEVENT `
    /EC $EventLogName `
    /MO $EventQuery `
    /RU SYSTEM `
    /RL HIGHEST `
    /TR $taskCommand `
    /F 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to register scheduled task: $schResult"
    exit 1
}

Write-Host ""
Write-Host "Installation complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  Script       : $TargetScript"
Write-Host "  Service cfg  : $configPath"
Write-Host "  Installer cfg: $UserConfigFile"
Write-Host "  Task         : $TaskName (RDP Event IDs 21/23/24/25, SYSTEM)"
Write-Host ""
Write-Host "Monitored events:"
Write-Host "  21 = RDP Session Logon"
Write-Host "  23 = RDP Session Logoff"
Write-Host "  24 = RDP Session Disconnect"
Write-Host "  25 = RDP Session Reconnection"
Write-Host ""
Write-Host "View logs: Event Viewer -> Application, or Task Scheduler -> $TaskName -> History"
Write-Host "Run manually: powershell -File `"$TargetScript`""
Write-Host ""
Write-Host "Uninstall:"
Write-Host "  schtasks /Delete /TN '$TaskName' /F"
Write-Host "  Remove-Item -Recurse -Force '$InstallDir'"
