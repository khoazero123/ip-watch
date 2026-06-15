# Remote Access Watch

Monitor Remote Desktop connections on Windows and SSH sessions on Linux, and send webhook notifications to n8n (or any HTTP endpoint). Uses a **separate webhook URL**, independent from [ip-watch](README.md).

| Platform | Events monitored |
|----------|------------------|
| Windows  | RDP logon, logoff, disconnect, reconnect |
| Linux    | SSH connect, disconnect |

---

## Install

### Windows (RDP)

Open **PowerShell** as Administrator:

```powershell
irm https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-rdp-webhook.ps1 | iex
```

Pass the webhook URL via environment variable (skip prompt):

```powershell
$env:REMOTE_ACCESS_WEBHOOK="https://example.com/webhook/xxxxxxxx"; irm https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-rdp-webhook.ps1 | iex
```

If GitHub is blocked (ISP/DNS):

```powershell
iex (curl.exe -s --doh-url https://1.1.1.1/dns-query https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-rdp-webhook.ps1 | Out-String)
```

### Linux (SSH)

**Interactive** (prompts for webhook URL — one-liner, stdin stays on TTY):

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-ssh-webhook.sh)"
```

**With webhook URL:**

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-ssh-webhook.sh)" _ \
  --webhook-url "https://example.com/webhook/xxxxxxxx"
```

> **Note:** `curl | sudo bash` pipes the script into stdin and **cannot** prompt for input. Use `sudo bash -c "$(curl ...)"` (same pattern as [Proxmox helper scripts](https://github.com/community-scripts/ProxmoxVE)) for interactive one-liner installs, or pass `--webhook-url` / the `REMOTE_ACCESS_WEBHOOK` env var.

---

## After install

| Platform | Script | Config | Service |
|----------|--------|--------|---------|
| Windows | `C:\ProgramData\RemoteAccessWatch\RDP-Webhook.ps1` | `C:\ProgramData\RemoteAccessWatch\config.json` | Task `RemoteAccessWatch-RDP` |
| Linux | `/usr/local/bin/ssh-webhook.sh` | `/etc/remote-access-watch/config.env` | `systemctl status remote-access-watch` |

The webhook URL entered during install is saved at `~/.config/remote-access-watch/install.env` for reuse on future installs.

---

## Windows events (RDP)

Task Scheduler listens to `Microsoft-Windows-TerminalServices-LocalSessionManager/Operational`:

| Event ID | `event_type` | Description |
|----------|--------------|-------------|
| 21 | `rdp_logon` | RDP logon |
| 23 | `rdp_logoff` | RDP logoff |
| 24 | `rdp_disconnect` | RDP disconnect (session still active) |
| 25 | `rdp_reconnect` | RDP reconnect |

## Linux events (SSH)

The script reads the `sshd` journal and matches these log lines:

| Log pattern | `event_type` |
|-------------|--------------|
| `Accepted publickey/password for user from IP` | `ssh_connect` |
| `Disconnected from user ...` | `ssh_disconnect` |
| `Disconnected from IP port` | `ssh_disconnect` |

---

## Webhook Payload

Windows and Linux share the same base structure:

```json
{
  "source": "remote-access-watch",
  "platform": "windows",
  "event_type": "rdp_logon",
  "hostname": "MY-PC",
  "timestamp": "2026-06-15T10:30:00.0000000+07:00",
  "username": "admin",
  "source_ip": "192.168.1.100"
}
```

The Windows payload also includes: `event_id`, `session_id`, `os_version`, `os_build`, `domain`, `local_adapters`.

| Field | Description |
|-------|-------------|
| `source` | Always `"remote-access-watch"` — use to filter in n8n |
| `platform` | `"windows"` or `"linux"` |
| `event_type` | `rdp_logon`, `rdp_logoff`, `rdp_disconnect`, `rdp_reconnect`, `ssh_connect`, `ssh_disconnect` |
| `hostname` | Machine hostname |
| `timestamp` | Event time (ISO 8601) |
| `username` | Login username |
| `source_ip` | Source connection IP |

---

## Configuration

### Windows (`config.json`)

```json
{
  "webhook_url": "https://example.com/webhook/xxxxxxxx"
}
```

No task restart needed after editing — the script reads config on each run.

### Linux (`config.env`)

```bash
WEBHOOK_URL="https://example.com/webhook/xxxxxxxx"
```

After editing, restart the service:

```bash
sudo systemctl restart remote-access-watch
```

---

## Uninstall

### Windows

```powershell
schtasks /Delete /TN "RemoteAccessWatch-RDP" /F
Remove-Item -Recurse -Force "$env:ProgramData\RemoteAccessWatch"
```

### Linux

```bash
sudo systemctl disable --now remote-access-watch
sudo rm /etc/systemd/system/remote-access-watch.service
sudo rm -rf /etc/remote-access-watch /usr/local/bin/ssh-webhook.sh
sudo systemctl daemon-reload
```

---

## Troubleshooting

### Windows: Task not running

- Check Task Scheduler → `RemoteAccessWatch-RDP` → History
- Run manually: `powershell -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\RemoteAccessWatch\RDP-Webhook.ps1"`
- Ensure Remote Desktop is enabled and events appear in Event Viewer → Applications and Services Logs → Microsoft → Windows → TerminalServices-LocalSessionManager → Operational

### Linux: Webhook not received

```bash
systemctl status remote-access-watch
journalctl -u remote-access-watch -f
journalctl SYSLOG_IDENTIFIER=sshd -f
```

Ensure `sshd` logs to the journal (`systemd-journald`). The script follows `SYSLOG_IDENTIFIER=sshd` (not just `journalctl -u ssh`) because the `ssh` unit often **does not** include `Disconnected from user ...` lines — only `session closed` (missing source IP).

**n8n webhook must accept POST.** A 404 with `"This webhook is not registered for POST requests"` means the Webhook node HTTP method is set to GET — change it to POST and activate the workflow.

### Non-interactive install (CI / SSH without TTY)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-ssh-webhook.sh)" _ \
  --webhook-url "https://example.com/webhook/xxx"
```

Or use an environment variable:

```bash
sudo REMOTE_ACCESS_WEBHOOK="https://example.com/webhook/xxx" \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-ssh-webhook.sh)"
```

---

## n8n Integration

Use a dedicated webhook for remote access. Filter by `source`:

```
{{ $json.source === "remote-access-watch" }}
```

Distinguish RDP and SSH:

```
{{ $json.platform === "windows" && $json.event_type === "rdp_logon" }}
{{ $json.platform === "linux" && $json.event_type === "ssh_connect" }}
```

---

## Files

| File | Description |
|------|-------------|
| `RDP-Webhook.ps1` | Sends webhook on RDP events (Windows) |
| `install-rdp-webhook.ps1` | Windows installer (Scheduled Task + event trigger) |
| `ssh-webhook.sh` | Monitors SSH connect/disconnect (Linux) |
| `install-ssh-webhook.sh` | Linux installer (systemd service) |

## License

MIT
