#!/usr/bin/env bash
# Kontrollerar Mailcow-hälsa på mailcow-server (204.168.157.75).
# Två typer av checkar:
#   1. Externa portcheckar från ATM-shops (nc): SMTP 25, SMTPS 465, Submission 587, IMAPS 993
#   2. SSH-check: disk, RAM, docker-containers
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
MAILCOW_HOST="${MAILCOW_HOST:-204.168.157.75}"
MAILCOW_SSH_USER="${MAILCOW_SSH_USER:-deploy}"
MAILCOW_SSH_KEY="${MAILCOW_SSH_KEY:-/home/hermes/.ssh/id_ed25519_mailcow}"
MAILCOW_PORTS="${MAILCOW_PORTS:-25 465 587 993}"
DISK_WARN_PERCENT="${DISK_WARN_PERCENT:-80}"
DISK_CRIT_PERCENT="${DISK_CRIT_PERCENT:-90}"
MEM_WARN_PERCENT="${MEM_WARN_PERCENT:-85}"
MEM_CRIT_PERCENT="${MEM_CRIT_PERCENT:-95}"

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

# --- 1. Externa portcheckar (SMTP, SMTPS, Submission, IMAPS) ---
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
            "🚨 <b>Mailcow ${svc} (port ${port}) svarar inte!</b>\nHost: ${MAILCOW_HOST}\nTid: $(date '+%H:%M %Z')" \
            "✅ <b>Mailcow ${svc} (port ${port}) är tillbaka</b>"
    fi
done

# --- 2. SSH-check: disk, RAM, docker ---
if [ ! -f "$MAILCOW_SSH_KEY" ]; then
    log "WARN: SSH-nyckel $MAILCOW_SSH_KEY saknas – hoppar över SSH-check"
else
    remote_output=$(ssh \
        -i "$MAILCOW_SSH_KEY" \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=15 \
        -o BatchMode=yes \
        "${MAILCOW_SSH_USER}@${MAILCOW_HOST}" \
        'printf "DISK:%s\n" $(df -P / | awk "NR==2{gsub(/%/,\"\",$5);print $5}"); printf "MEM:%s\n" $(free | awk "/^Mem:/{printf \"%.0f\", $3/$2*100}"); DOCKER_DOWN=$(docker ps --filter status=exited --filter status=dead --format "{{.Names}}" 2>/dev/null | tr "\n" "," | sed "s/,$/"/); printf "DOCKER_DOWN:%s\n" "${DOCKER_DOWN:-none}"' \
        2>/dev/null) || {
            log "FAIL SSH till mailcow-server $MAILCOW_HOST misslyckades"
            alert_if_changed "ssh" "down" \
                "🚨 <b>mailcow-server kan inte nås via SSH!</b>\n${MAILCOW_HOST}\nTid: $(date '+%H:%M %Z')" \
                "✅ <b>mailcow-server åtkomlig via SSH igen</b>"
            exit 0
        }

    log "OK   SSH till mailcow-server $MAILCOW_HOST lyckades"
    alert_if_changed "ssh" "up" "" ""

    disk_pct=$(echo "$remote_output" | grep '^DISK:' | cut -d: -f2)
    mem_pct=$(echo "$remote_output"  | grep '^MEM:'  | cut -d: -f2)
    docker_down=$(echo "$remote_output" | grep '^DOCKER_DOWN:' | cut -d: -f2-)

    log "INFO mailcow disk=${disk_pct}% ram=${mem_pct}% docker_down=${docker_down}"

    # Disk
    if [ -n "$disk_pct" ]; then
        if [ "$disk_pct" -ge "$DISK_CRIT_PERCENT" ] 2>/dev/null; then
            alert_if_changed "disk" "down" \
                "🔴 <b>mailcow-server: Disk kritisk!</b>\n/ används till <b>${disk_pct}%</b>" \
                "✅ <b>mailcow-server: Disk normaliserad</b>: ${disk_pct}%"
        elif [ "$disk_pct" -ge "$DISK_WARN_PERCENT" ] 2>/dev/null; then
            alert_if_changed "disk" "down" \
                "⚠️ <b>mailcow-server: Disk-varning</b>\n/ används till <b>${disk_pct}%</b>" \
                "✅ <b>mailcow-server: Disk normaliserad</b>: ${disk_pct}%"
        else
            alert_if_changed "disk" "up" "" ""
        fi
    fi

    # RAM
    if [ -n "$mem_pct" ]; then
        if [ "$mem_pct" -ge "$MEM_CRIT_PERCENT" ] 2>/dev/null; then
            alert_if_changed "mem" "down" \
                "🔴 <b>mailcow-server: RAM kritiskt!</b>\nRAM-användning: <b>${mem_pct}%</b>" \
                "✅ <b>mailcow-server: RAM normaliserat</b>: ${mem_pct}%"
        elif [ "$mem_pct" -ge "$MEM_WARN_PERCENT" ] 2>/dev/null; then
            alert_if_changed "mem" "down" \
                "⚠️ <b>mailcow-server: RAM-varning</b>\nRAM-användning: <b>${mem_pct}%</b>" \
                "✅ <b>mailcow-server: RAM normaliserat</b>: ${mem_pct}%"
        else
            alert_if_changed "mem" "up" "" ""
        fi
    fi

    # Docker-containers
    if [ -n "$docker_down" ] && [ "$docker_down" != "none" ]; then
        log "WARN Docker-containers nere: $docker_down"
        alert_if_changed "docker" "down" \
            "⚠️ <b>mailcow-server: Docker-containers nere!</b>\n${docker_down}\nTid: $(date '+%H:%M %Z')" \
            "✅ <b>mailcow-server: Docker-containers återställda</b>"
    else
        alert_if_changed "docker" "up" "" ""
    fi
fi

log "Mailcow-check klar"
