#!/usr/bin/env bash
#
# phase0-backup-openclaw.sh
#
# Snapshot OpenClaw state on 77.42.81.134 before installing Hermes.
# Non-destructive: OpenClaw keeps running.
#
# Run as the user OpenClaw is installed under (the script auto-detects
# from the systemd unit when run with sudo, otherwise it uses $USER).

set -euo pipefail

umask 077

log() { printf '[phase0] %s\n' "$*"; }
fail() { printf '[phase0] ERROR: %s\n' "$*" >&2; exit 1; }

UNIT_FILE=""
for candidate in \
  /etc/systemd/system/openclaw.service \
  /lib/systemd/system/openclaw.service \
  /usr/lib/systemd/system/openclaw.service; do
  if [ -f "$candidate" ]; then UNIT_FILE="$candidate"; break; fi
done

if [ -n "$UNIT_FILE" ]; then
  OPENCLAW_USER=$(awk -F= '/^User=/{print $2; exit}' "$UNIT_FILE" || true)
fi
OPENCLAW_USER="${OPENCLAW_USER:-$USER}"
OPENCLAW_HOME=$(getent passwd "$OPENCLAW_USER" | cut -d: -f6)
[ -d "$OPENCLAW_HOME" ] || fail "could not resolve home for user $OPENCLAW_USER"

DOT_OPENCLAW="$OPENCLAW_HOME/.openclaw"
[ -d "$DOT_OPENCLAW" ] || fail "$DOT_OPENCLAW does not exist - is OpenClaw installed for $OPENCLAW_USER?"

TS=$(date -u +%Y%m%dT%H%M%SZ)
DEST="$OPENCLAW_HOME/openclaw-backup/$TS"
mkdir -p "$DEST/dot-openclaw" "$DEST/systemd"

log "backing up to $DEST"
log "  user:    $OPENCLAW_USER"
log "  home:    $OPENCLAW_HOME"
log "  source:  $DOT_OPENCLAW"

cp -a "$DOT_OPENCLAW/." "$DEST/dot-openclaw/"
[ -n "$UNIT_FILE" ] && cp -a "$UNIT_FILE" "$DEST/systemd/" || true

{
  echo "== systemctl status openclaw =="
  systemctl status openclaw --no-pager 2>&1 || true
  echo
  echo "== systemctl cat openclaw =="
  systemctl cat openclaw 2>&1 || true
  echo
  echo "== node / npm / nvm =="
  command -v node && node --version || true
  command -v npm && npm --version || true
  if [ -s "$HOME/.nvm/nvm.sh" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.nvm/nvm.sh"
    nvm --version 2>&1 || true
    nvm current 2>&1 || true
    nvm ls 2>&1 || true
  fi
  echo
  echo "== global npm packages =="
  npm ls -g --depth=0 2>&1 || true
  echo
  echo "== open ports (looking for 18789) =="
  ss -ltnp 2>&1 | grep -E ':(18789|LISTEN)' || true
  echo
  echo "== ufw status =="
  sudo -n ufw status numbered 2>&1 || ufw status numbered 2>&1 || echo "ufw not queryable without sudo"
  echo
  echo "== crontab for $OPENCLAW_USER =="
  crontab -u "$OPENCLAW_USER" -l 2>&1 || true
  echo
  echo "== /etc/cron.d entries mentioning openclaw =="
  grep -rl -i openclaw /etc/cron.* 2>/dev/null || true
} > "$DEST/state.txt"

# Manifest
{
  echo "# OpenClaw backup manifest"
  echo
  echo "- Timestamp (UTC): $TS"
  echo "- Host: $(hostname -f 2>/dev/null || hostname)"
  echo "- User: $OPENCLAW_USER"
  echo "- Source: $DOT_OPENCLAW"
  echo
  echo "## Top-level entries in dot-openclaw/"
  ( cd "$DEST/dot-openclaw" && ls -la | sed 's/^/    /' )
  echo
  echo "## Key files present"
  for f in SOUL.md IDENTITY.md USER.md MEMORY.md AGENTS.md config.yaml .env; do
    if [ -e "$DEST/dot-openclaw/$f" ]; then
      sz=$(stat -c%s "$DEST/dot-openclaw/$f" 2>/dev/null || stat -f%z "$DEST/dot-openclaw/$f")
      echo "- $f ($sz bytes)"
    else
      echo "- $f MISSING"
    fi
  done
  echo
  echo "## Skills"
  if [ -d "$DEST/dot-openclaw/skills" ]; then
    ( cd "$DEST/dot-openclaw/skills" && find . -maxdepth 2 -type f | sed 's/^/    /' )
  else
    echo "_no skills/ directory_"
  fi
  echo
  echo "## Systemd unit captured"
  ls -la "$DEST/systemd" | sed 's/^/    /'
} > "$DEST/MANIFEST.md"

chmod -R go-rwx "$DEST"

log "done. inspect $DEST/MANIFEST.md"
log "recommended: copy the backup off this host before proceeding to phase 1"
log "  rsync -a $DEST your-workstation:openclaw-backup-$TS/"
