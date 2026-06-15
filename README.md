# IPv6 Watch

Monitor IPv4/IPv6 address changes on Windows, Linux, and macOS, and send webhook notifications to n8n (or any HTTP endpoint).

Supports IPv6-only machines, auto-detects network adapters, and uses a unified JSON payload across all platforms.

## Features

- Detects global IPv6 and IPv4 addresses (skips link-local / loopback)
- Auto-detects all active adapters, or filter by interface name
- Sends an `init` event on startup and `changed` events when IPs change
- Unified payload format for a single webhook across Windows and Unix
- Installers with interactive webhook URL prompt
- Runs as a Windows Scheduled Task, Linux systemd service, or macOS launchd daemon

## Files

| File | Description |
|------|-------------|
| `ipv6-watch.ps1` | Watch script for Windows |
| `ipv6-watch.sh` | Watch script for Linux and macOS |
| `install-ipv6-watch.ps1` | Windows installer (Scheduled Task) |
| `install-ipv6-watch.cmd` | Windows launcher (auto Bypass + Admin) |
| `install-ipv6-watch.sh` | Linux/macOS installer (systemd / launchd) |
| `RDP-Webhook.ps1` | Separate webhook for RDP session events |
| `mikrotik.rsc` | MikroTik router configuration |

## Webhook Payload

Both scripts send the same JSON structure:

```json
{
  "source": "ipv6-watch",
  "platform": "windows",
  "event_type": "init",
  "hostname": "MY-PC",
  "timestamp": "2026-06-15T10:30:00.0000000Z",
  "interfaces": {
    "Wi-Fi": {
      "ipv6": "2405:xxxx::xxxx",
      "ipv4": null,
      "mac": "AA-BB-CC-DD-EE-FF"
    }
  }
}
```

| Field | Description |
|-------|-------------|
| `source` | Always `"ipv6-watch"` — use to filter in n8n |
| `platform` | `"windows"`, `"linux"`, or `"darwin"` |
| `event_type` | `"init"` (startup) or `"changed"` (IP changed) |
| `hostname` | Machine hostname |
| `timestamp` | UTC ISO 8601 timestamp |
| `interfaces` | Map of adapter name → `{ ipv6, ipv4, mac }` |

## Quick Start

### Windows

Run **as Administrator** using one of the methods below.

> **Note:** Scripts on WSL paths (`\\wsl.localhost\...`) or downloaded from the internet are blocked by PowerShell Execution Policy. Use the `.cmd` launcher or `-ExecutionPolicy Bypass`.

**Option A — double-click or run the CMD launcher (recommended):**

```cmd
install-ipv6-watch.cmd
```

**Option B — PowerShell with Bypass:**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-ipv6-watch.ps1

# Or pass the URL directly
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-ipv6-watch.ps1 `
  -WebhookUrl "https://n8n.example.com/webhook/xxxxxxxx"
```

**Option C — copy to a local Windows path first:**

```powershell
Copy-Item -Recurse \\wsl.localhost\Ubuntu\var\www\my-projects\network C:\ipv6-watch
cd C:\ipv6-watch
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-ipv6-watch.ps1
```

**Install locations:**

- Script: `C:\ProgramData\IPv6Watch\ipv6-watch.ps1`
- Config: `C:\ProgramData\IPv6Watch\config.json`
- Task: `IPv6Watch` (runs at startup as SYSTEM)

**Run manually for debugging:**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\IPv6Watch\ipv6-watch.ps1"
```

### Linux

```bash
# Interactive
sudo ./install-ipv6-watch.sh

# Or pass the URL directly
sudo ./install-ipv6-watch.sh --webhook-url "https://n8n.example.com/webhook/xxxxxxxx"

# With specific interfaces
sudo ./install-ipv6-watch.sh \
  --webhook-url "https://n8n.example.com/webhook/xxxxxxxx" \
  --ifaces "eth0 wlan0"
```

**Install locations:**

- Script: `/usr/local/bin/ipv6-watch.sh`
- Config: `/etc/ipv6-watch/config.env`
- Service: `ipv6-watch` (systemd)

```bash
systemctl status ipv6-watch
journalctl -u ipv6-watch -f
```

### macOS

Same installer as Linux:

```bash
sudo ./install-ipv6-watch.sh --webhook-url "https://n8n.example.com/webhook/xxxxxxxx"
```

**Install locations:**

- Script: `/usr/local/bin/ipv6-watch.sh`
- Config: `/etc/ipv6-watch/config.env`
- Daemon: `net.ipv6watch` (launchd)

```bash
tail -f /var/log/ipv6-watch.log
```

### One-liner from GitHub

Replace `USER/REPO` with your repository path:

```bash
curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/install-ipv6-watch.sh | \
  sudo bash -s -- --webhook-url "https://n8n.example.com/webhook/xxxxxxxx"
```

## Configuration

### Windows (`config.json`)

```json
{
  "webhook_url": "https://n8n.example.com/webhook/xxxxxxxx",
  "interfaces": [],
  "poll_interval_seconds": 10
}
```

- `interfaces`: empty array = auto-detect all Up adapters
- `poll_interval_seconds`: polling interval (default: 10)

### Linux / macOS (`config.env`)

```bash
WEBHOOK_URL="https://n8n.example.com/webhook/xxxxxxxx"
IFACES=""
POLL_INTERVAL=10
```

- `IFACES`: space-separated interface names, or empty for auto-detect
- `POLL_INTERVAL`: polling interval in seconds (default: 10)

After editing config, restart the service:

```bash
# Linux
sudo systemctl restart ipv6-watch

# Windows
Restart-ScheduledTask -TaskName "IPv6Watch"
```

## Uninstall

### Windows

```powershell
Stop-ScheduledTask -TaskName "IPv6Watch" -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "IPv6Watch" -Confirm:$false
Remove-Item -Recurse -Force "$env:ProgramData\IPv6Watch"
```

### Linux

```bash
sudo systemctl disable --now ipv6-watch
sudo rm /etc/systemd/system/ipv6-watch.service
sudo rm -rf /etc/ipv6-watch /usr/local/bin/ipv6-watch.sh
sudo systemctl daemon-reload
```

### macOS

```bash
sudo launchctl bootout system/net.ipv6watch
sudo rm /Library/LaunchDaemons/net.ipv6watch.plist
sudo rm /usr/local/bin/ipv6-watch.sh
sudo rm -rf /etc/ipv6-watch /var/log/ipv6-watch.log /var/log/ipv6-watch.err
```

## Troubleshooting

### Execution Policy / script not signed (Windows)

```
File ... cannot be loaded. The file ... is not digitally signed.
```

PowerShell blocks unsigned scripts by default. Fix:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-ipv6-watch.ps1
```

Or use `install-ipv6-watch.cmd` which applies Bypass automatically and requests Admin.

### No IP detected (Windows, IPv6-only)

The script auto-detects all Up adapters and accepts global IPv6 addresses (non-`fe80`). Run diagnostics:

```powershell
Get-NetAdapter | Where-Object Status -eq 'Up' | Select Name, Status, MacAddress
Get-NetIPAddress -AddressFamily IPv6 |
  Where-Object { $_.IPAddress -notmatch '^fe80' } |
  Select InterfaceAlias, IPAddress, PrefixOrigin, AddressState
```

### Empty webhook payload

The script waits until at least one adapter has an IP before sending `init`. Check logs:

- **Windows:** Task Scheduler → `IPv6Watch` → History, or run the script manually
- **Linux:** `journalctl -u ipv6-watch -f`
- **macOS:** `tail -f /var/log/ipv6-watch.log`

### Non-interactive install requires URL

When piping the installer (`curl | bash`), you must pass `--webhook-url` / `-WebhookUrl` — interactive prompts are not available without a TTY.

## n8n Integration

Use a single webhook for both Windows and Linux/macOS clients. Filter by `source`:

```
{{ $json.source === "ipv6-watch" }}
```

Access interface data:

```
{{ $json.interfaces["Wi-Fi"].ipv6 }}
{{ $json.hostname }}
{{ $json.event_type }}
```

## License

MIT
