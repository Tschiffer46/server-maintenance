#!/usr/bin/env bash
# Fas 4 – installera infrastruktur-övervakning.
# Körs som root (sudo) på 77.42.81.134.
#
# Vad skriptet gör:
#  1. Kopierar infra.conf till /etc/hermes-monitoring/
#  2. Kopierar SSH-nyckel för web-hosting-prod till hermes-användaren
#  3. Lägger till web-hosting-prod i hermes SSH known_hosts
#  4. Installerar mailcow-check.sh och webhosting-check.sh
#  5. Installerar och startar hermes-infra-check.service + .timer

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_DIR="/usr/local/lib/hermes-monitoring"
CONF_DIR="/etc/hermes-monitoring"
HERMES_HOME="/home/hermes"

echo "=== Fas 4: Infrastruktur-övervakning ==="
echo ""

if [ "$(id -u)" -ne 0 ]; then
    echo "FEL: Kör med sudo: sudo bash $0"
    exit 1
fi

# Ladda in konfiguration för att få WEBHOSTING_HOST och SSH_USER
# shellcheck source=/dev/null
[ -f "$REPO_ROOT/config/infra.conf" ] && source "$REPO_ROOT/config/infra.conf"
WEBHOSTING_HOST="${WEBHOSTING_HOST:-89.167.90.112}"
WEBHOSTING_SSH_USER="${WEBHOSTING_SSH_USER:-deploy}"
WEBHOSTING_SSH_KEY="${WEBHOSTING_SSH_KEY:-$HERMES_HOME/.ssh/id_ed25519_webhosting}"

# --- 1. Kopiera infra.conf ---
echo "[1/5] Kopierar infra.conf..."
cp "$REPO_ROOT/config/infra.conf" "$CONF_DIR/infra.conf"
chmod 644 "$CONF_DIR/infra.conf"
echo "  $CONF_DIR/infra.conf installerad"

# --- 2. Kopiera SSH-nyckel ---
echo "[2/5] Kopierar SSH-nyckel för web-hosting-prod..."
mkdir -p "$HERMES_HOME/.ssh"
chmod 700 "$HERMES_HOME/.ssh"

# Hitta källnyckeln (deploy-användarens nyckel)
SRC_KEY=""
for candidate in \
    "/home/deploy/.ssh/id_ed25519" \
    "/root/.ssh/id_ed25519" \
    "$HOME/.ssh/id_ed25519"
do
    if [ -f "$candidate" ]; then
        SRC_KEY="$candidate"
        break
    fi
done

if [ -z "$SRC_KEY" ]; then
    echo "  FEL: Hittade inte SSH-nyckeln (~/.ssh/id_ed25519)."
    echo "  Ange sökväg till nyckeln:"
    read -rp "  Sökväg: " SRC_KEY
fi

cp "$SRC_KEY" "$WEBHOSTING_SSH_KEY"
chown hermes:hermes "$WEBHOSTING_SSH_KEY"
chmod 600 "$WEBHOSTING_SSH_KEY"
echo "  SSH-nyckel kopierad till $WEBHOSTING_SSH_KEY"

# --- 3. Lägg till known_hosts ---
echo "[3/5] Lägger till $WEBHOSTING_HOST i SSH known_hosts..."
KNOWN_HOSTS="$HERMES_HOME/.ssh/known_hosts"
sudo -u hermes ssh-keyscan -T 10 "$WEBHOSTING_HOST" >> "$KNOWN_HOSTS" 2>/dev/null || true
chown hermes:hermes "$KNOWN_HOSTS"
chmod 600 "$KNOWN_HOSTS"
echo "  $WEBHOSTING_HOST tillagd i known_hosts"

# --- 4. Installera övervakningsskript ---
echo "[4/5] Installerar skript..."
cp "$REPO_ROOT/scripts/hermes/monitoring/mailcow-check.sh" "$LIB_DIR/"
cp "$REPO_ROOT/scripts/hermes/monitoring/webhosting-check.sh" "$LIB_DIR/"
chmod +x "$LIB_DIR/mailcow-check.sh" "$LIB_DIR/webhosting-check.sh"
echo "  mailcow-check.sh och webhosting-check.sh installerade"

# --- 5. Installera systemd-unit och timer ---
echo "[5/5] Installerar systemd-unit..."
cp "$REPO_ROOT/systemd/hermes-infra-check.service" /etc/systemd/system/
cp "$REPO_ROOT/systemd/hermes-infra-check.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable hermes-infra-check.timer
systemctl start hermes-infra-check.timer
echo "  hermes-infra-check.timer aktiverad och startad"

# Kör en första check direkt
echo ""
echo "Kör första infra-check nu..."
sudo -u hermes bash "$LIB_DIR/mailcow-check.sh" 2>&1 | tail -3 || true
echo ""
sudo -u hermes bash "$LIB_DIR/webhosting-check.sh" 2>&1 | tail -3 || true

echo ""
echo "✔ Fas 4 klar!"
echo ""
echo "Vad händer nu:"
echo "  • Mailcow + web-hosting-prod checkas var 10:e minut"
echo "  • Disk/RAM-varning vid ${DISK_WARN_PERCENT}% resp ${MEM_WARN_PERCENT}%"
echo ""
echo "Verifiera med:"
echo "  sudo bash scripts/hermes/phase4-verify.sh"
