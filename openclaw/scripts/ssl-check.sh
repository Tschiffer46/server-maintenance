#!/usr/bin/env bash
# SSL certificate expiry check for all sites in openclaw/config/sites.txt
# Alerts when cert expires in <14 days. State file rate-limits to one alert/day per host.
# Intended to run from cron every 6 hours.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SITES_FILE="${SITES_FILE:-$REPO_DIR/openclaw/config/sites.txt}"
STATE_DIR="${STATE_DIR:-$HOME/.openclaw-monitor/state}"
LOG_FILE="${LOG_FILE:-$HOME/.openclaw-monitor/monitor.log}"
NOTIFY="$SCRIPT_DIR/lib/notify-telegram.sh"
WARN_DAYS="${WARN_DAYS:-14}"

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE"; }

if [ ! -r "$SITES_FILE" ]; then
  log "ssl-check: missing sites file: $SITES_FILE"
  exit 1
fi

check_one() {
  local url="$1"
  local host="${url#https://}"
  host="${host#http://}"
  host="${host%%/*}"
  local state_file="$STATE_DIR/ssl-$host.lastalert"

  # Fetch cert and parse expiry
  local end_date
  end_date="$(echo | timeout 15 openssl s_client -servername "$host" -connect "$host:443" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')"

  if [ -z "$end_date" ]; then
    log "ssl-check $host: could not read certificate"
    return
  fi

  local end_epoch now_epoch days_left
  end_epoch="$(date -d "$end_date" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date -u +%s)"
  if [ "$end_epoch" -eq 0 ]; then
    log "ssl-check $host: could not parse end date '$end_date'"
    return
  fi
  days_left=$(( (end_epoch - now_epoch) / 86400 ))

  log "ssl-check $host: $days_left days left"

  if [ "$days_left" -lt "$WARN_DAYS" ]; then
    # rate-limit: only alert once per day
    local today; today="$(date -u +%Y-%m-%d)"
    local last=""
    [ -r "$state_file" ] && last="$(cat "$state_file")"
    if [ "$last" != "$today" ]; then
      "$NOTIFY" "⚠️ <b>SSL EXPIRING</b>: $host in $days_left days ($end_date)" \
        && printf '%s' "$today" > "$state_file"
    fi
  fi
}

while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -z "$line" ] && continue
  case "$line" in \#*) continue;; esac
  case "$line" in https://*) check_one "$line";; esac
done < "$SITES_FILE"
