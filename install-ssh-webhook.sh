#!/usr/bin/env bash
# install-ssh-webhook.sh — Install SSH connect/disconnect webhook monitor on Linux (systemd)
#
# Usage (interactive one-liner — stdin stays on TTY, like Proxmox helper scripts):
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-ssh-webhook.sh)"
#
# Usage (with webhook URL):
#   sudo bash -c "$(curl -fsSL .../install-ssh-webhook.sh)" _ --webhook-url "https://example.com/webhook/xxx"

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/khoazero123/ip-watch/master"
WEBHOOK_URL=""
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/remote-access-watch"
SERVICE_NAME="remote-access-watch"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"

usage() {
    cat <<EOF
Install remote-access-watch (SSH) — send webhook on SSH connect/disconnect

Usage:
  sudo $0 [--webhook-url URL] [options]

Options:
  --webhook-url URL    n8n webhook URL (prompts interactively if omitted)
  --help               Show this help message

Examples:
  sudo $0
  sudo $0 --webhook-url "https://example.com/webhook/xxx"
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
    echo "$(get_installer_home)/.config/remote-access-watch/install.env"
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
    dir="$home/.config/remote-access-watch"
    file="$dir/install.env"
    mkdir -p "$dir"
    printf 'WEBHOOK_URL="%s"\n' "$WEBHOOK_URL" > "$file"
    chmod 600 "$file"
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        chown "$SUDO_USER:$SUDO_USER" "$dir" "$file" 2>/dev/null || true
    fi
}

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
  sudo bash -c "\$(curl -fsSL $REPO_RAW/install-ssh-webhook.sh)"

  # Non-interactive:
  sudo bash -c "\$(curl -fsSL $REPO_RAW/install-ssh-webhook.sh)" _ \\
    --webhook-url 'https://example.com/webhook/xxx'

  REMOTE_ACCESS_WEBHOOK='https://example.com/webhook/xxx' \\
    sudo bash -c "\$(curl -fsSL $REPO_RAW/install-ssh-webhook.sh)"
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
    tty_print "Enter your n8n webhook URL for SSH remote access alerts."
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
        --webhook-url) WEBHOOK_URL="$2"; shift 2 ;;
        --help|-h)     usage; exit 0 ;;
        *)             die "Unknown argument: $1 (use --help)" ;;
    esac
done

[[ "$(id -u)" -eq 0 ]] || die "Must be run as root (sudo)."

PLATFORM="$(uname -s)"
[[ "$PLATFORM" == "Linux" ]] || die "SSH webhook installer supports Linux only."

SAVED_WEBHOOK="$(read_saved_webhook_url || true)"

if [[ -z "$WEBHOOK_URL" && -n "${REMOTE_ACCESS_WEBHOOK:-}" ]]; then
    WEBHOOK_URL="$REMOTE_ACCESS_WEBHOOK"
fi

if [[ -z "$WEBHOOK_URL" ]]; then
    prompt_webhook_url "$SAVED_WEBHOOK"
else
    WEBHOOK_URL="$(echo "$WEBHOOK_URL" | xargs)"
    [[ "$WEBHOOK_URL" =~ ^https?:// ]] || die "Invalid Webhook URL: $WEBHOOK_URL"
fi

save_webhook_url_to_user_config
log "Saved webhook URL -> $(user_install_config)"

SOURCE_SCRIPT="$SCRIPT_DIR/ssh-webhook.sh"
TARGET_SCRIPT="$INSTALL_DIR/ssh-webhook.sh"

if [[ -n "$SCRIPT_DIR" && -f "$SOURCE_SCRIPT" ]]; then
    log "Copying script -> $TARGET_SCRIPT"
    install -m 755 "$SOURCE_SCRIPT" "$TARGET_SCRIPT"
else
    log "Downloading ssh-webhook.sh from GitHub -> $TARGET_SCRIPT"
    curl -fsSL "$REPO_RAW/ssh-webhook.sh" -o "$TARGET_SCRIPT"
    chmod 755 "$TARGET_SCRIPT"
fi

log "Writing config -> $CONFIG_DIR/config.env"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/config.env" <<EOF
WEBHOOK_URL="$WEBHOOK_URL"
EOF
chmod 644 "$CONFIG_DIR/config.env"

log "Installing systemd service: $SERVICE_NAME"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Remote Access Watch — SSH connect/disconnect webhook
After=network-online.target ssh.service sshd.service
Wants=network-online.target

[Service]
Type=simple
Environment=REMOTE_ACCESS_CONFIG=$CONFIG_DIR/config.env
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
