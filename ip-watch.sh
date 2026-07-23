#!/usr/bin/env bash
# ip-watch.sh — Monitor IPv4/IPv6 changes and send webhook notifications (Linux + macOS)
# Configuration: /etc/ip-watch/config.env

set -euo pipefail

CONFIG_FILE="${IPWATCH_CONFIG:-/etc/ip-watch/config.env}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERROR] Config not found: $CONFIG_FILE" >&2
    echo "        Install with:" >&2
    echo '        sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-ip-watch.sh)"' >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

: "${WEBHOOK_URL:?WEBHOOK_URL is not configured in $CONFIG_FILE}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
INIT_WAIT_IPV6_SECONDS="${INIT_WAIT_IPV6_SECONDS:-30}"
INCLUDE_TAILSCALE="${INCLUDE_TAILSCALE:-true}"
IFACES="${IFACES:-}"

HOSTNAME="$(hostname -s 2>/dev/null || hostname)"
PLATFORM="$(uname -s | tr '[:upper:]' '[:lower:]')"
LAST_INTERFACES=""

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
            {
                ip -o link show up | awk -F': ' '{print $2}' | grep -Ev '^(lo|docker|br-|veth|virbr)' || true
                detect_tailscale_iface
            } | awk 'NF && !seen[$0]++'
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

detect_tailscale_iface() {
    [[ "$INCLUDE_TAILSCALE" =~ ^([Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss])$ ]] || return 0

    case "$PLATFORM" in
        linux)
            if ip addr show dev tailscale0 2>/dev/null | grep -Eq 'inet6? '; then
                echo "tailscale0"
            fi
            ;;
        darwin)
            ifconfig -l 2>/dev/null | tr ' ' '\n' | grep '^utun' | while read -r dev; do
                ifconfig "$dev" 2>/dev/null | grep -q '100\.' && echo "$dev"
            done
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

build_interfaces_json() {
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
    echo "{${ifjson}}"
}

build_payload() {
    local event="$1"
    local interfaces="${2:-$(build_interfaces_json)}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%S')"

    cat <<EOF
{"source":"ip-watch","platform":"${PLATFORM}","event_type":"${event}","hostname":"${HOSTNAME}","timestamp":"${ts}","interfaces":${interfaces}}
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

init_waited=0

while true; do
    interfaces="$(build_interfaces_json)"
    if [[ "$interfaces" == "{}" ]]; then
        log "No IP detected, retrying in 5s..."
        sleep 5
        init_waited=$((init_waited + 5))
        continue
    fi

    if ! echo "$interfaces" | grep -q '"ipv6":' && [[ "$init_waited" -lt "$INIT_WAIT_IPV6_SECONDS" ]]; then
        log "IPv4 detected but no IPv6 yet, waiting for IPv6 (${init_waited}/${INIT_WAIT_IPV6_SECONDS}s)..."
        sleep 5
        init_waited=$((init_waited + 5))
        continue
    fi

    payload="$(build_payload init "$interfaces")"
    log "Init payload: $payload"
    if send_payload "$payload"; then
        LAST_INTERFACES="$interfaces"
        log "Init sent successfully."
        break
    fi

    log "Init failed, retrying in 5s..."
    sleep 5
done

watch_linux() {
    ip monitor address 2>/dev/null | while read -r _; do
        interfaces="$(build_interfaces_json)"
        if [[ "$interfaces" != "$LAST_INTERFACES" ]]; then
            payload="$(build_payload changed "$interfaces")"
            log "Changed payload: $payload"
            if send_payload "$payload"; then
                LAST_INTERFACES="$interfaces"
                log "IP change notification sent."
            fi
        fi
    done
}

watch_poll() {
    while true; do
        sleep "$POLL_INTERVAL"
        interfaces="$(build_interfaces_json)"
        if [[ "$interfaces" != "$LAST_INTERFACES" ]]; then
            payload="$(build_payload changed "$interfaces")"
            log "Changed payload: $payload"
            if send_payload "$payload"; then
                LAST_INTERFACES="$interfaces"
                log "IP change notification sent."
            fi
        fi
    done
}

if [[ "$PLATFORM" == "linux" ]] && command -v ip >/dev/null 2>&1; then
    log "Watch mode: ip monitor (Linux)"
    watch_linux
else
    log "Watch mode: polling every ${POLL_INTERVAL}s"
    watch_poll
fi
