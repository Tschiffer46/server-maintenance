#!/bin/bash
# Server Hardening Script — Run ONCE manually with sudo
# Usage: sudo bash harden-server.sh
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (sudo bash harden-server.sh)"
  exit 1
fi

echo "=== Server Hardening: $(date) ==="

# 1. UFW Firewall
echo ""
echo "--- Setting up UFW Firewall ---"
apt-get install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
# Port 81 (NPM admin) is NOT opened — use SSH tunnel to access:
# ssh -L 8081:localhost:81 deploy@89.167.90.112
ufw --force enable
ufw status verbose

# 2. fail2ban
echo ""
echo "--- Setting up fail2ban ---"
apt-get install -y fail2ban
cat > /etc/fail2ban/jail.local << 'JAILEOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200
JAILEOF
systemctl enable fail2ban
systemctl restart fail2ban
echo "Waiting for fail2ban to start..."
sleep 5
echo "fail2ban status:"
fail2ban-client status sshd || echo "WARNING: fail2ban may still be starting. Check with: sudo fail2ban-client status sshd"

# 3. SSH Hardening
echo ""
echo "--- Hardening SSH ---"
SSHD_CONFIG="/etc/ssh/sshd_config"

# Only modify if not already set correctly
grep -q "^PermitRootLogin no" "$SSHD_CONFIG" || {
  sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"
  echo "Set PermitRootLogin no"
}
grep -q "^PasswordAuthentication no" "$SSHD_CONFIG" || {
  sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
  echo "Set PasswordAuthentication no"
}
grep -q "^MaxAuthTries 3" "$SSHD_CONFIG" || {
  sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/' "$SSHD_CONFIG"
  echo "Set MaxAuthTries 3"
}
systemctl reload sshd
echo "SSH hardened"

# 4. Unattended Security Upgrades
echo ""
echo "--- Setting up unattended-upgrades ---"
apt-get install -y unattended-upgrades
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'UUEOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
UUEOF
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'AUEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
AUEOF
echo "Unattended upgrades configured (security patches only, no auto-reboot)"

# 5. Docker Daemon Hardening
echo ""
echo "--- Hardening Docker ---"
cat > /etc/docker/daemon.json << 'DOCKEREOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
DOCKEREOF
systemctl restart docker
echo "Docker log rotation configured"

# Wait for containers to come back
echo "Waiting for containers to restart..."
sleep 15

# Verify containers are running
echo ""
echo "--- Verification ---"
docker ps --format "table {{.Names}}\t{{.Status}}"
echo ""
echo "UFW status:"
ufw status
echo ""
echo "=== Hardening Complete ==="
echo ""
echo "IMPORTANT: Access Nginx Proxy Manager admin via SSH tunnel:"
echo "  ssh -L 8081:localhost:81 deploy@89.167.90.112"
echo "  Then open http://localhost:8081 in your browser"
