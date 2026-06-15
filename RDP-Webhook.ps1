# RDP-Webhook.ps1
# Sends a webhook notification when a Remote Desktop event is detected.
# Triggered by Task Scheduler on Event ID 21 (logon), 23 (logoff), 24 (disconnect), 25 (reconnect)
# from Microsoft-Windows-TerminalServices-LocalSessionManager/Operational

$ConfigPath = if ($env:REMOTE_ACCESS_CONFIG) {
    $env:REMOTE_ACCESS_CONFIG
} else {
    Join-Path $env:ProgramData "RemoteAccessWatch\config.json"
}

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config not found: $ConfigPath. Run install-rdp-webhook.ps1 to install."
    exit 1
}

$config = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$WebhookUrl = $config.webhook_url
if (-not $WebhookUrl) {
    Write-Error "webhook_url is not configured in $ConfigPath"
    exit 1
}

$LogName = "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"

try {
    $Event = Get-WinEvent -LogName $LogName -FilterXPath "*[System[(EventID=21 or EventID=23 or EventID=24 or EventID=25)]]" -MaxEvents 1 -ErrorAction Stop
    $EventXml = [xml]$Event.ToXml()
    $UserData = $EventXml.Event.UserData.EventXML

    $Username = $UserData.User
    $SessionId = $UserData.SessionID
    $SourceIP = $UserData.Address

    switch ($Event.Id) {
        21 { $EventType = "rdp_logon" }
        23 { $EventType = "rdp_logoff" }
        24 { $EventType = "rdp_disconnect" }
        25 { $EventType = "rdp_reconnect" }
        default { $EventType = "rdp_event_$($Event.Id)" }
    }

    $Hostname = $env:COMPUTERNAME
    $OSInfo = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $OSVersion = if ($OSInfo) { $OSInfo.Caption } else { "Unknown" }
    $OSBuild = if ($OSInfo) { $OSInfo.BuildNumber } else { "Unknown" }

    $NetworkAdapters = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled = True" -ErrorAction SilentlyContinue |
        ForEach-Object {
            @{
                description  = $_.Description
                ip_addresses = @($_.IPAddress)
                mac_address  = $_.MACAddress
            }
        }

    $Payload = @{
        source          = "remote-access-watch"
        platform        = "windows"
        event_type      = $EventType
        event_id        = $Event.Id
        timestamp       = $Event.TimeCreated.ToString("o")
        hostname        = $Hostname
        username        = $Username
        source_ip       = $SourceIP
        session_id      = $SessionId
        computer_name   = $Hostname
        os_version      = $OSVersion
        os_build        = $OSBuild
        domain          = $env:USERDOMAIN
        local_adapters  = $NetworkAdapters
    }

    $JsonBody = $Payload | ConvertTo-Json -Depth 4 -Compress
    Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $JsonBody -ContentType "application/json; charset=utf-8" -TimeoutSec 15

    Write-EventLog -LogName Application -Source "Application" -EventId 1000 -EntryType Information -Message "RDP Webhook sent successfully for user $Username from $SourceIP" -ErrorAction SilentlyContinue
}
catch {
    $ErrorMsg = "RDP Webhook failed: $($_.Exception.Message)"
    Write-EventLog -LogName Application -Source "Application" -EventId 1001 -EntryType Error -Message $ErrorMsg -ErrorAction SilentlyContinue
    Write-Error $ErrorMsg
}
