#!/usr/bin/env bash
# ip-watch.sh — Monitor IPv4/IPv6 changes and send webhook notifications (Linux + macOS)
# Configuration: /etc/ip-watch/config.env

set -euo pipefail

CONFIG_FILE="${IPWATCH_CONFIG:-/etc/ip-watch/config.env}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERROR] Config not found: $CONFIG_FILE" >&2
    echo "        Run install-ip-watch.sh to install." >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

: "${WEBHOOK_URL:?WEBHOOK_URL is not configured in $CONFIG_FILE}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
IFACES="${IFACES:-}"

HOSTNAME="$(hostname -s 2>/dev/null || hostname)"
PLATFORM="$(uname -s | tr '[:upper:]' '[:lower:]')"
LAST_DATA=""

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

detect_ifaces() {
    if [[ -n "$IFACES" ]]; then
        echo "$IFACES"
        return
    fi

    case "$PLATFORM" in
        linux)
            ip -o link show up | awk -F': ' '{print $2}' | grep -Ev '^(lo|docker|br-|veth|virbr)' || true
            ;;
        darwin)
            networksetup -listallhardwareports 2>/dev/null \
                | awk '/Device:/{print $2}' \
                | while read -r dev; do
                    ipconfig getifaddr "$dev" >/dev/null 2>&1 && echo "$dev"
                    ifconfig "$dev" 2>/dev/null | grep -q 'inet6 ' && echo "$dev"
                done | sort -u || true
            ;;
        *)
            echo "[ERROR] Unsupported operating system: $PLATFORM" >&2
            exit 1
            ;;
    esac
}

get_ipv6() {
    local iface="$1"
    case "$PLATFORM" in
        linux)
            # Prefer active global IPv6; skip link-local (fe80), temporary, and deprecated.
            # Note: "mngtmpaddr" is a host flag, NOT a temporary address — do not filter it.
            ip -6 addr show dev "$iface" scope global 2>/dev/null \
                | awk '
                    /inet6/ {
                        if ($0 ~ / fe80:/) next
                        if ($0 ~ / temporary /) next
                        if ($0 ~ / deprecated /) next
                        sub(/\/.*$/, "", $2)
                        print $2
                        exit
                    }'
            ;;
        darwin)
            ifconfig "$iface" 2>/dev/null \
                | awk '/inet6/ && !/fe80:/ && !/ temporary / {print $2; exit}'
            ;;
    esac
}

get_ipv4() {
    local iface="$1"
    case "$PLATFORM" in
        linux)
            ip -4 addr show dev "$iface" scope global 2>/dev/null \
                | awk '/inet / && !/127\./ && !/169\.254\./ {print $2; exit}'
            ;;
        darwin)
            ipconfig getifaddr "$iface" 2>/dev/null || true
            ;;
    esac
}

get_mac() {
    local iface="$1"
    case "$PLATFORM" in
        linux)
            ip link show "$iface" 2>/dev/null | awk '/link\/ether/ {print $2; exit}'
            ;;
        darwin)
            ifconfig "$iface" 2>/dev/null | awk '/ether/ {print $2; exit}'
            ;;
    esac
}

build_payload() {
    local event="$1"
    local ifjson=""
    local iface ipv6 ipv4 mac

    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue

        ipv6="$(get_ipv6 "$iface")"
        ipv4="$(get_ipv4 "$iface")"
        mac="$(get_mac "$iface")"

        [[ -n "$ipv6" ]] && ipv6="${ipv6%%/*}"
        [[ -n "$ipv4" ]] && ipv4="${ipv4%%/*}"

        [[ -z "$ipv6" && -z "$ipv4" ]] && continue

        ifjson="${ifjson}\"${iface}\":{"
        [[ -n "$ipv6" ]] && ifjson="${ifjson}\"ipv6\":\"${ipv6}\","
        [[ -n "$ipv4" ]] && ifjson="${ifjson}\"ipv4\":\"${ipv4}\","
        ifjson="${ifjson}\"mac\":\"${mac}\"},"
    done < <(detect_ifaces)

    ifjson="${ifjson%,}"

    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%S')"

    cat <<EOF
{"source":"ip-watch","platform":"${PLATFORM}","event_type":"${event}","hostname":"${HOSTNAME}","timestamp":"${ts}","interfaces":{${ifjson}}}
EOF
}

send_payload() {
    local payload="$1"
    if curl -sf -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json; charset=utf-8" \
        -d "$payload" \
        --max-time 15; then
        return 0
    fi
    return 1
}

# --- Main ---
log "Starting ip-watch (hostname=$HOSTNAME, platform=$PLATFORM, poll=${POLL_INTERVAL}s)"

while true; do
    payload="$(build_payload init)"
    if echo "$payload" | grep -q '"interfaces":{}'; then
        log "No IP detected, retrying in 5s..."
        sleep 5
        continue
    fi

    log "Init payload: $payload"
    if send_payload "$payload"; then
        LAST_DATA="$payload"
        log "Init sent successfully."
        break
    fi

    log "Init failed, retrying in 5s..."
    sleep 5
done

watch_linux() {
    ip monitor address 2>/dev/null | while read -r _; do
        payload="$(build_payload changed)"
        if [[ "$payload" != "$LAST_DATA" ]]; then
            log "Changed payload: $payload"
            if send_payload "$payload"; then
                LAST_DATA="$payload"
                log "IP change notification sent."
            fi
        fi
    done
}

watch_poll() {
    while true; do
        sleep "$POLL_INTERVAL"
        payload="$(build_payload changed)"
        if [[ "$payload" != "$LAST_DATA" ]]; then
            log "Changed payload: $payload"
            if send_payload "$payload"; then
                LAST_DATA="$payload"
                log "IP change notification sent."
            fi
        fi
    done
}

if [[ "$PLATFORM" == "linux" ]] && ip monitor address >/dev/null 2>&1; then
    log "Watch mode: ip monitor (Linux)"
    watch_linux
else
    log "Watch mode: polling every ${POLL_INTERVAL}s"
    watch_poll
fi
