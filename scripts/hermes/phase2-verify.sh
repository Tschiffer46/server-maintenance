#!/usr/bin/env bash
#
# phase2-verify.sh
#
# Verify the OpenClaw -> Hermes cutover.
#   sudo bash scripts/hermes/phase2-verify.sh

set -uo pipefail

HERMES_USER="hermes"
OPENCLAW_PORT=18789
OPENCLAW_UNITS=(openclaw-gateway openclaw)

pass=0; fail=0
ok()  { printf '  [ok]   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); }

echo "== hermes service =="
state=$(systemctl is-active hermes 2>/dev/null || true)
if [ "$state" = "active" ]; then ok "hermes is active"; else bad "hermes is $state"; fi
if systemctl is-enabled --quiet hermes; then ok "hermes is enabled at boot"; else bad "hermes is not enabled at boot"; fi

if pgrep -fa 'hermes' >/dev/null 2>&1; then ok "hermes process running"; else bad "no hermes process"; fi

echo
echo "== openclaw stopped =="
for u in "${OPENCLAW_UNITS[@]}"; do
  if systemctl is-active --quiet "$u"; then
    bad "$u is still active"
  fi
done
if pgrep -fa 'openclaw' >/dev/null 2>&1; then
  bad "openclaw process is still running:"
  pgrep -fa 'openclaw' | sed 's/^/    /'
else
  ok "no openclaw process running"
fi
if ss -ltn 2>/dev/null | grep -q ":${OPENCLAW_PORT}\b"; then
  bad "port $OPENCLAW_PORT still in use"
else
  ok "port $OPENCLAW_PORT free"
fi

echo
echo "== migration imported state =="
for entry in \
  /home/hermes/.hermes/skills/openclaw-imports \
  /home/hermes/.hermes/SOUL.md \
  /home/hermes/.hermes/MEMORY.md \
  /home/hermes/.hermes/USER.md; do
  if sudo -u "$HERMES_USER" test -e "$entry"; then
    ok "present: $entry"
  else
    echo "  [info] not present: $entry (not all are required - depends on what OpenClaw had)"
  fi
done

echo
echo "== recent hermes logs (last 20 lines) =="
journalctl -u hermes -n 20 --no-pager 2>/dev/null || true

echo
echo "== summary =="
echo "  pass: $pass"
echo "  fail: $fail"
echo
echo "manual check: send a message to your Telegram bot - you should get a reply"
echo "              from Hermes (it may introduce itself differently than OpenClaw did)."
[ "$fail" -eq 0 ]
