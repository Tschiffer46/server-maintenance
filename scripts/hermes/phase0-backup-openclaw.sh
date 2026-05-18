#!/usr/bin/env bash
#
# phase0-backup-openclaw.sh
#
# Snapshot OpenClaw state on 77.42.81.134 before installing Hermes.
# Non-destructive: OpenClaw keeps running.
#
# Run as the user OpenClaw is installed under (auto-detected from the
# systemd unit when run with sudo, otherwise uses $USER).

set -euo pipefail

umask 077

log() { printf '[phase0] %s\n' "$*"; }
fail() { printf '[phase0] ERROR: %s\n' "$*" >&2; exit 1; }

# Discover the systemd unit. The installed name on this host is
# `openclaw-gateway`; older docs called it `openclaw`. Match both.
UNIT_FILE=""
UNIT_NAME=""
for name in openclaw-gateway openclaw; do
  for dir in /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
    if [ -f "$dir/${name}.service" ]; then
      UNIT_FILE="$dir/${name}.service"
      UNIT_NAME="$name"
      break 2
    fi
  done
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
log "  unit:    ${UNIT_NAME:-<none detected>}"

cp -a "$DOT_OPENCLAW/." "$DEST/dot-openclaw/"
[ -n "$UNIT_FILE" ] && cp -a "$UNIT_FILE" "$DEST/systemd/" || true

{
  for name in openclaw-gateway openclaw; do
    echo "== systemctl status $name =="
    systemctl status "$name" --no-pager 2>&1 || true
    echo
    echo "== systemctl cat $name =="
    systemctl cat "$name" 2>&1 || true
    echo
  done
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
  echo "== openclaw process =="
  ps -fC node 2>&1 | grep -i claw || ps aux 2>&1 | grep -i claw | grep -v grep || true
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

# Manifest. Layout reflects what the running OpenClaw actually stores.
{
  echo "# OpenClaw backup manifest"
  echo
  echo "- Timestamp (UTC): $TS"
  echo "- Host: $(hostname -f 2>/dev/null || hostname)"
  echo "- User: $OPENCLAW_USER"
  echo "- Source: $DOT_OPENCLAW"
  echo "- Systemd unit: ${UNIT_NAME:-<none detected>}"
  echo
  echo "## Top-level entries in dot-openclaw/"
  ( cd "$DEST/dot-openclaw" && ls -la | sed 's/^/    /' )
  echo
  echo "## Key state captured"
  for entry in \
    openclaw.json \
    openclaw.json.last-good \
    identity/device.json \
    memory/main.sqlite \
    telegram/update-offset-default.json \
    credentials/telegram-pairing.json \
    credentials/telegram-default-allowFrom.json \
    exec-approvals.json \
    agents \
    flows \
    tasks \
    plugin-skills \
    plugins \
    workspace; do
    path="$DEST/dot-openclaw/$entry"
    if [ -e "$path" ]; then
      if [ -d "$path" ]; then
        n=$(find "$path" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
        echo "- $entry/ (directory, $n entries)"
      else
        sz=$(stat -c%s "$path" 2>/dev/null || stat -f%z "$path")
        echo "- $entry ($sz bytes)"
      fi
    else
      echo "- $entry MISSING"
    fi
  done
  echo
  echo "## Telegram credentials (sanitised view)"
  for f in "$DEST/dot-openclaw/credentials/telegram-pairing.json" \
           "$DEST/dot-openclaw/credentials/telegram-default-allowFrom.json"; do
    if [ -f "$f" ]; then
      echo "### $(basename "$f")"
      echo '```'
      sed -E 's/("(token|bot_token|api_token|secret)")\s*:\s*"[^"]+"/\1: "<REDACTED>"/g' "$f" | head -40
      echo '```'
    fi
  done
  echo
  echo "## Systemd unit captured"
  ls -la "$DEST/systemd" | sed 's/^/    /'
} > "$DEST/MANIFEST.md"

chmod -R go-rwx "$DEST"

log "done. inspect $DEST/MANIFEST.md"
log "recommended: copy the backup off this host before proceeding to phase 1"
log "  rsync -a $DEST your-workstation:openclaw-backup-$TS/"
