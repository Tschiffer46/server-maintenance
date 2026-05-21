#!/usr/bin/env bash
# Körs var 6:e timme av hermes-ssl-check.timer.
# Kontrollerar SSL-certifikat och DNS för alla sajter i sites.conf.
# Varnar via Telegram om:
#   • SSL-certifikat löper ut om < 30 dagar
#   • DNS-uppsökning misslyckas

set -euo pipefail

SITES_CONF="/etc/hermes-monitoring/sites.conf"
ENV_FILE="/home/hermes/.config/hermes-monitoring/env"
LOG_FILE="/var/log/hermes/monitoring.log"
SSL_WARN_DAYS=30

# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_CHAT_ID:-}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ssl-check: $*" >> "$LOG_FILE"
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

check_dns() {
    local host="$1"
    host "$host" > /dev/null 2>&1
}

mkdir -p "$(dirname "$LOG_FILE")"

if [ ! -f "$SITES_CONF" ]; then
    log "FEL: $SITES_CONF saknas"
    exit 1
fi

ssl_warnings=""
dns_warnings=""

while IFS='|' read -r url name _expected; do
    [[ "$url" =~ ^[[:space:]]*#.*$ || -z "${url// }" ]] && continue
    url="${url// }"
    name="${name// }"

    # Extrahera hostname
    host=$(echo "$url" | sed 's|https\?://||' | cut -d/ -f1 | cut -d: -f1)

    # DNS-check
    if ! check_dns "$host"; then
        log "DNS FAIL $name ($host)"
        dns_warnings="${dns_warnings}\n  • ${name} (${host}) – DNS svarar inte"
    else
        log "DNS OK  $name ($host)"
    fi

    # SSL-check (bara HTTPS)
    if [[ "$url" == https://* ]]; then
        days=$(check_ssl_days "$host")
        if [ "$days" -lt 0 ] 2>/dev/null; then
            log "SSL ERR $name ($host) – kunde inte hämta certifikat"
            ssl_warnings="${ssl_warnings}\n  • ${name} – kunde inte kontrollera certifikat"
        elif [ "$days" -lt "$SSL_WARN_DAYS" ] 2>/dev/null; then
            log "SSL WARN $name ($host) – ${days} dagar kvar"
            ssl_warnings="${ssl_warnings}\n  • ${name} – ${days} dagar kvar"
        else
            log "SSL OK  $name ($host) – ${days} dagar kvar"
        fi
    fi

done < "$SITES_CONF"

# Skicka samlad varning om det finns problem
if [ -n "$ssl_warnings" ] || [ -n "$dns_warnings" ]; then
    msg="⚠️ <b>SSL/DNS-varning</b> – $(date '+%Y-%m-%d %H:%M')"
    [ -n "$ssl_warnings" ] && msg="${msg}\n\n🔒 <b>SSL-certifikat löper snart ut:</b>${ssl_warnings}"
    [ -n "$dns_warnings" ] && msg="${msg}\n\n🌍 <b>DNS-problem:</b>${dns_warnings}"
    send_telegram "$msg"
fi

log "SSL/DNS-körning klar"
