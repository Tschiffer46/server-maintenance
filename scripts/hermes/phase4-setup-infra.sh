#!/usr/bin/env bash
# Fas 4 – installera infrastruktur-övervakning.
# Körs som root (sudo) på ATM-shops (77.42.81.134).
#
# Vad skriptet gör:
#  1. Kopierar infra.conf till /etc/hermes-monitoring/
#  2. Kopierar SSH-nyckel för mailcow-server (id_ed25519_mailcow)
#  3. Kopierar SSH-nyckel för web-hosting-prod (id_ed25519)
#  4. Lägger till båda servers i hermes SSH known_hosts
#  5. Installerar mailcow-check.sh och webhosting-check.sh
#  6. Installerar och startar hermes-infra-check.service + .timer

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
MAILCOW_SSH_USER="${MAILCOW_SSH_USER:-deploy}"
MAILCOW_SSH_KEY="${MAILCOW_SSH_KEY:-$HERMES_HOME/.ssh/id_ed25519_mailcow}"
WEBHOSTING_HOST="${WEBHOSTING_HOST:-89.167.90.112}"
WEBHOSTING_SSH_USER="${WEBHOSTING_SSH_USER:-deploy}"
WEBHOSTING_SSH_KEY="${WEBHOSTING_SSH_KEY:-$HERMES_HOME/.ssh/id_ed25519_webhosting}"

# --- 1. Kopiera infra.conf ---
echo "[1/6] Kopierar infra.conf..."
cp "$REPO_ROOT/config/infra.conf" "$CONF_DIR/infra.conf"
chmod 644 "$CONF_DIR/infra.conf"
echo "  $CONF_DIR/infra.conf installerad"

# --- 2 & 3. Kopiera SSH-nycklar ---
echo "[2/6] Kopierar SSH-nyckel för mailcow-server..."
mkdir -p "$HERMES_HOME/.ssh"
chmod 700 "$HERMES_HOME/.ssh"

# Mailcow-nyckel (id_ed25519_mailcow)
find_key() {
    local suffix="$1"
    for candidate in \
        "/home/deploy/.ssh/${suffix}" \
        "/root/.ssh/${suffix}" \
        "$HOME/.ssh/${suffix}"
    do
        [ -f "$candidate" ] && { echo "$candidate"; return; }
    done
    echo ""
}

SRC_MAILCOW=$(find_key "id_ed25519_mailcow")
if [ -z "$SRC_MAILCOW" ]; then
    echo "  Hittade inte ~/.ssh/id_ed25519_mailcow automatiskt."
    read -rp "  Ange sökväg till mailcow-nyckeln: " SRC_MAILCOW
fi
cp "$SRC_MAILCOW" "$MAILCOW_SSH_KEY"
chown hermes:hermes "$MAILCOW_SSH_KEY"
chmod 600 "$MAILCOW_SSH_KEY"
echo "  Mailcow-nyckel kopierad till $MAILCOW_SSH_KEY"

echo "[3/6] Kopierar SSH-nyckel för web-hosting-prod..."
SRC_WEBHOSTING=$(find_key "id_ed25519")
if [ -z "$SRC_WEBHOSTING" ]; then
    echo "  Hittade inte ~/.ssh/id_ed25519 automatiskt."
    read -rp "  Ange sökväg till web-hosting-nyckeln: " SRC_WEBHOSTING
fi
cp "$SRC_WEBHOSTING" "$WEBHOSTING_SSH_KEY"
chown hermes:hermes "$WEBHOSTING_SSH_KEY"
chmod 600 "$WEBHOSTING_SSH_KEY"
echo "  Web-hosting-nyckel kopierad till $WEBHOSTING_SSH_KEY"

# --- 4. known_hosts för båda servers ---
echo "[4/6] Lägger till servers i SSH known_hosts..."
KNOWN_HOSTS="$HERMES_HOME/.ssh/known_hosts"
touch "$KNOWN_HOSTS"
sudo -u hermes ssh-keyscan -T 10 "$MAILCOW_HOST" >> "$KNOWN_HOSTS" 2>/dev/null || true
sudo -u hermes ssh-keyscan -T 10 "$WEBHOSTING_HOST" >> "$KNOWN_HOSTS" 2>/dev/null || true
chown hermes:hermes "$KNOWN_HOSTS"
chmod 600 "$KNOWN_HOSTS"
echo "  $MAILCOW_HOST och $WEBHOSTING_HOST tillagda i known_hosts"

# --- 5. Installera övervakningsskript ---
echo "[5/6] Installerar skript..."
cp "$REPO_ROOT/scripts/hermes/monitoring/mailcow-check.sh" "$LIB_DIR/"
cp "$REPO_ROOT/scripts/hermes/monitoring/webhosting-check.sh" "$LIB_DIR/"
chmod +x "$LIB_DIR/mailcow-check.sh" "$LIB_DIR/webhosting-check.sh"
echo "  mailcow-check.sh och webhosting-check.sh installerade"

# --- 6. Installera systemd-unit och timer ---
echo "[6/6] Installerar systemd-unit..."
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
echo "  • Mailcow-server (${MAILCOW_HOST}) och web-hosting-prod (${WEBHOSTING_HOST})"
echo "    checkas var 10:e minut"
echo "  • Disk/RAM-varning vid ${DISK_WARN_PERCENT:-80}% resp ${MEM_WARN_PERCENT:-85}%"
echo "  • Mailcow-portar (25/465/587/993) kontrolleras utifrhån var 10:e minut"
echo ""
echo "Verifiera med:"
echo "  sudo bash scripts/hermes/phase4-verify.sh"
