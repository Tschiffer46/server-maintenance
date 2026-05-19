#!/usr/bin/env bash
#
# phase2-cutover.sh
#
# Cut over from OpenClaw to Hermes:
#   1. Preview the migration with `hermes claw migrate --dry-run`
#   2. Stop OpenClaw (frees the Telegram bot token and port 18789)
#   3. Stop hermes.service if running (clean .env write)
#   4. Run the migration for real with --overwrite --migrate-secrets
#   5. Enable + start hermes.service
#
# Idempotent: safe to re-run after a failed attempt.
#
# Run with sudo on the ops host.

set -uo pipefail

HERMES_USER="hermes"
HERMES_HOME="/home/${HERMES_USER}"
HERMES_BIN="${HERMES_HOME}/.local/bin/hermes"
OPENCLAW_USER="deploy"
OPENCLAW_HOME="/home/${OPENCLAW_USER}"
OPENCLAW_DIR="${OPENCLAW_HOME}/.openclaw"
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
[ -d "$OPENCLAW_DIR" ] || fail "$OPENCLAW_DIR missing - nothing to migrate"

latest_backup=$(ls -1t "${OPENCLAW_HOME}/openclaw-backup" 2>/dev/null | head -1 || true)
[ -n "$latest_backup" ] || fail "no ${OPENCLAW_HOME}/openclaw-backup found - run phase 0 first"
log "latest OpenClaw backup: ${OPENCLAW_HOME}/openclaw-backup/${latest_backup}"

# Grant hermes user a temporary read-only view of ~deploy/.openclaw.
log "granting hermes user temporary read access to $OPENCLAW_DIR"
ORIG_MODE=$(stat -c%a "$OPENCLAW_DIR")
ORIG_HOME_MODE=$(stat -c%a "$OPENCLAW_HOME")
chmod o+rx "$OPENCLAW_HOME"
if command -v setfacl >/dev/null 2>&1; then
  setfacl -R -m u:${HERMES_USER}:rX "$OPENCLAW_DIR" || chmod -R o+rX "$OPENCLAW_DIR"
else
  chmod -R o+rX "$OPENCLAW_DIR"
fi
restore_perms() {
  log "restoring original permissions on $OPENCLAW_DIR"
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -R -x u:${HERMES_USER} "$OPENCLAW_DIR" 2>/dev/null || true
  fi
  chmod "$ORIG_HOME_MODE" "$OPENCLAW_HOME" 2>/dev/null || true
  chmod -R "$ORIG_MODE" "$OPENCLAW_DIR" 2>/dev/null || true
}
trap restore_perms EXIT

# ----- Step 1: dry-run preview --------------------------------------------
echo
log "step 1/5 - dry-run preview"
log "  (no changes will be made by this step)"
echo
sudo -u "$HERMES_USER" -H "$HERMES_BIN" claw migrate \
  --source "$OPENCLAW_DIR" \
  --migrate-secrets \
  --overwrite \
  --dry-run \
  || log "dry-run reported issues - review above before continuing"

echo
confirm "dry-run done. proceed with stop OpenClaw + migrate (with --overwrite) + restart Hermes?"

# ----- Step 2: stop OpenClaw ----------------------------------------------
echo
log "step 2/5 - stopping OpenClaw (no-op if already stopped)"
for u in "${OPENCLAW_UNITS[@]}"; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${u}\.service"; then
    systemctl stop "$u" 2>/dev/null || true
    systemctl disable "$u" 2>/dev/null || true
  fi
done
if pgrep -fa 'openclaw' >/dev/null 2>&1; then
  pkill -TERM -f 'openclaw' || true
  sleep 3
  pgrep -fa 'openclaw' >/dev/null 2>&1 && pkill -KILL -f 'openclaw' || true
  sleep 1
fi
if ss -ltn 2>/dev/null | grep -q ":${OPENCLAW_PORT}\b"; then
  fail "port $OPENCLAW_PORT is still in use - investigate before continuing"
fi
log "  port $OPENCLAW_PORT is free"

# ----- Step 3: stop hermes so .env write is clean -------------------------
echo
log "step 3/5 - stopping hermes.service if running (so migration writes .env cleanly)"
if systemctl is-active --quiet hermes; then
  systemctl stop hermes
  log "  hermes stopped"
else
  log "  hermes was not running"
fi

# ----- Step 4: live migration ---------------------------------------------
echo
log "step 4/5 - running 'hermes claw migrate' with --overwrite --migrate-secrets"
log "  this will overwrite SOUL.md and model-config in ~hermes/.hermes/ with OpenClaw's values."
log "  After this you may want to re-pick the model: sudo -u $HERMES_USER -i hermes model"
echo
MIG_LOG=$(mktemp)
set +e
sudo -u "$HERMES_USER" -H "$HERMES_BIN" claw migrate \
  --source "$OPENCLAW_DIR" \
  --migrate-secrets \
  --overwrite \
  --yes 2>&1 | tee "$MIG_LOG"
rc=${PIPESTATUS[0]}
set -e

# Success signal from the tool: "Migration complete!" near end of output.
# Failure: explicit "Refusing to apply". (The phrase "No files were modified"
# also appears in the in-output preview even on success - don't match it.)
if [ "$rc" -ne 0 ] || grep -q 'Refusing to apply' "$MIG_LOG" || ! grep -q 'Migration complete' "$MIG_LOG"; then
  log ""
  log "migration did not complete cleanly (exit=$rc)."
  log "  log: $MIG_LOG"
  log "  options:"
  log "    - inspect the log, retry the migrate command manually"
  log "    - rollback to OpenClaw: see docs/hermes/rollback.md"
  fail "aborting phase 2 before restarting Hermes"
fi
rm -f "$MIG_LOG"

# ----- Step 5: start hermes -----------------------------------------------
echo
log "step 5/5 - enable + start hermes.service"
systemctl enable hermes 2>/dev/null || true
systemctl start hermes
sleep 4

state=$(systemctl is-active hermes || true)
log "  hermes is $state"
if [ "$state" != "active" ]; then
  log "hermes did not become active. recent logs:"
  journalctl -u hermes -n 40 --no-pager || true
  fail "phase 2 incomplete - see journalctl above"
fi

echo
log "phase 2 done."
log "  verify with: sudo bash scripts/hermes/phase2-verify.sh"
log "  if Hermes won't reply because of the imported model, re-pick:"
log "      sudo -u $HERMES_USER -i"
log "      hermes model"
log "      sudo systemctl restart hermes"
log "  test on Telegram: send any message to the bot - Hermes should reply."
