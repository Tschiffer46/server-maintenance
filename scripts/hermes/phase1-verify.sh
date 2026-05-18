#!/usr/bin/env bash
#
# phase1-verify.sh
#
# Verify phase 1 left the host in a good state: Hermes installed but
# inactive, OpenClaw still running, no port conflicts.
#
# Run with sudo - we need to read /home/hermes/ which is mode 0700.
#   sudo bash scripts/hermes/phase1-verify.sh

set -uo pipefail

HERMES_USER="hermes"
HERMES_HOME="/home/${HERMES_USER}"
HERMES_BIN="${HERMES_HOME}/.local/bin/hermes"
OPENCLAW_UNITS=(openclaw-gateway openclaw)
OPENCLAW_PORT=18789

pass=0; fail=0
ok()  { printf '  [ok]   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); }

# Use sudo if available so we can see into /home/hermes/. If already root,
# call the helper directly.
run_as_hermes() {
  if [ "$EUID" -eq 0 ]; then
    sudo -u "$HERMES_USER" -H -- "$@"
  else
    sudo -n -u "$HERMES_USER" -H -- "$@" 2>/dev/null
  fi
}
check_path_as_hermes() {
  local flag="$1" path="$2"
  if [ "$EUID" -eq 0 ]; then
    sudo -u "$HERMES_USER" test "$flag" "$path"
  else
    sudo -n -u "$HERMES_USER" test "$flag" "$path" 2>/dev/null
  fi
}

if [ "$EUID" -ne 0 ]; then
  echo "NOTE: not running as root - file checks for /home/hermes use 'sudo -n'."
  echo "      if any check below incorrectly says 'missing', re-run with sudo."
  echo
fi

echo "== hermes user / install =="
id "$HERMES_USER" >/dev/null 2>&1 && ok "user $HERMES_USER exists" || bad "user $HERMES_USER missing"
check_path_as_hermes -d "${HERMES_HOME}/.hermes" && ok "${HERMES_HOME}/.hermes/ exists" || bad "${HERMES_HOME}/.hermes/ missing"
check_path_as_hermes -x "$HERMES_BIN" && ok "hermes binary present" || bad "hermes binary missing at $HERMES_BIN"
ver=$(run_as_hermes "$HERMES_BIN" --version 2>/dev/null | head -1 || true)
[ -n "$ver" ] && ok "hermes reports: $ver" || bad "hermes --version returned nothing"

echo
echo "== systemd unit =="
if systemctl cat hermes >/dev/null 2>&1; then
  ok "hermes.service installed"
  state=$(systemctl is-active hermes || true)
  if [ "$state" = "inactive" ] || [ "$state" = "failed" ] || [ "$state" = "unknown" ]; then
    ok "hermes is not running yet (state=$state) - expected at end of phase 1"
  else
    bad "hermes is $state - phase 1 should leave it stopped"
  fi
else
  bad "hermes.service not found - did you install the unit?"
fi

echo
echo "== openclaw still healthy =="
# systemctl may not know openclaw-gateway as a managed unit (some installs
# start it directly). Treat 'port + process' as authoritative; service
# status is just informational.
active_unit=""
for u in "${OPENCLAW_UNITS[@]}"; do
  if systemctl is-active --quiet "$u"; then active_unit="$u"; break; fi
done
if [ -n "$active_unit" ]; then
  ok "openclaw service active: $active_unit"
else
  echo "  [info] systemctl does not show ${OPENCLAW_UNITS[*]} as active (informational only)"
fi
if ss -ltn 2>/dev/null | grep -q ":${OPENCLAW_PORT}\b"; then
  ok "openclaw listening on port $OPENCLAW_PORT"
else
  bad "nothing listening on $OPENCLAW_PORT - openclaw may be down"
fi
if pgrep -fa 'openclaw' >/dev/null 2>&1; then
  ok "openclaw process running"
else
  bad "no openclaw process found"
fi

echo
echo "== hermes doctor =="
run_as_hermes "$HERMES_BIN" doctor || bad "hermes doctor returned non-zero"

echo
echo "== summary =="
echo "  pass: $pass"
echo "  fail: $fail"
[ "$fail" -eq 0 ]
