#!/usr/bin/env bash
# Prepare the Shopware host for OpenClaw. Idempotent — safe to re-run.
# Touches: apt packages, ufw rules, fail2ban service, nvm + Node 24 for $SUDO_USER.
# Does NOT touch: Docker, Shopware, existing site configs.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo bash $0" >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
  echo "This script must be run via sudo from a non-root user (so nvm installs into their home)." >&2
  exit 1
fi
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

log() { printf '\n▶ %s\n' "$*"; }

log "Updating apt index and applying security updates"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get -y -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' upgrade
apt-get -y install ca-certificates curl gnupg lsb-release git jq unattended-upgrades

log "Ensuring fail2ban is installed and enabled"
if ! command -v fail2ban-client >/dev/null 2>&1; then
  apt-get -y install fail2ban
fi
systemctl enable --now fail2ban

log "Configuring UFW (preserving existing rules)"
if ! command -v ufw >/dev/null 2>&1; then
  apt-get -y install ufw
fi
# Only set defaults if UFW is inactive — don't override what's already in place
if ! ufw status | grep -q "Status: active"; then
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH
  ufw allow 80/tcp
  ufw allow 443/tcp
  yes | ufw enable
fi
# OpenClaw Gateway is localhost-only by default — no UFW rule needed.
ufw status verbose || true

log "Installing nvm + Node 24 for user '$TARGET_USER'"
NVM_DIR="$TARGET_HOME/.nvm"
if [[ ! -d "$NVM_DIR" ]]; then
  sudo -u "$TARGET_USER" -H bash -lc 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash'
fi
sudo -u "$TARGET_USER" -H bash -lc '
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  nvm install 24
  nvm alias default 24
  node -v
  npm -v
'

log "Enabling lingering for $TARGET_USER (so the systemd --user daemon survives logout)"
loginctl enable-linger "$TARGET_USER" || true

log "Disk and memory after prep"
df -h /
free -h

echo
echo "✅ Server prep complete. Next: bash openclaw/scripts/02-install-openclaw.sh"
