#!/usr/bin/env bash
# Körs var 5:e minut av hermes-site-check.timer.
# Kollar HTTP-status för alla sajter i /etc/hermes-monitoring/sites.conf.
# Skickar Telegram-varning när en sajt går ner, och ett återhämtningsmeddelande
# när den kommer tillbaka. Skickar INTE upprepade varningar medan sajten
# är nere (stateful via tillståndsfiler).

set -euo pipefail

SITES_CONF="/etc/hermes-monitoring/sites.conf"
ENV_FILE="/home/hermes/.config/hermes-monitoring/env"
STATE_DIR="/var/lib/hermes/monitoring/state"
LOG_FILE="/var/log/hermes/monitoring.log"
TIMEOUT_CONNECT=10
TIMEOUT_MAX=30

# Läs in Telegram-credentials
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_CHAT_ID:-}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] site-check: $*" >> "$LOG_FILE"
}

send_telegram() {
    local msg="$1"
    if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then
        log "WARN: Telegram-credentials saknas, hoppar över notifiering"
        return 0
    fi
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=${msg}" \
        > /dev/null 2>&1 || log "WARN: Telegram-utskick misslyckades"
}

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

if [ ! -f "$SITES_CONF" ]; then
    log "FEL: $SITES_CONF saknas – kör phase3-setup-monitoring.sh först"
    exit 1
fi

while IFS='|' read -r url name expected_codes; do
    # Hoppa över kommentarsrader och tomma rader
    [[ "$url" =~ ^[[:space:]]*#.*$ || -z "${url// }" ]] && continue

    url="${url// }"
    name="${name// }"
    expected_codes="${expected_codes// }"
    [ -z "$expected_codes" ] && expected_codes="200"

    # Använd URL som nökkel för tillståndsfilen (sänkta tecken)
    state_key=$(echo "$url" | tr -cs 'a-zA-Z0-9' '_')
    state_file="$STATE_DIR/${state_key}.status"

    # Gör HTTP-check
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout "$TIMEOUT_CONNECT" \
        --max-time "$TIMEOUT_MAX" \
        -L \
        "$url" 2>/dev/null || echo "000")

    prev_status="up"
    [ -f "$state_file" ] && prev_status=$(cat "$state_file")

    # Acceptera flera koder separerade med komma (ex: "200,401,403")
    is_ok="no"
    IFS=',' read -ra accepted <<< "$expected_codes"
    for code in "${accepted[@]}"; do
        [ "$http_code" = "$code" ] && is_ok="yes" && break
    done

    if [ "$is_ok" = "yes" ]; then
        log "OK   $name ($url) → HTTP $http_code"
        if [ "$prev_status" = "down" ]; then
            send_telegram "✅ <b>${name}</b> är tillbaka!\n${url}\nHTTP ${http_code}"
            log "RECOVERY $name ($url)"
        fi
        echo "up" > "$state_file"
    else
        log "FAIL $name ($url) → HTTP ${http_code} (förväntat ${expected_codes})"
        if [ "$prev_status" != "down" ]; then
            send_telegram "🚨 <b>${name}</b> är NER!\n${url}\nHTTP ${http_code} (förväntat ${expected_codes})\nTid: $(date '+%H:%M %Z')"
        fi
        echo "down" > "$state_file"
    fi

done < "$SITES_CONF"

log "Checkkörning klar"
