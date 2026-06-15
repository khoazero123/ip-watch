#Requires -Version 5.1
<#
.SYNOPSIS
    Install ipv6-watch on Windows (Scheduled Task at startup).

.PARAMETER WebhookUrl
    n8n webhook URL. If omitted, prompts interactively (prefills from ~/.config/ip-watch/install.env).

.EXAMPLE
    irm https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-ipv6-watch.ps1 | iex
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$WebhookUrl,

    [Parameter(Mandatory = $false)]
    [string[]]$Interfaces = @(),

    [Parameter(Mandatory = $false)]
    [int]$PollIntervalSeconds = 10,

    [Parameter(Mandatory = $false)]
    [string]$InstallDir = "$env:ProgramData\IPv6Watch",

    [Parameter(Mandatory = $false)]
    [string]$TaskName = "IPv6Watch"
)

$ErrorActionPreference = "Stop"

$RepoRawBase = 'https://raw.githubusercontent.com/khoazero123/ip-watch/master'
$UserConfigDir = Join-Path $env:USERPROFILE '.config\ip-watch'
$UserConfigFile = Join-Path $UserConfigDir 'install.env'

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

    $tempScript = Join-Path $env:TEMP "install-ipv6-watch.ps1"
    Invoke-WebRequest -Uri "$RepoRawBase/install-ipv6-watch.ps1" -OutFile $tempScript -UseBasicParsing

    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tempScript)
    if ($WebhookUrl) { $psArgs += @('-WebhookUrl', $WebhookUrl) }
    if ($PollIntervalSeconds -ne 10) { $psArgs += @('-PollIntervalSeconds', $PollIntervalSeconds) }

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
        Write-Error "Webhook URL is required in non-interactive mode. Set `$env:IPWATCH_WEBHOOK or use -WebhookUrl."
        exit 1
    }

    Write-Host ""
    Write-Host "Enter your n8n webhook URL." -ForegroundColor Yellow
    if ($DefaultUrl) {
        Write-Host "Press Enter to use the saved URL." -ForegroundColor DarkGray
    }
    Write-Host "Example: https://n8n.example.com/webhook/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
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

# --- Self-elevate if not running as Administrator ---
if (-not (Test-IsAdmin)) {
    Request-AdminElevation
}

# --- Resolve webhook URL (param > env > prompt with saved prefill) ---
$savedWebhook = Get-SavedWebhookUrl

if (-not $WebhookUrl -and $env:IPWATCH_WEBHOOK) {
    $WebhookUrl = $env:IPWATCH_WEBHOOK.Trim()
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

# --- Locate or download watch script ---
$ScriptDir = if ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $null
}
$LocalScript = if ($ScriptDir) { Join-Path $ScriptDir "ipv6-watch.ps1" } else { $null }

Write-Step "Creating install directory: $InstallDir"
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

$TargetScript = Join-Path $InstallDir "ipv6-watch.ps1"

if ($LocalScript -and (Test-Path $LocalScript)) {
    Write-Step "Copying script -> $TargetScript"
    Copy-Item -Path $LocalScript -Destination $TargetScript -Force
}
else {
    Write-Step "Downloading ipv6-watch.ps1 from GitHub -> $TargetScript"
    Invoke-WebRequest -Uri "$RepoRawBase/ipv6-watch.ps1" -OutFile $TargetScript -UseBasicParsing
}

# --- Write service config ---
$config = [ordered]@{
    webhook_url             = $WebhookUrl
    interfaces              = @($Interfaces)
    poll_interval_seconds   = $PollIntervalSeconds
}

$configPath = Join-Path $InstallDir "config.json"
Write-Step "Writing config -> $configPath"
$config | ConvertTo-Json -Depth 3 | Set-Content -Path $configPath -Encoding UTF8

# --- Register Scheduled Task ---
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TargetScript`""

$trigger = New-ScheduledTaskTrigger -AtStartup

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1)

$principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -RunLevel Highest `
    -LogonType ServiceAccount

Write-Step "Registering Scheduled Task: $TaskName"
Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Force | Out-Null

Write-Step "Starting task for the first time..."
Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Installation complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  Script       : $TargetScript"
Write-Host "  Service cfg  : $configPath"
Write-Host "  Installer cfg: $UserConfigFile"
Write-Host "  Task         : $TaskName (AtStartup, SYSTEM)"
Write-Host ""
Write-Host "View logs: Task Scheduler -> $TaskName -> History"
Write-Host "Run manually: powershell -File `"$TargetScript`""
Write-Host ""
Write-Host "Uninstall:"
Write-Host "  Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
Write-Host "  Remove-Item -Recurse -Force '$InstallDir'"
