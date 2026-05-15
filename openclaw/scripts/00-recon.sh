#!/usr/bin/env bash
# Read-only recon of the Shopware server before installing OpenClaw.
# Touches nothing. Safe to run anytime.
set -euo pipefail

hr() { printf '\n=== %s ===\n' "$1"; }

hr "Host"
hostname
uname -a
uptime

hr "OS / kernel"
. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "unknown"

hr "Disk (root)"
df -h /

hr "Memory"
free -h

hr "CPU"
nproc
lscpu | grep -E 'Model name|Socket|Core' || true

hr "Docker containers (read-only)"
if command -v docker >/dev/null 2>&1; then
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
else
  echo "docker not installed or not on PATH"
fi

hr "Listening TCP ports"
if command -v ss >/dev/null 2>&1; then
  sudo ss -tlnp 2>/dev/null || ss -tln
else
  sudo netstat -tlnp 2>/dev/null || netstat -tln
fi

hr "UFW status"
if command -v ufw >/dev/null 2>&1; then
  sudo ufw status verbose 2>/dev/null || echo "ufw present but not readable without sudo"
else
  echo "ufw not installed"
fi

hr "fail2ban status"
if command -v fail2ban-client >/dev/null 2>&1; then
  sudo fail2ban-client status 2>/dev/null || echo "fail2ban present but not readable"
else
  echo "fail2ban not installed"
fi

hr "Existing Node.js (system)"
command -v node && node -v || echo "no system node"
command -v nvm >/dev/null 2>&1 && echo "nvm present" || echo "no nvm"

hr "Existing OpenClaw"
command -v openclaw >/dev/null 2>&1 && openclaw --version || echo "not installed (expected)"

hr "Done"
echo "Copy the output above and send it back."
