#!/usr/bin/env bash
# Körs dagligen kl 08:00 av hermes-daily-report.timer.
# Bygger en kompakt, actionable rapport: rubrik, eventuella problem, eventuella TODOs.
# Inga 60-dagars-listor, inga "X körs som vanligt"-rader om allt är OK.

set -euo pipefail

SITES_CONF="/etc/hermes-monitoring/sites.conf"
ENV_FILE="/home/hermes/.config/hermes-monitoring/env"
STATE_DIR="/var/lib/hermes/monitoring/state"
LOG_FILE="/var/log/hermes/monitoring.log"
SSL_WARN_DAYS=30   # visa enbart cert under denna gräns

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

read_kv() { grep "^$2:" "$1" 2>/dev/null | head -1 | cut -d: -f2- ; }

mkdir -p "$(dirname "$LOG_FILE")"
[ ! -f "$SITES_CONF" ] && { log "FEL: $SITES_CONF saknas"; exit 1; }

# === Sajter ===
total=0
up_count=0
down_list=""
ssl_warn=""        # detaljer för cert < SSL_WARN_DAYS
ssl_min_days=9999  # minst antal dagar bland alla cert (för en kort summering)

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
        down_list="${down_list}\n  • ${name} (${url})"
    fi

    if [[ "$url" == https://* ]]; then
        days=$(check_ssl_days "$host")
        if [ "$days" -ge 0 ] 2>/dev/null; then
            [ "$days" -lt "$ssl_min_days" ] 2>/dev/null && ssl_min_days="$days"
            if [ "$days" -lt "$SSL_WARN_DAYS" ] 2>/dev/null; then
                ssl_warn="${ssl_warn}\n  • ${name}: <b>${days} dagar kvar</b>"
            fi
        fi
    fi
done < "$SITES_CONF"

# === Bygg meddelandet ===
msg="📊 <b>Daglig statusrapport</b> – $(date '+%Y-%m-%d')"

# --- Sajter ---
if [ "$up_count" -eq "$total" ]; then
    msg="${msg}\n\n✅ Alla ${total} sajter svarar som väntat"
else
    down_count=$(( total - up_count ))
    msg="${msg}\n\n🚨 <b>${down_count} av ${total} sajter svarar inte:</b>${down_list}"
    msg="${msg}\n\n  ↳ Om en sajt är nere och du vet att det inte är ett problem (t.ex. login krävs),"
    msg="${msg}\n     uppdatera <code>config/sites.conf</code> och lägg till statuskoden – ex: <code>...|Namn|200,401</code>"
fi

# --- SSL ---
if [ -n "$ssl_warn" ]; then
    msg="${msg}\n\n🔒 <b>SSL att förnya inom ${SSL_WARN_DAYS} dagar:</b>${ssl_warn}"
elif [ "$ssl_min_days" -lt 9999 ] 2>/dev/null; then
    msg="${msg}\n\n🔒 SSL OK – närmaste utgång om ${ssl_min_days} dagar"
fi

# === Uppdateringar ===
# För varje host: installerade i natt, väntar, reboot
host_section() {
    local label="$1" key="$2" log_host_cmd="$3"
    local f="$STATE_DIR/updates.${key}.txt"
    [ ! -f "$f" ] && return
    local sec upd reboot installed_last_night
    sec=$(read_kv "$f" SEC)
    upd=$(read_kv "$f" UPD)
    reboot=$(read_kv "$f" REBOOT)

    # Försök hitta installerade paket från senaste unattended-upgrade
    if [ "$key" = "atm-shops" ]; then
        installed_last_night=$(grep -h "$(date '+%Y-%m-%d')\|$(date -d 'yesterday' '+%Y-%m-%d')" \
            /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null \
            | grep -c 'Packages that will be upgraded:' || true)
    fi

    local out="  • <b>${label}</b>: "
    if [ "$sec" = "?" ]; then
        out="${out}status okänd"
    elif [ "$sec" = "0" ] && [ "$upd" = "0" ] && [ "$reboot" = "no" ]; then
        out="${out}aktuell ✅"
    else
        local parts=""
        [ "$sec" != "0" ] && parts="${parts}${sec} säkerhetspaket väntar, "
        [ "$upd" != "0" ] && parts="${parts}${upd} övriga paket väntar, "
        [ "$reboot" = "yes" ] && parts="${parts}<b>omstart krävs</b>, "
        out="${out}${parts%, }"
    fi
    echo "$out"
}

updates_section=""
todos=""

line=$(host_section "ATM-shops" "atm-shops" "")
[ -n "$line" ] && updates_section="${updates_section}\n${line}"

line=$(host_section "mailcow-server" "mailcow" "ssh root@204.168.157.75")
[ -n "$line" ] && updates_section="${updates_section}\n${line}"

line=$(host_section "web-hosting-prod" "web-hosting" "ssh deploy@89.167.90.112")
[ -n "$line" ] && updates_section="${updates_section}\n${line}"

[ -n "$updates_section" ] && msg="${msg}\n\n🔧 <b>OS-paket:</b>${updates_section}"

# Generera TODO-lista per host om något kräver handling
add_todo_if_pending() {
    local label="$1" key="$2" ssh_cmd="$3"
    local f="$STATE_DIR/updates.${key}.txt"
    [ ! -f "$f" ] && return
    local sec upd reboot
    sec=$(read_kv "$f" SEC); upd=$(read_kv "$f" UPD); reboot=$(read_kv "$f" REBOOT)

    if [ "$reboot" = "yes" ]; then
        todos="${todos}\n  • <b>${label}</b>: omstart krävs. Kör:\n      <code>${ssh_cmd}</code>\n      <code>sudo reboot</code>"
    fi
    # Övriga paket (ej security) – security tas av unattended-upgrades automatiskt
    if [ "$upd" != "0" ] && [ "$upd" != "?" ] && [ -n "$upd" ]; then
        todos="${todos}\n  • <b>${label}</b>: ${upd} icke-säkerhetspaket att uppgradera (valfritt). Kör:\n      <code>${ssh_cmd}</code>\n      <code>sudo apt upgrade</code>"
    fi
}
add_todo_if_pending "ATM-shops"       "atm-shops"   "ssh deploy@77.42.81.134"
add_todo_if_pending "mailcow-server"  "mailcow"     "ssh root@204.168.157.75"
add_todo_if_pending "web-hosting-prod" "web-hosting" "ssh deploy@89.167.90.112"

# Mailcow-app
mailcow_app_file="$STATE_DIR/updates.mailcow-app.txt"
if [ -f "$mailcow_app_file" ]; then
    installed=$(read_kv "$mailcow_app_file" INSTALLED)
    latest=$(read_kv "$mailcow_app_file" LATEST)
    if [ -n "$installed" ] && [ -n "$latest" ] && \
       [ "$installed" != "unknown" ] && [ "$latest" != "unknown" ] && \
       [ "$installed" != "n/a" ] && [ "$installed" != "$latest" ]; then
        todos="${todos}\n  • <b>Mailcow-app</b>: <code>${installed}</code> → <code>${latest}</code>. Läs release-notes först:\n      https://github.com/mailcow/mailcow-dockerized/releases/tag/${latest}\n      Uppgradera (paus ~5 min):\n      <code>ssh root@204.168.157.75</code>\n      <code>cd /opt/mailcow-dockerized &amp;&amp; ./update.sh</code>"
    fi
fi

if [ -n "$todos" ]; then
    msg="${msg}\n\n📋 <b>Att göra:</b>${todos}"
fi

send_telegram "$msg"
log "Daglig rapport skickad: ${up_count}/${total} uppe"
