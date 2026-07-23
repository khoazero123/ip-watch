#!/usr/bin/env bash
# install-ip-watch.sh — Install ip-watch on Linux (systemd) and macOS (launchd)
#
# Usage (interactive one-liner — stdin stays on TTY):
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-ip-watch.sh)"
#
# Usage (with webhook URL):
#   sudo bash -c "$(curl -fsSL .../install-ip-watch.sh)" _ --webhook-url "https://example.com/webhook/xxx"

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/khoazero123/ip-watch/master"
INSTALL_ONE_LINER='sudo bash -c "$(curl -fsSL '"$REPO_RAW"'/install-ip-watch.sh)"'
WEBHOOK_URL=""
IFACES=""
POLL_INTERVAL=10
INIT_WAIT_IPV6_SECONDS=30
INCLUDE_TAILSCALE=true
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/ip-watch"
SERVICE_NAME="ip-watch"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"

usage() {
    cat <<EOF
Install ip-watch — monitor IP changes and send webhook notifications

Usage:
  $INSTALL_ONE_LINER

With options (append after _):
  sudo bash -c "\$(curl -fsSL $REPO_RAW/install-ip-watch.sh)" _ --webhook-url URL [options]

Options:
  --webhook-url URL        n8n webhook URL (prompts interactively if omitted)
  --ifaces IFACES          Space-separated interface names (default: auto-detect)
  --poll-interval SEC      Polling interval in seconds (default: 10)
  --init-wait-ipv6 SEC     Seconds to wait for IPv6 before initial send (default: 30)
  --include-tailscale BOOL Include tailscale0 when it has an IP (default: true)
  --help                   Show this help message

Examples:
  $INSTALL_ONE_LINER
  sudo bash -c "\$(curl -fsSL $REPO_RAW/install-ip-watch.sh)" _ --webhook-url "https://example.com/webhook/xxx"
  sudo bash -c "\$(curl -fsSL $REPO_RAW/install-ip-watch.sh)" _ --webhook-url "https://..." --ifaces "eth0 wlan0"
EOF
}

log() { echo "==> $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

get_installer_home() {
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        getent passwd "$SUDO_USER" | cut -d: -f6
    else
        echo "$HOME"
    fi
}

user_install_config() {
    echo "$(get_installer_home)/.config/ip-watch/install.env"
}

read_saved_webhook_url() {
    local file saved
    file="$(user_install_config)"
    [[ -f "$file" ]] || return 0
    saved="$(grep -E '^\s*WEBHOOK_URL=' "$file" | head -1 | cut -d= -f2- | tr -d '"'"'"'' | xargs)"
    [[ -n "$saved" ]] && echo "$saved"
}

save_webhook_url_to_user_config() {
    local file dir home
    home="$(get_installer_home)"
    dir="$home/.config/ip-watch"
    file="$dir/install.env"
    mkdir -p "$dir"
    printf 'WEBHOOK_URL="%s"\n' "$WEBHOOK_URL" > "$file"
    chmod 600 "$file"
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        chown "$SUDO_USER:$SUDO_USER" "$dir" "$file" 2>/dev/null || true
    fi
}

# When run via "curl | bash", stdin is a pipe — use: sudo bash -c "$(curl -fsSL ...)"
tty_print() {
    if [[ -t 1 ]]; then
        echo "$@"
    elif [[ -e /dev/tty ]] && { echo "$@" >/dev/tty; } 2>/dev/null; then
        :
    else
        echo "$@"
    fi
}

tty_read() {
    local prompt="$1"
    if [[ -t 0 ]]; then
        read -rp "$prompt" WEBHOOK_URL
    elif [[ -e /dev/tty ]]; then
        read -rp "$prompt" WEBHOOK_URL </dev/tty 2>/dev/null || return 1
    else
        return 1
    fi
}

can_use_dev_tty() {
    ( exec 3<>/dev/tty ) 2>/dev/null
}

can_prompt_interactively() {
    [[ -t 0 ]] && return 0
    can_use_dev_tty
}

pipe_install_hint() {
    cat >&2 <<EOF
[ERROR] Cannot prompt for Webhook URL when stdin is a pipe.

Use one of these instead:

  # Interactive one-liner (stdin stays on TTY):
  $INSTALL_ONE_LINER

  # Non-interactive:
  sudo bash -c "\$(curl -fsSL $REPO_RAW/install-ip-watch.sh)" _ \\
    --webhook-url 'https://example.com/webhook/xxx'

  sudo IPWATCH_WEBHOOK='https://example.com/webhook/xxx' \\
    bash -c "\$(curl -fsSL $REPO_RAW/install-ip-watch.sh)"
EOF
}

prompt_webhook_url() {
    local default_url="${1:-}"

    if ! can_prompt_interactively; then
        if [[ -n "$default_url" ]]; then
            WEBHOOK_URL="$default_url"
            return 0
        fi
        pipe_install_hint
        exit 1
    fi

    tty_print ""
    tty_print "Enter your n8n webhook URL."
    if [[ -n "$default_url" ]]; then
        tty_print "Press Enter to use the saved URL."
    fi
    tty_print "Example: https://example.com/webhook/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    tty_print ""

    while true; do
        if [[ -n "$default_url" ]]; then
            if [[ -t 0 ]]; then
                read -rp "Webhook URL [$default_url]: " WEBHOOK_URL
            elif [[ -e /dev/tty ]]; then
                read -rp "Webhook URL [$default_url]: " WEBHOOK_URL </dev/tty 2>/dev/null || { pipe_install_hint; exit 1; }
            fi
            WEBHOOK_URL="${WEBHOOK_URL:-$default_url}"
        else
            if ! tty_read "Webhook URL: "; then
                pipe_install_hint
                exit 1
            fi
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
        --init-wait-ipv6) INIT_WAIT_IPV6_SECONDS="$2"; shift 2 ;;
        --include-tailscale) INCLUDE_TAILSCALE="$2"; shift 2 ;;
        --help|-h)       usage; exit 0 ;;
        *)               die "Unknown argument: $1 (use --help)" ;;
    esac
done

[[ "$(id -u)" -eq 0 ]] || die "Must be run as root (sudo)."

SAVED_WEBHOOK="$(read_saved_webhook_url || true)"

if [[ -z "$WEBHOOK_URL" && -n "${IPWATCH_WEBHOOK:-}" ]]; then
    WEBHOOK_URL="$IPWATCH_WEBHOOK"
fi

if [[ -z "$WEBHOOK_URL" ]]; then
    prompt_webhook_url "$SAVED_WEBHOOK"
else
    WEBHOOK_URL="$(echo "$WEBHOOK_URL" | xargs)"
    [[ "$WEBHOOK_URL" =~ ^https?:// ]] || die "Invalid Webhook URL: $WEBHOOK_URL"
fi

save_webhook_url_to_user_config
log "Saved webhook URL -> $(user_install_config)"

SOURCE_SCRIPT="$SCRIPT_DIR/ip-watch.sh"
TARGET_SCRIPT="$INSTALL_DIR/ip-watch.sh"
PLATFORM="$(uname -s)"

if [[ -n "$SCRIPT_DIR" && -f "$SOURCE_SCRIPT" ]]; then
    log "Copying script -> $TARGET_SCRIPT"
    install -m 755 "$SOURCE_SCRIPT" "$TARGET_SCRIPT"
else
    log "Downloading ip-watch.sh from GitHub -> $TARGET_SCRIPT"
    curl -fsSL "$REPO_RAW/ip-watch.sh" -o "$TARGET_SCRIPT"
    chmod 755 "$TARGET_SCRIPT"
fi

log "Writing config -> $CONFIG_DIR/config.env"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/config.env" <<EOF
WEBHOOK_URL="$WEBHOOK_URL"
IFACES="$IFACES"
POLL_INTERVAL=$POLL_INTERVAL
INIT_WAIT_IPV6_SECONDS=$INIT_WAIT_IPV6_SECONDS
INCLUDE_TAILSCALE=$INCLUDE_TAILSCALE
EOF
chmod 644 "$CONFIG_DIR/config.env"

install_linux() {
    log "Installing systemd service: $SERVICE_NAME"
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=IP Watch — send webhook on IP change
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=IPWATCH_CONFIG=$CONFIG_DIR/config.env
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
    echo "  Script        : $TARGET_SCRIPT"
    echo "  Service cfg   : $CONFIG_DIR/config.env"
    echo "  Installer cfg : $(user_install_config)"
    echo "  Service       : $SERVICE_NAME"
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
    local plist="/Library/LaunchDaemons/net.ipwatch.plist"

    log "Installing launchd daemon -> $plist"
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>net.ipwatch</string>
    <key>ProgramArguments</key>
    <array>
        <string>$TARGET_SCRIPT</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>IPWATCH_CONFIG</key>
        <string>$CONFIG_DIR/config.env</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/ip-watch.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/ip-watch.err</string>
</dict>
</plist>
EOF

    chmod 644 "$plist"
    launchctl bootout system/net.ipwatch 2>/dev/null || true
    launchctl bootstrap system "$plist"
    launchctl enable system/net.ipwatch
    launchctl kickstart -k system/net.ipwatch

    echo ""
    echo "Installation complete (macOS/launchd)!"
    echo ""
    echo "  Script : $TARGET_SCRIPT"
    echo "  Config : $CONFIG_DIR/config.env"
    echo "  Daemon : net.ipwatch"
    echo ""
    echo "Logs: tail -f /var/log/ip-watch.log"
    echo ""
    echo "Uninstall:"
    echo "  sudo launchctl bootout system/net.ipwatch"
    echo "  sudo rm $plist $TARGET_SCRIPT"
    echo "  sudo rm -rf $CONFIG_DIR /var/log/ip-watch.log /var/log/ip-watch.err"
}

case "$PLATFORM" in
    Linux)  install_linux ;;
    Darwin) install_macos ;;
    *)      die "Unsupported operating system: $PLATFORM" ;;
esac
