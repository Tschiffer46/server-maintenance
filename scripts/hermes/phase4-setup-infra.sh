#!/usr/bin/env bash
# Fas 4 – installera infrastruktur-övervakning.
# Körs som root (sudo) på ATM-shops (77.42.81.134).
#
# FÖRUTSÄTTNING: SSH-nycklarna för hermes-användaren måste redan finnas:
#   /home/hermes/.ssh/id_ed25519_mailcow      (kopierad från Mac)
#   /home/hermes/.ssh/id_ed25519_monitoring   (genererad på ATM-shops)
# Se docs/hermes/migration-plan.md fas 4 för hur nycklarna läggs på plats.
#
# Vad skriptet gör:
#  1. Kopierar infra.conf till /etc/hermes-monitoring/
#  2. Verifierar att SSH-nycklarna finns och sätter rättigheter
#  3. Lägger till båda servers i hermes SSH known_hosts
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

# Ladda konfiguration
# shellcheck source=/dev/null
[ -f "$REPO_ROOT/config/infra.conf" ] && source "$REPO_ROOT/config/infra.conf"
MAILCOW_HOST="${MAILCOW_HOST:-204.168.157.75}"
MAILCOW_SSH_KEY="${MAILCOW_SSH_KEY:-$HERMES_HOME/.ssh/id_ed25519_mailcow}"
WEBHOSTING_HOST="${WEBHOSTING_HOST:-89.167.90.112}"
WEBHOSTING_SSH_KEY="${WEBHOSTING_SSH_KEY:-$HERMES_HOME/.ssh/id_ed25519_monitoring}"

# --- 1. Kopiera infra.conf ---
echo "[1/5] Kopierar infra.conf..."
cp "$REPO_ROOT/config/infra.conf" "$CONF_DIR/infra.conf"
chmod 644 "$CONF_DIR/infra.conf"
echo "  $CONF_DIR/infra.conf installerad"

# --- 2. Verifiera SSH-nycklar ---
echo "[2/5] Verifierar SSH-nycklar för hermes-användaren..."
missing_key=0
for key_info in "$MAILCOW_SSH_KEY:mailcow" "$WEBHOSTING_SSH_KEY:web-hosting-prod"; do
    key="${key_info%%:*}"
    label="${key_info##*:}"
    if [ -f "$key" ]; then
        chown hermes:hermes "$key"
        chmod 600 "$key"
        echo "  OK: $label-nyckel finns ($key)"
    else
        echo "  SAKNAS: $label-nyckel ($key)"
        missing_key=1
    fi
done

if [ "$missing_key" -ne 0 ]; then
    echo ""
    echo "FEL: En eller flera SSH-nycklar saknas."
    echo "Lägg dem på plats först (se migration-plan.md fas 4) och kör om."
    exit 1
fi

# --- 3. known_hosts för båda servers ---
echo "[3/5] Lägger till servers i SSH known_hosts..."
KNOWN_HOSTS="$HERMES_HOME/.ssh/known_hosts"
touch "$KNOWN_HOSTS"
for h in "$MAILCOW_HOST" "$WEBHOSTING_HOST"; do
    if ! grep -q "$h" "$KNOWN_HOSTS" 2>/dev/null; then
        sudo -u hermes ssh-keyscan -T 10 "$h" >> "$KNOWN_HOSTS" 2>/dev/null || true
    fi
done
chown hermes:hermes "$KNOWN_HOSTS"
chmod 600 "$KNOWN_HOSTS"
echo "  $MAILCOW_HOST och $WEBHOSTING_HOST i known_hosts"

# --- 4. Installera övervakningsskript ---
echo "[4/5] Installerar skript..."
mkdir -p "$LIB_DIR"
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
echo "  (mailcow)"
sudo -u hermes bash "$LIB_DIR/mailcow-check.sh" 2>&1 | tail -5 || true
echo ""
echo "  (web-hosting-prod)"
sudo -u hermes bash "$LIB_DIR/webhosting-check.sh" 2>&1 | tail -5 || true

echo ""
echo "✔ Fas 4 klar!"
echo ""
echo "Vad händer nu:"
echo "  • mailcow-server (${MAILCOW_HOST}) och web-hosting-prod (${WEBHOSTING_HOST})"
echo "    checkas var 10:e minut"
echo "  • Mailcow-portar (25/465/587/993) kontrolleras utifrhån"
echo ""
echo "Verifiera med:"
echo "  sudo bash scripts/hermes/phase4-verify.sh"
