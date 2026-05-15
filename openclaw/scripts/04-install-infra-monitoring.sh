#!/usr/bin/env bash
# Add infrastructure (disk/RAM/Docker/services) checks to the cron block.
# Assumes 03-install-monitoring.sh has been run (which created the .env file
# and the openclaw-monitor crontab block).

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

chmod +x "$SCRIPT_DIR/infra-check.sh"

# Run once to seed state (and surface any current issues)
echo "▶ Running infra-check once to seed state..."
"$SCRIPT_DIR/infra-check.sh"
echo "✓ initial run complete"

# Update crontab block — keep prior site/ssl lines, add infra line
BEGIN_MARK="# >>> openclaw-monitor >>>"
END_MARK="# <<< openclaw-monitor <<<"

EXISTING="$(crontab -l 2>/dev/null || true)"

# Pull out existing managed block (if any) so we can rebuild it
INSIDE="$(printf '%s\n' "$EXISTING" | awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  $0==b {inside=1; next}
  $0==e {inside=0; next}
  inside
')"

OUTSIDE="$(printf '%s\n' "$EXISTING" | awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  $0==b {skip=1; next}
  $0==e {skip=0; next}
  !skip
')"

# Strip any prior infra-check.sh lines, keep everything else
KEPT="$(printf '%s\n' "$INSIDE" | grep -v 'infra-check.sh' || true)"

# If the existing block is empty (e.g. user skipped 03), seed with header
if [ -z "$KEPT" ]; then
  KEPT="# Managed by openclaw/scripts/*-install-*.sh — do not edit by hand."
fi

NEW_BLOCK="$BEGIN_MARK
$KEPT
*/15 * * * * $SCRIPT_DIR/infra-check.sh >/dev/null 2>&1
$END_MARK"

{
  printf '%s\n' "$OUTSIDE"
  printf '%s\n' "$NEW_BLOCK"
} | sed '/^$/N;/^\n$/D' | crontab -

echo "✓ crontab updated:"
crontab -l | sed -n "/$BEGIN_MARK/,/$END_MARK/p"

echo
echo "Edit thresholds:  $(cd "$(dirname "$SCRIPT_DIR")" && pwd)/config/infra.conf"
echo "Test alert:       echo 'EXPECTED_CONTAINERS=\"does-not-exist\"' >> openclaw/config/infra.conf && bash openclaw/scripts/infra-check.sh"
echo "Logs:             tail -f ~/.openclaw-monitor/monitor.log"
