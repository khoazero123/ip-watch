# Remote Access Watch

Theo dõi kết nối Remote Desktop trên Windows và SSH trên Linux, gửi webhook tới n8n (hoặc bất kỳ HTTP endpoint nào). Dùng **webhook URL riêng**, tách biệt với [ip-watch](README.md).

| Nền tảng | Sự kiện theo dõi |
|----------|------------------|
| Windows  | RDP logon, logoff, disconnect, reconnect |
| Linux    | SSH connect, disconnect |

---

## Cài đặt

### Windows (RDP)

Mở **PowerShell** với quyền Administrator:

```powershell
irm https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-rdp-webhook.ps1 | iex
```

Truyền webhook URL qua biến môi trường (bỏ qua prompt):

```powershell
$env:REMOTE_ACCESS_WEBHOOK="https://example.com/webhook/xxxxxxxx"; irm https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-rdp-webhook.ps1 | iex
```

Nếu GitHub bị chặn (ISP/DNS):

```powershell
iex (curl.exe -s --doh-url https://1.1.1.1/dns-query https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-rdp-webhook.ps1 | Out-String)
```

### Linux (SSH)

**Tương tác** (hỏi webhook URL):

```bash
curl -fsSL https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-ssh-webhook.sh \
  -o /tmp/install-ssh-webhook.sh && sudo bash /tmp/install-ssh-webhook.sh
```

**Truyền webhook URL trực tiếp:**

```bash
curl -fsSL https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-ssh-webhook.sh \
  -o /tmp/install-ssh-webhook.sh \
  && sudo bash /tmp/install-ssh-webhook.sh --webhook-url "https://example.com/webhook/xxxxxxxx"
```

> **Lưu ý:** `curl | sudo bash -s` pipe script vào stdin nên không thể prompt. Dùng `curl -o && bash` để cài tương tác, hoặc truyền `--webhook-url` khi pipe.

---

## Sau khi cài

| Nền tảng | Script | Config | Service |
|----------|--------|--------|---------|
| Windows | `C:\ProgramData\RemoteAccessWatch\RDP-Webhook.ps1` | `C:\ProgramData\RemoteAccessWatch\config.json` | Task `RemoteAccessWatch-RDP` |
| Linux | `/usr/local/bin/ssh-webhook.sh` | `/etc/remote-access-watch/config.env` | `systemctl status remote-access-watch` |

Webhook URL đã nhập khi cài được lưu tại `~/.config/remote-access-watch/install.env` (dùng lại lần cài sau).

---

## Sự kiện Windows (RDP)

Task Scheduler lắng nghe log `Microsoft-Windows-TerminalServices-LocalSessionManager/Operational`:

| Event ID | `event_type` | Mô tả |
|----------|--------------|-------|
| 21 | `rdp_logon` | Đăng nhập RDP |
| 23 | `rdp_logoff` | Đăng xuất RDP |
| 24 | `rdp_disconnect` | Ngắt kết nối RDP (session còn) |
| 25 | `rdp_reconnect` | Kết nối lại RDP |

## Sự kiện Linux (SSH)

Script đọc journal của `sshd` và bắt các dòng:

| Pattern log | `event_type` |
|-------------|--------------|
| `Accepted publickey/password for user from IP` | `ssh_connect` |
| `Disconnected from user ...` | `ssh_disconnect` |
| `Disconnected from IP port` | `ssh_disconnect` |
| `session closed for user ...` | `ssh_disconnect` (fallback) |

---

## Webhook Payload

Cả Windows và Linux dùng cùng cấu trúc cơ bản:

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

Payload Windows bổ sung thêm: `event_id`, `session_id`, `os_version`, `os_build`, `domain`, `local_adapters`.

| Trường | Mô tả |
|--------|-------|
| `source` | Luôn `"remote-access-watch"` — dùng để lọc trong n8n |
| `platform` | `"windows"` hoặc `"linux"` |
| `event_type` | `rdp_logon`, `rdp_logoff`, `rdp_disconnect`, `rdp_reconnect`, `ssh_connect`, `ssh_disconnect` |
| `hostname` | Tên máy |
| `timestamp` | Thời điểm sự kiện (ISO 8601) |
| `username` | Tên user đăng nhập |
| `source_ip` | IP nguồn kết nối |

---

## Cấu hình

### Windows (`config.json`)

```json
{
  "webhook_url": "https://example.com/webhook/xxxxxxxx"
}
```

Sửa xong không cần restart task — script đọc config mỗi lần chạy.

### Linux (`config.env`)

```bash
WEBHOOK_URL="https://example.com/webhook/xxxxxxxx"
```

Sau khi sửa, restart service:

```bash
sudo systemctl restart remote-access-watch
```

---

## Gỡ cài đặt

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

## Xử lý sự cố

### Windows: Task không chạy

- Kiểm tra Task Scheduler → `RemoteAccessWatch-RDP` → History
- Chạy thủ công: `powershell -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\RemoteAccessWatch\RDP-Webhook.ps1"`
- Đảm bảo Remote Desktop được bật và có sự kiện trong Event Viewer → Applications and Services Logs → Microsoft → Windows → TerminalServices-LocalSessionManager → Operational

### Linux: Không nhận webhook

```bash
systemctl status remote-access-watch
journalctl -u remote-access-watch -f
journalctl -u ssh -f    # hoặc -u sshd
```

Đảm bảo `sshd` ghi log vào journal (`systemd-journald`). Script tự chọn unit `ssh`, `sshd`, hoặc `SYSLOG_IDENTIFIER=sshd`.

### Cài không tương tác (CI / SSH không TTY)

```bash
REMOTE_ACCESS_WEBHOOK="https://example.com/webhook/xxx" \
  curl -fsSL https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-ssh-webhook.sh | sudo -E bash -s
```

---

## Tích hợp n8n

Dùng webhook riêng cho remote access. Lọc theo `source`:

```
{{ $json.source === "remote-access-watch" }}
```

Phân biệt RDP và SSH:

```
{{ $json.platform === "windows" && $json.event_type === "rdp_logon" }}
{{ $json.platform === "linux" && $json.event_type === "ssh_connect" }}
```

---

## Files

| File | Mô tả |
|------|-------|
| `RDP-Webhook.ps1` | Script gửi webhook khi có sự kiện RDP (Windows) |
| `install-rdp-webhook.ps1` | Installer Windows (Scheduled Task + Event trigger) |
| `ssh-webhook.sh` | Script theo dõi SSH connect/disconnect (Linux) |
| `install-ssh-webhook.sh` | Installer Linux (systemd service) |

## License

MIT
