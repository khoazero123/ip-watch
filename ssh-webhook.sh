#!/usr/bin/env bash
# ssh-webhook.sh — Monitor SSH connect/disconnect and send webhook notifications (Linux)
# Configuration: /etc/remote-access-watch/config.env

set -euo pipefail

CONFIG_FILE="${REMOTE_ACCESS_CONFIG:-/etc/remote-access-watch/config.env}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERROR] Config not found: $CONFIG_FILE" >&2
    echo "        Run install-ssh-webhook.sh to install." >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

: "${WEBHOOK_URL:?WEBHOOK_URL is not configured in $CONFIG_FILE}"

HOSTNAME="$(hostname -s 2>/dev/null || hostname)"
PLATFORM="linux"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

send_webhook() {
    local event_type="$1"
    local username="$2"
    local source_ip="$3"
    local ts response http_code curl_exit
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local payload
    payload=$(cat <<EOF
{"source":"remote-access-watch","platform":"${PLATFORM}","event_type":"${event_type}","hostname":"${HOSTNAME}","timestamp":"${ts}","username":"${username}","source_ip":"${source_ip}"}
EOF
)

    response=$(curl -sS -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json; charset=utf-8" \
        --max-time 15 \
        -w $'\n__HTTP_CODE__:%{http_code}' \
        -d "$payload" 2>&1) || curl_exit=$?
    curl_exit=${curl_exit:-0}

    http_code="${response##*$'\n'__HTTP_CODE__:}"
    response="${response%$'\n'__HTTP_CODE__:*}"

    if [[ "$curl_exit" -eq 0 && "$http_code" =~ ^2[0-9]{2}$ ]]; then
        log "Webhook sent: ${event_type} user=${username} ip=${source_ip} (HTTP ${http_code})"
    else
        log "Webhook failed: ${event_type} user=${username} ip=${source_ip} (curl_exit=${curl_exit} HTTP ${http_code:-n/a}) ${response:-}"
    fi
}

process_line() {
    local line="$1"
    local username source_ip

    if [[ "$line" =~ Accepted\ (publickey|password|keyboard-interactive(/pam)?)\ for\ ([^[:space:]]+)\ from\ ([^[:space:]]+)\ port\ [0-9]+ ]]; then
        username="${BASH_REMATCH[3]}"
        source_ip="${BASH_REMATCH[4]}"
        send_webhook "ssh_connect" "$username" "$source_ip"
        return
    fi

    if [[ "$line" =~ Disconnected\ from\ user\ ([^[:space:]]+)\ ([0-9a-fA-F:.]+)\ port\ [0-9]+ ]]; then
        username="${BASH_REMATCH[1]}"
        source_ip="${BASH_REMATCH[2]}"
        send_webhook "ssh_disconnect" "$username" "$source_ip"
        return
    fi

    if [[ "$line" =~ Disconnected\ from\ ([0-9a-fA-F:.]+)\ port\ [0-9]+ ]]; then
        source_ip="${BASH_REMATCH[1]}"
        send_webhook "ssh_disconnect" "" "$source_ip"
    fi
}

follow_sshd_journal() {
    # The ssh unit journal often omits "Disconnected from ..." lines; sshd syslog has them all.
    if journalctl SYSLOG_IDENTIFIER=sshd -n 1 --no-pager >/dev/null 2>&1; then
        journalctl SYSLOG_IDENTIFIER=sshd -f -n 0 --no-pager
        return
    fi
    if systemctl is-active --quiet ssh 2>/dev/null; then
        journalctl -u ssh -f -n 0 --no-pager
        return
    fi
    if systemctl is-active --quiet sshd 2>/dev/null; then
        journalctl -u sshd -f -n 0 --no-pager
        return
    fi
    journalctl _COMM=sshd -f -n 0 --no-pager
}

log "Starting SSH webhook monitor (hostname=${HOSTNAME})"
log "Following sshd journal..."

follow_sshd_journal | while IFS= read -r line; do
    process_line "$line" || true
done
