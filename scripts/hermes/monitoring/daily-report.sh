#!/usr/bin/env bash
# Körs dagligen kl 08:00 av hermes-daily-report.timer.
# Läser tillståndsfiler och SSL-data, skickar en daglig summering via Telegram.

set -euo pipefail

SITES_CONF="/etc/hermes-monitoring/sites.conf"
ENV_FILE="/home/hermes/.config/hermes-monitoring/env"
STATE_DIR="/var/lib/hermes/monitoring/state"
LOG_FILE="/var/log/hermes/monitoring.log"

# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_CHAT_ID:-}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] daily-report: $*" >> "$LOG_FILE"
}

send_telegram() {
    local msg="$1"
    [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ] && { log "WARN: Telegram-credentials saknas"; return 0; }
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=${msg}" \
        > /dev/null 2>&1 || log "WARN: Telegram-utskick misslyckades"
}

check_ssl_days() {
    local host="$1"
    local expiry days_left
    expiry=$(echo Q | timeout 15 openssl s_client \
        -connect "${host}:443" \
        -servername "$host" \
        2>/dev/null | \
        openssl x509 -noout -enddate 2>/dev/null | \
        cut -d= -f2) || { echo "-1"; return; }
    [ -z "$expiry" ] && { echo "-1"; return; }
    local expiry_epoch now_epoch
    expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null) || { echo "-1"; return; }
    now_epoch=$(date +%s)
    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
    echo "$days_left"
}

mkdir -p "$(dirname "$LOG_FILE")"

if [ ! -f "$SITES_CONF" ]; then
    log "FEL: $SITES_CONF saknas"
    exit 1
fi

total=0
up_count=0
down_list=""
ssl_expiring=""

while IFS='|' read -r url name _expected; do
    [[ "$url" =~ ^[[:space:]]*#.*$ || -z "${url// }" ]] && continue
    url="${url// }"
    name="${name// }"
    host=$(echo "$url" | sed 's|https\?://||' | cut -d/ -f1 | cut -d: -f1)

    total=$(( total + 1 ))

    state_key=$(echo "$url" | tr -cs 'a-zA-Z0-9' '_')
    state_file="$STATE_DIR/${state_key}.status"
    status="okänd"
    [ -f "$state_file" ] && status=$(cat "$state_file")

    if [ "$status" = "up" ]; then
        up_count=$(( up_count + 1 ))
    else
        down_list="${down_list}\n  • ${name} (${url}) – status: ${status}"
    fi

    # SSL-kollar bara i dagliga rapporten om < 60 dagar kvar
    if [[ "$url" == https://* ]]; then
        days=$(check_ssl_days "$host")
        if [ "$days" -lt 60 ] 2>/dev/null && [ "$days" -ge 0 ] 2>/dev/null; then
            ssl_expiring="${ssl_expiring}\n  • ${name}: ${days} dagar kvar"
        fi
    fi

done < "$SITES_CONF"

# Bygg rapport
if [ "$up_count" -eq "$total" ]; then
    status_line="✅ Alla ${total} sajter är uppe"
else
    down_count=$(( total - up_count ))
    status_line="🚨 ${down_count} av ${total} sajter är NERE"
fi

msg="📊 <b>Daglig statusrapport</b> – $(date '+%Y-%m-%d %H:%M')"
msg="${msg}\n\n${status_line}"

if [ -n "$down_list" ]; then
    msg="${msg}\n\n<b>Sajter som är nere:</b>${down_list}"
fi

if [ -n "$ssl_expiring" ]; then
    msg="${msg}\n\n🔒 <b>SSL-certifikat att förnya snart:</b>${ssl_expiring}"
fi

msg="${msg}\n\nNästa rapport: imorgon 08:00"

send_telegram "$msg"
log "Daglig rapport skickad: ${up_count}/${total} uppe"
