#!/usr/bin/env bash
#
# phase2-cutover.sh
#
# Cut over from OpenClaw to Hermes:
#   1. Preview the migration with `hermes claw migrate --dry-run`
#   2. Stop OpenClaw (frees the Telegram bot token and port 18789)
#   3. Run the migration for real
#   4. Enable and start hermes.service
#
# Each destructive step asks for confirmation. If anything goes wrong
# before step 4 succeeds, see docs/hermes/rollback.md for how to restart
# OpenClaw.
#
# Run with sudo on the ops host.

set -uo pipefail

HERMES_USER="hermes"
HERMES_HOME="/home/${HERMES_USER}"
HERMES_BIN="${HERMES_HOME}/.local/bin/hermes"
OPENCLAW_USER="deploy"
OPENCLAW_HOME="/home/${OPENCLAW_USER}"
OPENCLAW_PORT=18789
OPENCLAW_UNITS=(openclaw-gateway openclaw)

log() { printf '[phase2] %s\n' "$*"; }
fail() { printf '[phase2] ERROR: %s\n' "$*" >&2; exit 1; }
confirm() {
  local msg="$1"
  read -r -p "[phase2] $msg [y/N] " ans
  [ "$ans" = "y" ] || { log "aborted by user"; exit 1; }
}

[ "$EUID" -eq 0 ] || fail "run with sudo"
[ -x "$HERMES_BIN" ] || fail "hermes binary missing at $HERMES_BIN - run phase 1 first"
[ -d "${OPENCLAW_HOME}/.openclaw" ] || fail "${OPENCLAW_HOME}/.openclaw missing - nothing to migrate"

# Make sure phase 0 backup exists before we touch anything.
latest_backup=$(ls -1t "${OPENCLAW_HOME}/openclaw-backup" 2>/dev/null | head -1 || true)
[ -n "$latest_backup" ] || fail "no ${OPENCLAW_HOME}/openclaw-backup found - run phase 0 first"
log "latest OpenClaw backup: ${OPENCLAW_HOME}/openclaw-backup/${latest_backup}"

# Make the OpenClaw config readable by the hermes user just for the
# migration. We restore the original mode at the end.
log "granting hermes user temporary read access to ~deploy/.openclaw"
ORIG_MODE=$(stat -c%a "${OPENCLAW_HOME}/.openclaw")
ORIG_HOME_MODE=$(stat -c%a "${OPENCLAW_HOME}")
chmod o+rx "${OPENCLAW_HOME}"
setfacl -R -m u:${HERMES_USER}:rX "${OPENCLAW_HOME}/.openclaw" 2>/dev/null \
  || chmod -R o+rX "${OPENCLAW_HOME}/.openclaw"
restore_perms() {
  log "restoring original permissions on ~deploy/.openclaw"
  setfacl -R -x u:${HERMES_USER} "${OPENCLAW_HOME}/.openclaw" 2>/dev/null || true
  chmod "$ORIG_HOME_MODE" "${OPENCLAW_HOME}" 2>/dev/null || true
  chmod -R "$ORIG_MODE" "${OPENCLAW_HOME}/.openclaw" 2>/dev/null || true
}
trap restore_perms EXIT

# ----- Step 1: dry-run preview --------------------------------------------
echo
log "step 1/4 - dry-run preview of 'hermes claw migrate'"
log "  (no changes will be made by this step)"
echo
sudo -u "$HERMES_USER" -H "$HERMES_BIN" claw migrate --dry-run \
  --openclaw-home "${OPENCLAW_HOME}/.openclaw" 2>&1 \
  || log "dry-run reported issues - review above before continuing"

echo
confirm "dry-run done. review the output above. proceed to stop OpenClaw and migrate?"

# ----- Step 2: stop OpenClaw ----------------------------------------------
echo
log "step 2/4 - stopping OpenClaw"
stopped=0
for u in "${OPENCLAW_UNITS[@]}"; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${u}\.service"; then
    log "  systemctl stop $u"
    systemctl stop "$u" || true
    systemctl disable "$u" 2>/dev/null || true
    stopped=1
  fi
done
# Belt and suspenders: kill any remaining openclaw process.
if pgrep -fa 'openclaw' >/dev/null 2>&1; then
  log "  sending SIGTERM to remaining openclaw processes"
  pkill -TERM -f 'openclaw' || true
  sleep 3
  if pgrep -fa 'openclaw' >/dev/null 2>&1; then
    log "  still running - sending SIGKILL"
    pkill -KILL -f 'openclaw' || true
    sleep 1
  fi
  stopped=1
fi
[ "$stopped" -eq 1 ] || log "  no openclaw process was running"

if ss -ltn 2>/dev/null | grep -q ":${OPENCLAW_PORT}\b"; then
  fail "port $OPENCLAW_PORT is still in use after stop attempt - investigate before continuing"
fi
log "  port $OPENCLAW_PORT is free"

# ----- Step 3: live migration ---------------------------------------------
echo
log "step 3/4 - running 'hermes claw migrate' for real"
echo
if ! sudo -u "$HERMES_USER" -H "$HERMES_BIN" claw migrate \
     --openclaw-home "${OPENCLAW_HOME}/.openclaw"; then
  log ""
  log "migration command exited non-zero. options:"
  log "  - retry: sudo -u $HERMES_USER -H $HERMES_BIN claw migrate --openclaw-home ${OPENCLAW_HOME}/.openclaw"
  log "  - rollback to OpenClaw: see docs/hermes/rollback.md"
  fail "aborting phase 2"
fi

# ----- Step 4: start hermes ------------------------------------------------
echo
log "step 4/4 - enable + start hermes.service"
systemctl enable hermes
systemctl start hermes
sleep 4

state=$(systemctl is-active hermes || true)
log "  hermes is $state"
if [ "$state" != "active" ]; then
  log "hermes did not become active. recent logs:"
  journalctl -u hermes -n 40 --no-pager || true
  log "see also: systemctl status hermes"
  fail "phase 2 incomplete"
fi

echo
log "phase 2 done."
log "  verify with: sudo bash scripts/hermes/phase2-verify.sh"
log "  test on Telegram: send any message to the bot - Hermes should reply now."
