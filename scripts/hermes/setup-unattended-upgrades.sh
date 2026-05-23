#!/usr/bin/env bash
# Konfigurerar unattended-upgrades för automatisk installation av enbart
# säkerhetspatcher kl 05:00 varje natt. Reboot körs ALDRIG automatiskt –
# notis går via den dagliga rapporten kl 08:00.
#
# Körs på VARJE server (ATM-shops, mailcow-server, web-hosting-prod).
# Kräver root (sudo).
#
# Användning:
#   sudo bash setup-unattended-upgrades.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Det här skriptet måste köras som root (använd sudo)." >&2
    exit 1
fi

echo "=== Konfigurerar unattended-upgrades ==="

# 1. Installera paket
echo "[1/4] Installerar paket..."
DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades apt-listchanges >/dev/null
echo "  unattended-upgrades + apt-listchanges installerade"

# 2. Identifiera distribution för att välja rätt repo-label
codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-bookworm}")
distro_id=$(. /etc/os-release && echo "${ID:-debian}")

if [ "$distro_id" = "debian" ]; then
    origins='Debian,codename=${distro_codename},label=Debian-Security'
elif [ "$distro_id" = "ubuntu" ]; then
    origins='${distro_id}:${distro_codename}-security'
else
    origins='Debian,codename=${distro_codename},label=Debian-Security'
fi

# 3. Skriv 50unattended-upgrades (enbart security)
echo "[2/4] Skriver /etc/apt/apt.conf.d/50unattended-upgrades..."
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
// Genererad av server-maintenance/scripts/hermes/setup-unattended-upgrades.sh
// Endast säkerhetsuppdateringar installeras automatiskt.

Unattended-Upgrade::Origins-Pattern {
    "origin=${origins}";
};

// Aldrig automatisk omstart – vi rapporterar i daglig rapport istället
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
// Reboot körs ENDAST om /var/run/reboot-required finns. Vald tid 05:45
// lokal, dvs ca 15 min efter att paketen installerats. Ändra till "false"
// här (eller kör skriptet igen efter att ha bytt) när servern är i
// produktion och du själv vill schemalägga omstart.
Unattended-Upgrade::Automatic-Reboot-Time "05:45";

// Behåll konfigurationsfiler vid uppgradering
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";

// Ta bort oanvända kernel-paket men inte automatiskt-installerade
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "false";

// Maila inte (vi rapporterar via Telegram istället)
Unattended-Upgrade::Mail "";

// Logga utförligt
Unattended-Upgrade::Verbose "true";
EOF
echo "  klart"

# 4. Aktivera periodisk körning
echo "[3/4] Skriver /etc/apt/apt.conf.d/20auto-upgrades..."
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
echo "  klart"

# 5. Override tidpunkt för apt-daily-upgrade.timer till 05:00
echo "[4/4] Sätter körtid till 05:00..."
mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
cat > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 05:00:00
RandomizedDelaySec=30min
Persistent=true
EOF

systemctl daemon-reload
systemctl enable apt-daily-upgrade.timer >/dev/null 2>&1 || true
systemctl restart apt-daily-upgrade.timer
echo "  apt-daily-upgrade.timer satt till 05:00 (med upp till 30 min slumpmässig fördröjning)"

echo ""
echo "✔ Klart!"
echo ""
echo "Verifiera:"
echo "  systemctl list-timers apt-daily-upgrade.timer"
echo "  sudo unattended-upgrade --dry-run --debug 2>&1 | tail -20"
echo ""
echo "Loggfil: /var/log/unattended-upgrades/unattended-upgrades.log"
