#!/usr/bin/env bash
#
# phase1-install-hermes.sh
#
# Install Hermes Agent on 77.42.81.134 under a dedicated `hermes` system
# user, alongside the running OpenClaw. Does NOT start the service - that
# happens in phase 2 after `hermes setup` is run interactively.
#
# Run with sudo on the ops host.

set -euo pipefail

INSTALLER_URL="https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh"
INSTALLER_PATH="/tmp/hermes-install.sh"
HERMES_USER="hermes"
HERMES_HOME="/home/${HERMES_USER}"
UNIT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.. && pwd)/systemd/hermes.service"
UNIT_DST="/etc/systemd/system/hermes.service"

log() { printf '[phase1] %s\n' "$*"; }
fail() { printf '[phase1] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || fail "run with sudo"
[ -f "$UNIT_SRC" ] || fail "could not find $UNIT_SRC - run from a clone of the repo"

# 1. Verify OpenClaw is still up before we touch anything.
if systemctl is-active --quiet openclaw; then
  log "openclaw is active - good, we will not touch it"
else
  log "WARNING: openclaw is not active. Phase 0 assumed it was running."
  read -r -p "continue anyway? [y/N] " ans
  [ "$ans" = "y" ] || exit 1
fi

# 2. Create the hermes user.
if id "$HERMES_USER" >/dev/null 2>&1; then
  log "user $HERMES_USER already exists"
else
  log "creating system user $HERMES_USER"
  useradd --system --create-home --shell /bin/bash --home-dir "$HERMES_HOME" "$HERMES_USER"
fi

# 3. Download the installer to a file, show its checksum, ask for consent
#    before executing. This is the bit users should never blindly accept.
log "downloading installer to $INSTALLER_PATH"
curl -fsSL "$INSTALLER_URL" -o "$INSTALLER_PATH"
chmod 0755 "$INSTALLER_PATH"

log "installer SHA256:"
sha256sum "$INSTALLER_PATH"
log "size: $(stat -c%s "$INSTALLER_PATH") bytes"
log "review with: less $INSTALLER_PATH"
read -r -p "run installer as $HERMES_USER now? [y/N] " ans
[ "$ans" = "y" ] || { log "aborted by user"; exit 1; }

# 4. Run the installer as the hermes user.
log "running installer as $HERMES_USER (this can take a few minutes)"
sudo -u "$HERMES_USER" -H bash "$INSTALLER_PATH"

# 5. Sanity check binary.
HERMES_BIN="${HERMES_HOME}/.local/bin/hermes"
[ -x "$HERMES_BIN" ] || fail "expected $HERMES_BIN to exist after install"
log "hermes binary: $HERMES_BIN"
sudo -u "$HERMES_USER" -H "$HERMES_BIN" --version || true

# 6. Drop systemd unit. Do NOT enable / start - phase 2 does that.
log "installing systemd unit -> $UNIT_DST"
install -m 0644 "$UNIT_SRC" "$UNIT_DST"
systemctl daemon-reload

log ""
log "phase 1 done. next steps (manual):"
log "  1. sudo -u $HERMES_USER -i"
log "  2. hermes setup       # choose Nous Portal as LLM provider; skip channels for now"
log "  3. exit"
log "  4. bash scripts/hermes/phase1-verify.sh"
