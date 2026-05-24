#!/usr/bin/env bash
# Samlar information om tillgängliga uppdateringar på alla tre servrarna.
# Körs en gång per dygn (07:50) av hermes-update-check.timer, precis innan
# den dagliga rapporten kl 08:00 som plockar upp resultatet.
#
# Skriver state till /var/lib/hermes/monitoring/state/updates.<host>.txt
# och /var/lib/hermes/monitoring/state/updates.summary.

set -euo pipefail

CONF_FILE="/etc/hermes-monitoring/infra.conf"
ENV_FILE="/home/hermes/.config/hermes-monitoring/env"
LOG_FILE="/var/log/hermes/monitoring.log"
STATE_DIR="/var/lib/hermes/monitoring/state"

# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && source "$ENV_FILE"
# shellcheck source=/dev/null
[ -f "$CONF_FILE" ] && source "$CONF_FILE"

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] update-check: $*" >> "$LOG_FILE"; }

# Returnerar tre rader:
#   SEC:<antal säkerhetspaket tillgängliga>
#   UPD:<antal övriga paket tillgängliga>
#   REBOOT:<yes|no>
gather_apt_status() {
    # Använder existerande apt-cache (apt-daily.timer uppdaterar nattetid).
    # Kräver inte root.
    local total sec upd reboot
    # apt list --upgradable: en rad per paket, formatet "<pkg>/<repo> ..."
    # Säkerhetspaket har "security" i repo-namnet (Debian: bookworm-security)
    total=$(apt list --upgradable 2>/dev/null | grep -c '^[^/]*/' || true)
    sec=$(apt list --upgradable 2>/dev/null | grep -c 'security' || true)
    upd=$(( total - sec ))
    [ "$upd" -lt 0 ] && upd=0

    reboot="no"
    [ -f /var/run/reboot-required ] && reboot="yes"

    printf "SEC:%s\nUPD:%s\nREBOOT:%s\n" "$sec" "$upd" "$reboot"
}

# Lokal: ATM-shops
log "Kör lokal apt-check"
local_state="$STATE_DIR/updates.atm-shops.txt"
gather_apt_status > "$local_state" 2>>"$LOG_FILE" || log "WARN lokal apt-check misslyckades"

# Remote: kör samma funktion via SSH (vi skickar den som ett inline-script)
remote_apt_check() {
    local label="$1" host="$2" user="$3" key="$4" use_sudo="$5"
    local out_file="$STATE_DIR/updates.${label}.txt"
    local sudo_prefix=""
    [ "$use_sudo" = "yes" ] && sudo_prefix="sudo "

    # Inline-script: ingen apt-get update (kräver root). Använd cache.
    local script
    script=$(cat <<'REMOTE'
total=$(apt list --upgradable 2>/dev/null | grep -c '^[^/]*/' || true)
sec=$(apt list --upgradable 2>/dev/null | grep -c 'security' || true)
upd=$(( total - sec ))
[ "$upd" -lt 0 ] && upd=0
reboot="no"
[ -f /var/run/reboot-required ] && reboot="yes"
printf "SEC:%s\nUPD:%s\nREBOOT:%s\n" "$sec" "$upd" "$reboot"
REMOTE
)

    if ssh -i "$key" \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=15 \
        -o BatchMode=yes \
        "${user}@${host}" "${sudo_prefix}bash -s" <<< "$script" \
        > "$out_file" 2>/dev/null; then
        log "OK   remote apt-check $label"
    else
        log "FAIL remote apt-check $label (SSH eller apt fel)"
        echo "SEC:?" > "$out_file"
        echo "UPD:?" >> "$out_file"
        echo "REBOOT:?" >> "$out_file"
    fi
}

if [ -n "${MAILCOW_HOST:-}" ] && [ -f "${MAILCOW_SSH_KEY:-}" ]; then
    remote_apt_check "mailcow" "$MAILCOW_HOST" "$MAILCOW_SSH_USER" "$MAILCOW_SSH_KEY" "no"
fi

if [ -n "${WEBHOSTING_HOST:-}" ] && [ -f "${WEBHOSTING_SSH_KEY:-}" ]; then
    # deploy har inte root, så vi kan inte läsa /var/run/reboot-required om
    # filen är root-only. Den är världsläsbar på Debian per default.
    remote_apt_check "web-hosting" "$WEBHOSTING_HOST" "$WEBHOSTING_SSH_USER" "$WEBHOSTING_SSH_KEY" "no"
fi

# --- Mailcow-version vs senaste GitHub release ---
mailcow_state="$STATE_DIR/updates.mailcow-app.txt"
if [ -n "${MAILCOW_HOST:-}" ] && [ -f "${MAILCOW_SSH_KEY:-}" ]; then
    # Installerad version: senaste tag eller commit i /opt/mailcow-dockerized
    installed=$(ssh -i "$MAILCOW_SSH_KEY" \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=15 \
        -o BatchMode=yes \
        "${MAILCOW_SSH_USER}@${MAILCOW_HOST}" \
        'cd /opt/mailcow-dockerized 2>/dev/null && (git describe --tags 2>/dev/null || git rev-parse --short HEAD 2>/dev/null) || echo "unknown"' \
        2>/dev/null || echo "unknown")
    installed="${installed:-unknown}"

    # JSON är ofta minifierad – parsa "tag_name" robust med sed
    latest=$(curl -sf --max-time 15 \
        https://api.github.com/repos/mailcow/mailcow-dockerized/releases/latest \
        2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -1 || true)
    latest="${latest:-unknown}"

    {
        echo "INSTALLED:${installed}"
        echo "LATEST:${latest}"
    } > "$mailcow_state"
    log "Mailcow-version: installerad=${installed} senaste=${latest}"
else
    echo "INSTALLED:n/a"  > "$mailcow_state"
    echo "LATEST:n/a"     >> "$mailcow_state"
fi

log "update-check klar"
