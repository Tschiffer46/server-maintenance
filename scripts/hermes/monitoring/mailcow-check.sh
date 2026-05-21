#!/usr/bin/env bash
# Kontrollerar Mailcow-hälsa på lokal server.
# Checkar: web-UI (HTTP), SMTP-portar, disk.
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
MAILCOW_HOST="${MAILCOW_HOST:-127.0.0.1}"
MAILCOW_HTTP_PORT="${MAILCOW_HTTP_PORT:-81}"
MAILCOW_PORTS="${MAILCOW_PORTS:-25 465 587 993}"
DISK_WARN_PERCENT="${DISK_WARN_PERCENT:-80}"
DISK_CRIT_PERCENT="${DISK_CRIT_PERCENT:-90}"

STATE_DIR="/var/lib/hermes/monitoring/state"
mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] mailcow-check: $*" >> "$LOG_FILE"; }

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
    local state_file="$STATE_DIR/mailcow_${key}.status"
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

# --- HTTP-check av Mailcow web-UI ---
http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 10 --max-time 20 \
    "http://${MAILCOW_HOST}:${MAILCOW_HTTP_PORT}/" 2>/dev/null || echo "000")

if [ "$http_code" = "000" ] || [ "$http_code" = "502" ] || [ "$http_code" = "503" ]; then
    log "FAIL Mailcow web-UI → HTTP $http_code"
    alert_if_changed "webui" "down" \
        "🚨 <b>Mailcow web-UI svarar inte!</b>\nHTTP ${http_code}\nTid: $(date '+%H:%M %Z')" \
        "✅ <b>Mailcow web-UI är tillbaka</b>\nHTTP ${http_code}"
else
    log "OK   Mailcow web-UI → HTTP $http_code"
    alert_if_changed "webui" "up" "" ""
fi

# --- Port-checkar (SMTP, SMTPS, Submission, IMAPS) ---
for port in $MAILCOW_PORTS; do
    if nc -z -w5 "$MAILCOW_HOST" "$port" 2>/dev/null; then
        log "OK   Mailcow port $port öppen"
        alert_if_changed "port${port}" "up" "" ""
    else
        log "FAIL Mailcow port $port stängd"
        case "$port" in
            25)  svc="SMTP" ;;
            465) svc="SMTPS" ;;
            587) svc="Submission" ;;
            993) svc="IMAPS" ;;
            *)   svc="port $port" ;;
        esac
        alert_if_changed "port${port}" "down" \
            "🚨 <b>Mailcow ${svc} (port ${port}) svarar inte!</b>\nTid: $(date '+%H:%M %Z')" \
            "✅ <b>Mailcow ${svc} (port ${port}) är tillbaka</b>"
    fi
done

# --- Disk-check (lokal server) ---
disk_pct=$(df -P / | awk 'NR==2{gsub(/%/,"",$5); print $5}')
log "INFO Disk / används till ${disk_pct}%"

if [ "$disk_pct" -ge "$DISK_CRIT_PERCENT" ] 2>/dev/null; then
    alert_if_changed "disk" "down" \
        "🔴 <b>KRITISK: Disk nästan full!</b>\n/ används till <b>${disk_pct}%</b>\nTid: $(date '+%H:%M %Z')" \
        "✅ <b>Disk-användning normaliserad</b>: ${disk_pct}%"
elif [ "$disk_pct" -ge "$DISK_WARN_PERCENT" ] 2>/dev/null; then
    alert_if_changed "disk" "down" \
        "⚠️ <b>Disk-varning:</b> / används till <b>${disk_pct}%</b>\nÅtgärda innan det är fullt!" \
        "✅ <b>Disk-användning normaliserad</b>: ${disk_pct}%"
else
    alert_if_changed "disk" "up" "" ""
fi

log "Mailcow-check klar"
