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

# --- Uppdateringssektion ---
read_kv() { grep "^$2:" "$1" 2>/dev/null | head -1 | cut -d: -f2- ; }

format_host_updates() {
    local label="$1" file="$2"
    [ ! -f "$file" ] && return
    local sec upd reboot
    sec=$(read_kv "$file" SEC)
    upd=$(read_kv "$file" UPD)
    reboot=$(read_kv "$file" REBOOT)
    [ -z "$sec$upd$reboot" ] && return

    local line="  • <b>${label}</b>: "
    local parts=""
    if [ "$sec" = "0" ] && [ "$upd" = "0" ] && [ "$reboot" = "no" ]; then
        parts="aktuell ✅"
    else
        [ "$sec" != "0" ] && [ "$sec" != "?" ] && parts="${parts}${sec} säkerhetspaket, "
        [ "$upd" != "0" ] && [ "$upd" != "?" ] && parts="${parts}${upd} övriga paket, "
        [ "$reboot" = "yes" ] && parts="${parts}<b>omstart krävs</b>, "
        [ "$sec" = "?" ] && parts="${parts}status okänd, "
        parts="${parts%, }"
    fi
    echo "${line}${parts}"
}

updates_section=""
for host_label in "atm-shops:ATM-shops" "mailcow:mailcow-server" "web-hosting:web-hosting-prod"; do
    label_key="${host_label%%:*}"
    label_display="${host_label##*:}"
    line=$(format_host_updates "$label_display" "$STATE_DIR/updates.${label_key}.txt")
    [ -n "$line" ] && updates_section="${updates_section}\n${line}"
done

# Mailcow-app jämförelse
mailcow_app_file="$STATE_DIR/updates.mailcow-app.txt"
mailcow_section=""
if [ -f "$mailcow_app_file" ]; then
    installed=$(read_kv "$mailcow_app_file" INSTALLED)
    latest=$(read_kv "$mailcow_app_file" LATEST)
    if [ -n "$installed" ] && [ -n "$latest" ] && \
       [ "$installed" != "unknown" ] && [ "$latest" != "unknown" ] && \
       [ "$installed" != "n/a" ]; then
        if [ "$installed" != "$latest" ]; then
            mailcow_section="\n\n📦 <b>Mailcow-app uppdatering tillgänglig</b>"
            mailcow_section="${mailcow_section}\n  Installerad: <code>${installed}</code>"
            mailcow_section="${mailcow_section}\n  Senaste:     <code>${latest}</code>"
            mailcow_section="${mailcow_section}\n  Så här uppdaterar du (kräver paus i mailtrafiken ~5 min):"
            mailcow_section="${mailcow_section}\n  <code>ssh root@204.168.157.75</code>"
            mailcow_section="${mailcow_section}\n  <code>cd /opt/mailcow-dockerized &amp;&amp; ./update.sh</code>"
            mailcow_section="${mailcow_section}\n  Läs release-notes först: https://github.com/mailcow/mailcow-dockerized/releases/latest"
        fi
    fi
fi

if [ -n "$updates_section" ]; then
    msg="${msg}\n\n🔧 <b>Uppdateringar:</b>${updates_section}"
fi
[ -n "$mailcow_section" ] && msg="${msg}${mailcow_section}"

msg="${msg}\n\nNästa rapport: imorgon 08:00"

send_telegram "$msg"
log "Daglig rapport skickad: ${up_count}/${total} uppe"
