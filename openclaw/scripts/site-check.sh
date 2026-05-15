#!/usr/bin/env bash
# HTTP health check for all sites in openclaw/config/sites.txt
# State file tracks last status per URL. Alerts only on transitions.
# Intended to run from cron every 5 minutes.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SITES_FILE="${SITES_FILE:-$REPO_DIR/openclaw/config/sites.txt}"
STATE_DIR="${STATE_DIR:-$HOME/.openclaw-monitor/state}"
LOG_FILE="${LOG_FILE:-$HOME/.openclaw-monitor/monitor.log}"
NOTIFY="$SCRIPT_DIR/lib/notify-telegram.sh"

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE"; }

if [ ! -r "$SITES_FILE" ]; then
  log "site-check: missing sites file: $SITES_FILE"
  exit 1
fi

# slugify URL for filename
slug() { printf '%s' "$1" | sed -e 's|https\?://||' -e 's|[^A-Za-z0-9.-]|_|g'; }

check_one() {
  local url="$1"
  local slug; slug="$(slug "$url")"
  local state_file="$STATE_DIR/http-$slug.state"
  local prev="unknown"
  [ -r "$state_file" ] && prev="$(cat "$state_file")"

  # -L follow redirects; -k NOT used (we want SSL failures to surface)
  local code
  code="$(curl -L -o /dev/null -s -w '%{http_code}' --max-time 20 --retry 1 --retry-delay 2 "$url" 2>/dev/null || echo '000')"

  # Treat any response from the server (1xx-4xx) as "up" — only 5xx or
  # connection failure (000) counts as down. 401/403 means the site is
  # alive but auth-protected, which is normal for staging/internal hosts.
  local now
  if [ "$code" -ge 100 ] && [ "$code" -lt 500 ]; then
    now="up:$code"
  else
    now="down:$code"
  fi

  printf '%s' "$now" > "$state_file"

  if [ "$prev" != "$now" ]; then
    log "transition $url $prev -> $now"
    case "$now" in
      up:*)
        if [ "$prev" != "unknown" ]; then
          "$NOTIFY" "✅ <b>RECOVERED</b>: $url is back (HTTP $code)" \
            || log "notify failed for $url"
        fi
        ;;
      down:*)
        "$NOTIFY" "🚨 <b>DOWN</b>: $url returned HTTP $code" \
          || log "notify failed for $url"
        ;;
    esac
  fi
}

while IFS= read -r line; do
  # strip leading/trailing whitespace
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -z "$line" ] && continue
  case "$line" in \#*) continue;; esac
  check_one "$line"
done < "$SITES_FILE"
