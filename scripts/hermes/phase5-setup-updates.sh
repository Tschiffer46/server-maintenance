#!/usr/bin/env bash
# Installerar update-check.sh + systemd-timer på ATM-shops.
# Måste köras som root.
#
# Efter att skriptet körts: kör setup-unattended-upgrades.sh på VARJE server
# (ATM-shops lokalt, mailcow + web-hosting via SSH). Se instruktioner som
# skrivs ut nedan.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Måste köras som root (sudo)." >&2
    exit 1
fi

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

LIB_DIR="/usr/local/lib/hermes-monitoring"
SYSTEMD_DIR="/etc/systemd/system"

echo "=== Fas 5: Uppdateringsövervakning ==="

echo "[1/3] Installerar update-check.sh..."
install -o root -g root -m 755 \
    "${REPO_ROOT}/scripts/hermes/monitoring/update-check.sh" \
    "${LIB_DIR}/update-check.sh"

# daily-report.sh har också uppdaterats – kopiera om den
install -o root -g root -m 755 \
    "${REPO_ROOT}/scripts/hermes/monitoring/daily-report.sh" \
    "${LIB_DIR}/daily-report.sh"
echo "  update-check.sh + daily-report.sh installerade i ${LIB_DIR}"

echo "[2/3] Installerar systemd-unit..."
install -o root -g root -m 644 \
    "${REPO_ROOT}/systemd/hermes-update-check.service" \
    "${SYSTEMD_DIR}/hermes-update-check.service"
install -o root -g root -m 644 \
    "${REPO_ROOT}/systemd/hermes-update-check.timer" \
    "${SYSTEMD_DIR}/hermes-update-check.timer"

systemctl daemon-reload
systemctl enable --now hermes-update-check.timer
echo "  hermes-update-check.timer aktiverad (körs 07:50 varje dag)"

echo "[3/3] Kör första update-check nu..."
sudo -u hermes bash "${LIB_DIR}/update-check.sh" || true

echo ""
echo "✔ Lokal del klar!"
echo ""
echo "NÄSTA STEG: Aktivera automatiska säkerhetspatcher på varje server."
echo ""
echo "På ATM-shops (här, lokalt):"
echo "  sudo bash ${REPO_ROOT}/scripts/hermes/setup-unattended-upgrades.sh"
echo ""
echo "På mailcow-server (kör från ATM-shops):"
echo "  scp ${REPO_ROOT}/scripts/hermes/setup-unattended-upgrades.sh \\"
echo "      root@204.168.157.75:/tmp/"
echo "  ssh root@204.168.157.75 'bash /tmp/setup-unattended-upgrades.sh && rm /tmp/setup-unattended-upgrades.sh'"
echo ""
echo "På web-hosting-prod (deploy-user har inte sudo – logga in som vanligt"
echo "och kör scriptet med sudo där):"
echo "  ssh deploy@89.167.90.112"
echo "  # på servern:"
echo "  curl -sO https://raw.githubusercontent.com/Tschiffer46/server-maintenance/claude/migrate-openclaw-hermes-eupAL/scripts/hermes/setup-unattended-upgrades.sh"
echo "  sudo bash setup-unattended-upgrades.sh"
echo "  rm setup-unattended-upgrades.sh"
echo ""
echo "Verifiera fas 5:"
echo "  sudo bash ${REPO_ROOT}/scripts/hermes/phase5-verify.sh"
