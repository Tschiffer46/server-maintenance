#!/usr/bin/env bash
# Install the 08:00 morning digest cron job and seed the events database.
# Idempotent: re-running just refreshes the cron block.

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as the deploy user (no sudo)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$HOME/.openclaw-monitor/.env"

if [ ! -r "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE. Run 03-install-monitoring.sh first." >&2
  exit 1
fi

mkdir -p "$HOME/.openclaw-monitor"
chmod +x "$SCRIPT_DIR/morning-digest.py" "$SCRIPT_DIR/lib/log-event.py"

# Initialise schema (creates the file too)
python3 "$SCRIPT_DIR/lib/log-event.py" startup info digest "events DB initialised" \
  && echo "✓ events DB ready: $HOME/.openclaw-monitor/events.db"

# Add cron line (08:00 local server time, every day)
BEGIN_MARK="# >>> openclaw-monitor >>>"
END_MARK="# <<< openclaw-monitor <<<"

EXISTING="$(crontab -l 2>/dev/null || true)"
INSIDE="$(printf '%s\n' "$EXISTING" | awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  $0==b {inside=1; next} $0==e {inside=0; next} inside')"
OUTSIDE="$(printf '%s\n' "$EXISTING" | awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  $0==b {skip=1; next} $0==e {skip=0; next} !skip')"

KEPT="$(printf '%s\n' "$INSIDE" | grep -v 'morning-digest.py' || true)"
[ -z "$KEPT" ] && KEPT="# Managed by openclaw/scripts/*-install-*.sh — do not edit by hand."

NEW_BLOCK="$BEGIN_MARK
$KEPT
0 8 * * * /usr/bin/python3 $SCRIPT_DIR/morning-digest.py >/dev/null 2>&1
$END_MARK"

{
  printf '%s\n' "$OUTSIDE"
  printf '%s\n' "$NEW_BLOCK"
} | sed '/^$/N;/^\n$/D' | crontab -

echo "✓ crontab now contains:"
crontab -l | sed -n "/$BEGIN_MARK/,/$END_MARK/p"

# Optional: send a test digest right now (using whatever's already in the DB).
echo
read -r -p "Send a test digest to Telegram right now? [y/N] " yn
case "$yn" in
  [yY]*) python3 "$SCRIPT_DIR/morning-digest.py" && echo "✓ test digest sent" ;;
  *) echo "(skipping test digest — first real one runs at 08:00 server time)" ;;
esac

echo
echo "Server time:    $(date '+%Y-%m-%d %H:%M %Z')  (digest fires at 08:00 in this timezone)"
echo "Events DB:      $HOME/.openclaw-monitor/events.db"
echo "Inspect:        sqlite3 $HOME/.openclaw-monitor/events.db 'SELECT ts, kind, severity, source FROM events ORDER BY id DESC LIMIT 20;'"
echo "Run manually:   python3 $SCRIPT_DIR/morning-digest.py"
