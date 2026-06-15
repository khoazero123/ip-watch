#!/usr/bin/env bash
# install-ipv6-watch.sh — Install ipv6-watch on Linux (systemd) and macOS (launchd)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-ipv6-watch.sh | \
#     sudo bash -s -- --webhook-url "https://n8n.example.com/webhook/xxx"

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/khoazero123/ip-watch/master"
WEBHOOK_URL=""
IFACES=""
POLL_INTERVAL=10
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/ipv6-watch"
SERVICE_NAME="ipv6-watch"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"

usage() {
    cat <<EOF
Install ipv6-watch — monitor IP changes and send webhook notifications

Usage:
  sudo $0 [--webhook-url URL] [options]

Options:
  --webhook-url URL    n8n webhook URL (prompts interactively if omitted)
  --ifaces IFACES      Space-separated interface names (default: auto-detect)
  --poll-interval SEC  Polling interval in seconds (default: 10)
  --help               Show this help message

Examples:
  sudo $0
  sudo $0 --webhook-url "https://n8n.example.com/webhook/xxx"
  sudo $0 --webhook-url "https://..." --ifaces "eth0 wlan0"
EOF
}

log() { echo "==> $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

# When run via "curl | sudo bash", stdin is the pipe — read prompts from /dev/tty
tty_print() {
    if [[ -t 1 ]]; then
        echo "$@"
    elif [[ -w /dev/tty ]]; then
        echo "$@" >/dev/tty
    else
        echo "$@"
    fi
}

tty_read() {
    local prompt="$1"
    if [[ -t 0 ]]; then
        read -rp "$prompt" WEBHOOK_URL
    elif [[ -r /dev/tty ]]; then
        read -rp "$prompt" WEBHOOK_URL </dev/tty
    else
        return 1
    fi
}

can_prompt_interactively() {
    [[ -t 0 ]] || [[ -r /dev/tty ]]
}

prompt_webhook_url() {
    if ! can_prompt_interactively; then
        die "Webhook URL is required in non-interactive mode. Use: --webhook-url 'https://...'"
    fi

    tty_print ""
    tty_print "No Webhook URL provided — please enter your n8n webhook URL."
    tty_print "Example: https://n8n.example.com/webhook/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    tty_print ""

    while true; do
        if ! tty_read "Webhook URL: "; then
            die "Webhook URL is required in non-interactive mode. Use: --webhook-url 'https://...'"
        fi
        WEBHOOK_URL="$(echo "$WEBHOOK_URL" | xargs)"
        if [[ -z "$WEBHOOK_URL" ]]; then
            tty_print "URL cannot be empty, please try again."
            continue
        fi
        if [[ ! "$WEBHOOK_URL" =~ ^https?:// ]]; then
            tty_print "URL must start with http:// or https://, please try again."
            continue
        fi
        break
    done
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --webhook-url)   WEBHOOK_URL="$2"; shift 2 ;;
        --ifaces)        IFACES="$2"; shift 2 ;;
        --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
        --help|-h)       usage; exit 0 ;;
        *)               die "Unknown argument: $1 (use --help)" ;;
    esac
done

[[ "$(id -u)" -eq 0 ]] || die "Must be run as root (sudo)."

if [[ -z "$WEBHOOK_URL" && -n "${IPWATCH_WEBHOOK:-}" ]]; then
    WEBHOOK_URL="$IPWATCH_WEBHOOK"
fi

if [[ -z "$WEBHOOK_URL" ]]; then
    prompt_webhook_url
else
    WEBHOOK_URL="$(echo "$WEBHOOK_URL" | xargs)"
    [[ "$WEBHOOK_URL" =~ ^https?:// ]] || die "Invalid Webhook URL: $WEBHOOK_URL"
fi

SOURCE_SCRIPT="$SCRIPT_DIR/ipv6-watch.sh"
TARGET_SCRIPT="$INSTALL_DIR/ipv6-watch.sh"
PLATFORM="$(uname -s)"

if [[ -n "$SCRIPT_DIR" && -f "$SOURCE_SCRIPT" ]]; then
    log "Copying script -> $TARGET_SCRIPT"
    install -m 755 "$SOURCE_SCRIPT" "$TARGET_SCRIPT"
else
    log "Downloading ipv6-watch.sh from GitHub -> $TARGET_SCRIPT"
    curl -fsSL "$REPO_RAW/ipv6-watch.sh" -o "$TARGET_SCRIPT"
    chmod 755 "$TARGET_SCRIPT"
fi

log "Writing config -> $CONFIG_DIR/config.env"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/config.env" <<EOF
WEBHOOK_URL="$WEBHOOK_URL"
IFACES="$IFACES"
POLL_INTERVAL=$POLL_INTERVAL
EOF
chmod 644 "$CONFIG_DIR/config.env"

install_linux() {
    log "Installing systemd service: $SERVICE_NAME"
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=IPv6/IPv4 Watch — send webhook on IP change
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=IPV6_WATCH_CONFIG=$CONFIG_DIR/config.env
ExecStart=$TARGET_SCRIPT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"

    echo ""
    echo "Installation complete (Linux/systemd)!"
    echo ""
    echo "  Script : $TARGET_SCRIPT"
    echo "  Config : $CONFIG_DIR/config.env"
    echo "  Service: $SERVICE_NAME"
    echo ""
    echo "Status: systemctl status $SERVICE_NAME"
    echo "Logs:   journalctl -u $SERVICE_NAME -f"
    echo ""
    echo "Uninstall:"
    echo "  sudo systemctl disable --now $SERVICE_NAME"
    echo "  sudo rm /etc/systemd/system/${SERVICE_NAME}.service"
    echo "  sudo rm -rf $CONFIG_DIR $TARGET_SCRIPT"
    echo "  sudo systemctl daemon-reload"
}

install_macos() {
    local plist="/Library/LaunchDaemons/net.ipv6watch.plist"

    log "Installing launchd daemon -> $plist"
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>net.ipv6watch</string>
    <key>ProgramArguments</key>
    <array>
        <string>$TARGET_SCRIPT</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>IPV6_WATCH_CONFIG</key>
        <string>$CONFIG_DIR/config.env</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/ipv6-watch.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/ipv6-watch.err</string>
</dict>
</plist>
EOF

    chmod 644 "$plist"
    launchctl bootout system/net.ipv6watch 2>/dev/null || true
    launchctl bootstrap system "$plist"
    launchctl enable system/net.ipv6watch
    launchctl kickstart -k system/net.ipv6watch

    echo ""
    echo "Installation complete (macOS/launchd)!"
    echo ""
    echo "  Script : $TARGET_SCRIPT"
    echo "  Config : $CONFIG_DIR/config.env"
    echo "  Daemon : net.ipv6watch"
    echo ""
    echo "Logs: tail -f /var/log/ipv6-watch.log"
    echo ""
    echo "Uninstall:"
    echo "  sudo launchctl bootout system/net.ipv6watch"
    echo "  sudo rm $plist $TARGET_SCRIPT"
    echo "  sudo rm -rf $CONFIG_DIR /var/log/ipv6-watch.log /var/log/ipv6-watch.err"
}

case "$PLATFORM" in
    Linux)  install_linux ;;
    Darwin) install_macos ;;
    *)      die "Unsupported operating system: $PLATFORM" ;;
esac
