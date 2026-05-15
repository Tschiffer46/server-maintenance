#!/usr/bin/env bash
# Install OpenClaw globally for the current (non-root) user and launch the
# interactive onboarding wizard. Idempotent: re-running upgrades to latest.
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "Run this WITHOUT sudo (as your normal user). nvm + npm global must stay in your home." >&2
  exit 1
fi

export NVM_DIR="$HOME/.nvm"
if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
  echo "nvm not found — run scripts/01-prepare-server.sh first." >&2
  exit 1
fi
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"
nvm use 24 >/dev/null

echo "Node:  $(node -v)"
echo "npm:   $(npm -v)"

echo
echo "▶ Installing/updating openclaw (global)"
npm install -g openclaw@latest

echo
echo "▶ openclaw version"
openclaw --version || true

echo
echo "▶ Launching onboarding wizard (interactive)"
echo "   Refer to PLAYBOOK.md Step 6 for which answers to pick."
echo
openclaw onboard --install-daemon

echo
echo "▶ Post-install checks"
openclaw doctor || true
openclaw gateway status || true

echo
echo "✅ OpenClaw installed. Go to PLAYBOOK.md Step 7 to smoke-test from Telegram."
