#Requires -Version 5.1
<#
.SYNOPSIS
    Monitor IPv4/IPv6 changes and send a webhook when IP addresses change.
.DESCRIPTION
    Reads configuration from %ProgramData%\IPWatch\config.json.
    Payload format is unified with ip-watch.sh (Linux/macOS).
#>

$ErrorActionPreference = "Continue"

$ConfigDir  = Join-Path $env:ProgramData "IPWatch"
$ConfigFile = Join-Path $ConfigDir "config.json"

function Get-Config {
    if (-not (Test-Path $ConfigFile)) {
        Write-Host "[ERROR] Config not found: $ConfigFile"
        Write-Host "        Run install-ip-watch.ps1 to install."
        exit 1
    }
    try {
        return Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-Host "[ERROR] Invalid config: $ConfigFile"
        exit 1
    }
}

function Get-GlobalIPv6($InterfaceAlias) {
    Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -notmatch '^fe80' -and
            $_.IPAddress -ne '::1' -and
            $_.IPAddress -notmatch '^::$' -and
            $_.AddressState -in @('Preferred', 'Tentative')
        } |
        Sort-Object @{
            Expression = {
                switch ($_.AddressState) {
                    'Preferred' { 0 }
                    'Tentative' { 1 }
                    default     { 2 }
                }
            }
        } |
        Select-Object -First 1
}

function Get-GlobalIPv4($InterfaceAlias) {
    Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -notmatch '^127\.' -and
            $_.IPAddress -notmatch '^169\.254\.' -and
            $_.IPAddress -notmatch '^0\.'
        } |
        Select-Object -First 1
}

function Get-InterfaceData {
    param([string[]]$InterfaceFilter)

    $ifaces = [ordered]@{}

    $adapters = if ($InterfaceFilter -and $InterfaceFilter.Count -gt 0) {
        foreach ($name in $InterfaceFilter) {
            Get-NetAdapter -Name $name -ErrorAction SilentlyContinue
        }
    }
    else {
        Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' -and -not $_.Virtual }
    }

    foreach ($adapter in $adapters) {
        if (-not $adapter -or $adapter.Status -ne 'Up') { continue }

        $alias = $adapter.Name
        $ipv6  = Get-GlobalIPv6 $alias
        $ipv4  = Get-GlobalIPv4 $alias

        if (-not $ipv6 -and -not $ipv4) { continue }

        $ifaces[$alias] = [ordered]@{
            ipv6 = if ($ipv6) { $ipv6.IPAddress } else { $null }
            ipv4 = if ($ipv4) { $ipv4.IPAddress } else { $null }
            mac  = $adapter.MacAddress
        }
    }

    return $ifaces
}

function Build-Payload {
    param(
        [string]$EventType,
        [hashtable]$InterfaceData,
        [string]$Hostname
    )

    $body = [ordered]@{
        source     = 'ip-watch'
        platform   = 'windows'
        event_type = $EventType
        hostname   = $Hostname
        timestamp  = (Get-Date).ToUniversalTime().ToString('o')
        interfaces = $InterfaceData
    }

    return ($body | ConvertTo-Json -Depth 5 -Compress)
}

function Send-Payload {
    param(
        [string]$ApiUrl,
        [string]$Payload
    )

    try {
        $bytes   = [System.Text.Encoding]::UTF8.GetBytes($Payload)
        $headers = @{ 'Content-Type' = 'application/json; charset=utf-8' }

        Invoke-RestMethod `
            -Uri $ApiUrl `
            -Method POST `
            -Headers $headers `
            -Body $bytes `
            -TimeoutSec 15 `
            -UseBasicParsing | Out-Null

        return $true
    }
    catch {
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Send failed: $($_.Exception.Message)"
        return $false
    }
}

function Write-Log([string]$Message) {
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

# --- Main ---
$config   = Get-Config
$apiUrl   = $config.webhook_url
$hostname = $env:COMPUTERNAME
$pollSec  = if ($config.poll_interval_seconds) { [int]$config.poll_interval_seconds } else { 10 }
$ifaces   = @($config.interfaces | Where-Object { $_ })

if (-not $apiUrl) {
    Write-Log "ERROR: webhook_url is empty in config."
    exit 1
}

Write-Log "Starting ip-watch (hostname=$hostname, poll=${pollSec}s)"

$lastData = ''

# INIT — retry until at least one interface has an IP and send succeeds
while ($true) {
    $data     = Get-InterfaceData -InterfaceFilter $ifaces
    $dataJson = ($data | ConvertTo-Json -Depth 5 -Compress)

    if ($data.Count -eq 0) {
        Write-Log "No IP detected on any adapter, retrying in 5s..."
        Write-Log "  (Adapters Up: $((Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -ExpandProperty Name) -join ', '))"
        Start-Sleep -Seconds 5
        continue
    }

    $payload = Build-Payload -EventType 'init' -InterfaceData $data -Hostname $hostname
    Write-Log "Init payload: $payload"

    if (Send-Payload -ApiUrl $apiUrl -Payload $payload) {
        $lastData = $dataJson
        Write-Log "Init sent successfully."
        break
    }

    Write-Log "Init failed, retrying in 5s..."
    Start-Sleep -Seconds 5
}

# WATCH LOOP
while ($true) {
    Start-Sleep -Seconds $pollSec

    $data     = Get-InterfaceData -InterfaceFilter $ifaces
    $dataJson = ($data | ConvertTo-Json -Depth 5 -Compress)

    if ($dataJson -ne $lastData) {
        $payload = Build-Payload -EventType 'changed' -InterfaceData $data -Hostname $hostname
        Write-Log "Changed payload: $payload"

        if (Send-Payload -ApiUrl $apiUrl -Payload $payload) {
            $lastData = $dataJson
            Write-Log "IP change notification sent."
        }
    }
}
