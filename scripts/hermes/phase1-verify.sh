#!/usr/bin/env bash
#
# phase1-verify.sh
#
# Verify phase 1 left the host in a good state: Hermes installed but
# inactive, OpenClaw still running, no port conflicts.

set -uo pipefail

HERMES_USER="hermes"
HERMES_HOME="/home/${HERMES_USER}"
HERMES_BIN="${HERMES_HOME}/.local/bin/hermes"

pass=0; fail=0
ok()  { printf '  [ok]   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); }

echo "== hermes user / install =="
id "$HERMES_USER" >/dev/null 2>&1 && ok "user $HERMES_USER exists" || bad "user $HERMES_USER missing"
[ -d "${HERMES_HOME}/.hermes" ] && ok "${HERMES_HOME}/.hermes/ exists" || bad "${HERMES_HOME}/.hermes/ missing"
[ -x "$HERMES_BIN" ] && ok "hermes binary present" || bad "hermes binary missing at $HERMES_BIN"
if [ -x "$HERMES_BIN" ]; then
  ver=$(sudo -u "$HERMES_USER" -H "$HERMES_BIN" --version 2>/dev/null | head -1 || true)
  [ -n "$ver" ] && ok "hermes reports: $ver" || bad "hermes --version returned nothing"
fi

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
if systemctl is-active --quiet openclaw; then
  ok "openclaw is active"
else
  bad "openclaw is NOT active - phase 1 should not have touched it"
fi
if ss -ltn 2>/dev/null | grep -q '127.0.0.1:18789'; then
  ok "openclaw listening on 127.0.0.1:18789"
else
  bad "nothing listening on 127.0.0.1:18789 - openclaw may be unhealthy"
fi

echo
echo "== hermes doctor =="
if [ -x "$HERMES_BIN" ]; then
  sudo -u "$HERMES_USER" -H "$HERMES_BIN" doctor || bad "hermes doctor returned non-zero"
fi

echo
echo "== summary =="
echo "  pass: $pass"
echo "  fail: $fail"
[ "$fail" -eq 0 ]
