#!/usr/bin/env bash
# Kontrollerar web-hosting-prod (89.167.90.112) via SSH.
# Checkar: SSH-anslutning, disk, minne, webbserver.
# Del av hermes-infra-check.service – körs var 10:e minut.

set -euo pipefail

CONF_FILE="/etc/hermes-monitoring/infra.conf"
ENV_FILE="/home/hermes/.config/hermes-monitoring/env"
LOG_FILE="/var/log/hermes/monitoring.log"

# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && source "$ENV_FILE"
# shellcheck source=/dev/null
[ -f "$CONF_FILE" ] && source "$CONF_FILE"

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_CHAT_ID:-}"
WEBHOSTING_HOST="${WEBHOSTING_HOST:-89.167.90.112}"
WEBHOSTING_SSH_USER="${WEBHOSTING_SSH_USER:-deploy}"
WEBHOSTING_SSH_KEY="${WEBHOSTING_SSH_KEY:-/home/hermes/.ssh/id_ed25519_webhosting}"
DISK_WARN_PERCENT="${DISK_WARN_PERCENT:-80}"
DISK_CRIT_PERCENT="${DISK_CRIT_PERCENT:-90}"
MEM_WARN_PERCENT="${MEM_WARN_PERCENT:-85}"
MEM_CRIT_PERCENT="${MEM_CRIT_PERCENT:-95}"

STATE_DIR="/var/lib/hermes/monitoring/state"
mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] webhosting-check: $*" >> "$LOG_FILE"; }

send_telegram() {
    local msg="$1"
    [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ] && { log "WARN: Telegram-credentials saknas"; return 0; }
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=${msg}" \
        > /dev/null 2>&1 || log "WARN: Telegram-utskick misslyckades"
}

alert_if_changed() {
    local key="$1" status="$2" msg_down="$3" msg_up="$4"
    local state_file="$STATE_DIR/webhosting_${key}.status"
    local prev="up"
    [ -f "$state_file" ] && prev=$(cat "$state_file")
    if [ "$status" = "down" ]; then
        [ "$prev" != "down" ] && send_telegram "$msg_down"
        echo "down" > "$state_file"
    else
        [ "$prev" = "down" ] && send_telegram "$msg_up"
        echo "up" > "$state_file"
    fi
}

if [ ! -f "$WEBHOSTING_SSH_KEY" ]; then
    log "FEL: SSH-nyckel saknas: $WEBHOSTING_SSH_KEY"
    log "     Kör phase4-setup-infra.sh för att kopiera nyckeln"
    exit 1
fi

# --- SSH-anslutning och remote-check ---
# Kör ett kompakt kommando som samlar disk%, RAM% och webbserver-status
remote_output=$(ssh \
    -i "$WEBHOSTING_SSH_KEY" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=15 \
    -o BatchMode=yes \
    "${WEBHOSTING_SSH_USER}@${WEBHOSTING_HOST}" \
    'printf "DISK:%s\n" $(df -P / | awk "NR==2{gsub(/%/,\"\",$5);print $5}"); printf "MEM:%s\n" $(free | awk "/^Mem:/{printf \"%.0f\", $3/$2*100}"); WEB=unknown; systemctl is-active nginx >/dev/null 2>&1 && WEB=nginx; systemctl is-active apache2 >/dev/null 2>&1 && WEB=apache2; printf "WEB:%s\n" $WEB; printf "UP:%s\n" "$(uptime -p)"' \
    2>/dev/null) || {
        log "FAIL SSH till $WEBHOSTING_HOST misslyckades"
        alert_if_changed "ssh" "down" \
            "🚨 <b>web-hosting-prod kan inte nås!</b>\nSSH till ${WEBHOSTING_HOST} misslyckades\nTid: $(date '+%H:%M %Z')" \
            "✅ <b>web-hosting-prod är åtkomlig igen</b>"
        exit 0
    }

log "OK   SSH till $WEBHOSTING_HOST lyckades"
alert_if_changed "ssh" "up" "" ""

# Parsa output
disk_pct=$(echo "$remote_output" | grep '^DISK:' | cut -d: -f2)
mem_pct=$(echo "$remote_output"  | grep '^MEM:'  | cut -d: -f2)
web_svc=$(echo "$remote_output"  | grep '^WEB:'  | cut -d: -f2)
uptime_str=$(echo "$remote_output" | grep '^UP:'   | cut -d: -f2-)

log "INFO web-hosting disk=${disk_pct}% ram=${mem_pct}% web=${web_svc} ${uptime_str}"

# Disk-check
if [ -n "$disk_pct" ]; then
    if [ "$disk_pct" -ge "$DISK_CRIT_PERCENT" ] 2>/dev/null; then
        alert_if_changed "disk" "down" \
            "🔴 <b>web-hosting-prod: Disk kritisk!</b>\n/ används till <b>${disk_pct}%</b>\nTid: $(date '+%H:%M %Z')" \
            "✅ <b>web-hosting-prod: Disk normaliserad</b>: ${disk_pct}%"
    elif [ "$disk_pct" -ge "$DISK_WARN_PERCENT" ] 2>/dev/null; then
        alert_if_changed "disk" "down" \
            "⚠️ <b>web-hosting-prod: Disk-varning</b>\n/ används till <b>${disk_pct}%</b>" \
            "✅ <b>web-hosting-prod: Disk normaliserad</b>: ${disk_pct}%"
    else
        alert_if_changed "disk" "up" "" ""
    fi
fi

# RAM-check
if [ -n "$mem_pct" ]; then
    if [ "$mem_pct" -ge "$MEM_CRIT_PERCENT" ] 2>/dev/null; then
        alert_if_changed "mem" "down" \
            "🔴 <b>web-hosting-prod: RAM kritiskt!</b>\nRAM-användning: <b>${mem_pct}%</b>\nTid: $(date '+%H:%M %Z')" \
            "✅ <b>web-hosting-prod: RAM normaliserat</b>: ${mem_pct}%"
    elif [ "$mem_pct" -ge "$MEM_WARN_PERCENT" ] 2>/dev/null; then
        alert_if_changed "mem" "down" \
            "⚠️ <b>web-hosting-prod: RAM-varning</b>\nRAM-användning: <b>${mem_pct}%</b>" \
            "✅ <b>web-hosting-prod: RAM normaliserat</b>: ${mem_pct}%"
    else
        alert_if_changed "mem" "up" "" ""
    fi
fi

# Webbserver-check
if [ "$web_svc" = "unknown" ]; then
    log "WARN Ingen webbserver (nginx/apache2) aktiv på $WEBHOSTING_HOST"
    alert_if_changed "webserver" "down" \
        "⚠️ <b>web-hosting-prod: Ingen webbserver aktiv</b>\nVarken nginx eller apache2 körs\nTid: $(date '+%H:%M %Z')" \
        "✅ <b>web-hosting-prod: Webbserver aktiv igen</b>"
else
    log "OK   Webbserver $web_svc aktiv på $WEBHOSTING_HOST"
    alert_if_changed "webserver" "up" "" ""
fi

log "Webhosting-check klar"
