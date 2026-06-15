#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Install ipv6-watch on Windows (Scheduled Task at startup).

.PARAMETER WebhookUrl
    n8n webhook URL. If omitted, the script prompts interactively.

.PARAMETER Interfaces
    Adapter names to monitor. Empty = auto-detect all Up adapters.

.EXAMPLE
    .\install-ipv6-watch.ps1
    # Prompts for Webhook URL interactively

.EXAMPLE
    .\install-ipv6-watch.ps1 -WebhookUrl "https://n8n.example.com/webhook/xxx"
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

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Read-WebhookUrl {
    if ([Environment]::UserInteractive -eq $false -or $Host.Name -eq 'ServerRemoteHost') {
        Write-Error "Webhook URL is required in non-interactive mode. Use: -WebhookUrl 'https://...'"
        exit 1
    }

    Write-Host ""
    Write-Host "No Webhook URL provided — please enter your n8n webhook URL." -ForegroundColor Yellow
    Write-Host "Example: https://n8n.example.com/webhook/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    Write-Host ""

    while ($true) {
        $url = (Read-Host "Webhook URL").Trim()
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

# --- Prompt for webhook if not passed via parameter ---
if (-not $WebhookUrl) {
    $WebhookUrl = Read-WebhookUrl
}
else {
    $WebhookUrl = $WebhookUrl.Trim()
    if ($WebhookUrl -notmatch '^https?://') {
        Write-Error "Invalid Webhook URL: $WebhookUrl"
        exit 1
    }
}

# --- Locate source script ---
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceScript = Join-Path $ScriptDir "ipv6-watch.ps1"

if (-not (Test-Path $SourceScript)) {
    Write-Error "ipv6-watch.ps1 not found in the same directory as the installer."
    Write-Error "Download both files from GitHub or clone the repo before installing."
    exit 1
}

Write-Step "Creating install directory: $InstallDir"
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

$TargetScript = Join-Path $InstallDir "ipv6-watch.ps1"
Write-Step "Copying script -> $TargetScript"
Copy-Item -Path $SourceScript -Destination $TargetScript -Force

# --- Write config ---
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

# --- Start immediately ---
Write-Step "Starting task for the first time..."
Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Installation complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  Script : $TargetScript"
Write-Host "  Config : $configPath"
Write-Host "  Task   : $TaskName (AtStartup, SYSTEM)"
Write-Host ""
Write-Host "View logs: Task Scheduler -> $TaskName -> History"
Write-Host "Run manually: powershell -File `"$TargetScript`""
Write-Host ""
Write-Host "Uninstall:"
Write-Host "  Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
Write-Host "  Remove-Item -Recurse -Force '$InstallDir'"
