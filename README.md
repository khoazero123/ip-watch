# IP Watch

Monitor IPv4/IPv6 address changes on Windows, Linux, and macOS, and send webhook notifications to n8n (or any HTTP endpoint).

## Install

### Linux / macOS

**Interactive** (prompts for webhook URL):

```bash
curl -fsSL https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-ip-watch.sh \
  -o /tmp/install-ip-watch.sh && sudo bash /tmp/install-ip-watch.sh
```

**With webhook URL:**

```bash
curl -fsSL https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-ip-watch.sh \
  -o /tmp/install-ip-watch.sh \
  && sudo bash /tmp/install-ip-watch.sh --webhook-url "https://example.com/webhook/xxxxxxxx"
```

> **Note:** `curl | sudo bash -s` pipes the script into stdin and cannot prompt for input. Use `curl -o && bash` for interactive install, or pass `--webhook-url` when piping.

### Windows

Open **PowerShell** and run:

```powershell
irm https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-ip-watch.ps1 | iex
```

If GitHub is blocked (ISP/DNS), use DNS-over-HTTPS:

```powershell
iex (curl.exe -s --doh-url https://1.1.1.1/dns-query https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-ip-watch.ps1 | Out-String)
```

The script will request **Administrator** privileges and prompt for your webhook URL.

**Pass webhook URL via environment variable (skip prompt):**

```powershell
$env:IPWATCH_WEBHOOK="https://example.com/webhook/xxxxxxxx"; irm https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-ip-watch.ps1 | iex
```

> The `irm` command downloads the script; `iex` executes it. Always verify the URL points to [github.com/khoazero123/ip-watch](https://github.com/khoazero123/ip-watch).

### After install

| Platform | Script | Config | Service |
|----------|--------|--------|---------|
| Windows | `C:\ProgramData\IPWatch\ip-watch.ps1` | `C:\ProgramData\IPWatch\config.json` | Task `IPWatch` |
| Linux | `/usr/local/bin/ip-watch.sh` | `/etc/ip-watch/config.env` | `systemctl status ip-watch` |
| macOS | `/usr/local/bin/ip-watch.sh` | `/etc/ip-watch/config.env` | `tail -f /var/log/ip-watch.log` |

---

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
| `ip-watch.ps1` | Watch script for Windows |
| `ip-watch.sh` | Watch script for Linux and macOS |
| `install-ip-watch.ps1` | Windows installer (Scheduled Task) |
| `install-ip-watch.cmd` | Windows launcher (auto Bypass + Admin) |
| `install-ip-watch.sh` | Linux/macOS installer (systemd / launchd) |

## Webhook Payload

Both scripts send the same JSON structure:

```json
{
  "source": "ip-watch",
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
| `source` | Always `"ip-watch"` — use to filter in n8n |
| `platform` | `"windows"`, `"linux"`, or `"darwin"` |
| `event_type` | `"init"` (startup) or `"changed"` (IP changed) |
| `hostname` | Machine hostname |
| `timestamp` | UTC ISO 8601 timestamp |
| `interfaces` | Map of adapter name → `{ ipv6, ipv4, mac }` |

## Configuration

### Windows (`config.json`)

```json
{
  "webhook_url": "https://example.com/webhook/xxxxxxxx",
  "interfaces": [],
  "poll_interval_seconds": 10
}
```

- `interfaces`: empty array = auto-detect all Up adapters
- `poll_interval_seconds`: polling interval (default: 10)

### Linux / macOS (`config.env`)

```bash
WEBHOOK_URL="https://example.com/webhook/xxxxxxxx"
IFACES=""
POLL_INTERVAL=10
```

- `IFACES`: space-separated interface names, or empty for auto-detect
- `POLL_INTERVAL`: polling interval in seconds (default: 10)

After editing config, restart the service:

```bash
# Linux
sudo systemctl restart ip-watch

# Windows
Restart-ScheduledTask -TaskName "IPWatch"
```

**Run manually for debugging (Windows):**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\IPWatch\ip-watch.ps1"
```

## Uninstall

### Windows

```powershell
Stop-ScheduledTask -TaskName "IPWatch" -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "IPWatch" -Confirm:$false
Remove-Item -Recurse -Force "$env:ProgramData\IPWatch"
```

### Linux

```bash
sudo systemctl disable --now ip-watch
sudo rm /etc/systemd/system/ip-watch.service
sudo rm -rf /etc/ip-watch /usr/local/bin/ip-watch.sh
sudo systemctl daemon-reload
```

### macOS

```bash
sudo launchctl bootout system/net.ipwatch
sudo rm /Library/LaunchDaemons/net.ipwatch.plist
sudo rm /usr/local/bin/ip-watch.sh
sudo rm -rf /etc/ip-watch /var/log/ip-watch.log /var/log/ip-watch.err
```

## Troubleshooting

### Execution Policy / script not signed (Windows)

If `irm | iex` is blocked, use the CMD launcher or Bypass:

```powershell
irm https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-ip-watch.cmd -OutFile $env:TEMP\install.cmd; & $env:TEMP\install.cmd
```

Or:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-ip-watch.ps1 | iex"
```

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

- **Windows:** Task Scheduler → `IPWatch` → History, or run the script manually
- **Linux:** `journalctl -u ip-watch -f`
- **macOS:** `tail -f /var/log/ip-watch.log`

### Non-interactive install (no terminal)

When there is no terminal at all (CI, SSH without TTY), pass the webhook URL explicitly:

```bash
curl -fsSL https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-ip-watch.sh | \
  sudo bash -s -- --webhook-url "https://example.com/webhook/xxxxxxxx"
```

Or use an environment variable:

```bash
IPWATCH_WEBHOOK="https://example.com/webhook/xxxxxxxx" \
  curl -fsSL https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-ip-watch.sh | sudo -E bash -s
```

## n8n Integration

Use a single webhook for both Windows and Linux/macOS clients. Filter by `source`:

```
{{ $json.source === "ip-watch" }}
```

Access interface data:

```
{{ $json.interfaces["Wi-Fi"].ipv6 }}
{{ $json.hostname }}
{{ $json.event_type }}
```

## License

MIT
