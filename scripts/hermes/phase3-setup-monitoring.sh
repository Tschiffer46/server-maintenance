#!/usr/bin/env bash
# Fas 3 – installera Hermes site/SSL/dagligövervakning.
# Körs som root (sudo) på 77.42.81.134.
#
# Vad skriptet gör:
#  1. Skapar kataloger för state, loggar och konfiguration
#  2. Kopierar övervakningsskript till /usr/local/lib/hermes-monitoring/
#  3. Kopierar sites.conf till /etc/hermes-monitoring/
#  4. Hämtar Telegram-credentials från Hermes-konfigurationen
#     (om de inte hittas automatiskt får du ange dem manuellt)
#  5. Installerar systemd-units och timers
#  6. Aktiverar och startar alla tre timers

set -euo pipefail

# Hitta repo-roten (skriptet ligger i scripts/hermes/)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

LIB_DIR="/usr/local/lib/hermes-monitoring"
CONF_DIR="/etc/hermes-monitoring"
STATE_DIR="/var/lib/hermes/monitoring/state"
LOG_DIR="/var/log/hermes"
HERMES_HOME="/home/hermes"
CREDENTIALS_FILE="${HERMES_HOME}/.config/hermes-monitoring/env"

echo "=== Fas 3: Site-övervakning ==="
echo ""

if [ "$(id -u)" -ne 0 ]; then
    echo "FEL: Kör med sudo: sudo bash $0"
    exit 1
fi

# --- 1. Skapa kataloger ---
echo "[1/6] Skapar kataloger..."
mkdir -p "$LIB_DIR" "$CONF_DIR" "$STATE_DIR" "$LOG_DIR"
chown hermes:hermes "$STATE_DIR" "$LOG_DIR"
chmod 750 "$STATE_DIR"

# --- 2. Kopiera övervakningsskript ---
echo "[2/6] Installerar övervakningsskript..."
cp "$REPO_ROOT/scripts/hermes/monitoring/site-check.sh" "$LIB_DIR/"
cp "$REPO_ROOT/scripts/hermes/monitoring/ssl-check.sh" "$LIB_DIR/"
cp "$REPO_ROOT/scripts/hermes/monitoring/daily-report.sh" "$LIB_DIR/"
chmod +x "$LIB_DIR/"*.sh
echo "  Skript installerade i $LIB_DIR"

# --- 3. Kopiera sites.conf ---
echo "[3/6] Kopierar sites.conf..."
cp "$REPO_ROOT/config/sites.conf" "$CONF_DIR/sites.conf"
chmod 644 "$CONF_DIR/sites.conf"
echo "  $CONF_DIR/sites.conf installerad ($(grep -c '^https' "$CONF_DIR/sites.conf") sajter)"

# --- 4. Hämta Telegram-credentials ---
echo "[4/6] Hämtar Telegram-credentials..."

BOT_TOKEN=""
CHAT_ID=""

# Försök hämta från Hermes-konfigurationen
for cfg in \
    "${HERMES_HOME}/.hermes/config.toml" \
    "${HERMES_HOME}/.hermes/config.json" \
    "${HERMES_HOME}/.config/hermes/config.toml" \
    "${HERMES_HOME}/.config/hermes/config.json"
do
    if [ -f "$cfg" ]; then
        if [[ "$cfg" == *.toml ]]; then
            BOT_TOKEN=$(grep -E 'bot_token|token' "$cfg" 2>/dev/null | head -1 | sed "s/.*=\s*['\"]\?//;s/['\"]\?\s*$//" || true)
            CHAT_ID=$(grep -E 'chat_id|chatId' "$cfg" 2>/dev/null | head -1 | sed "s/.*=\s*['\"]\?//;s/['\"]\?\s*$//" || true)
        elif [[ "$cfg" == *.json ]]; then
            if command -v jq &>/dev/null; then
                BOT_TOKEN=$(jq -r '.telegram.bot_token // .telegram.token // empty' "$cfg" 2>/dev/null || true)
                CHAT_ID=$(jq -r '.telegram.chat_id // .telegram.chatId // empty' "$cfg" 2>/dev/null || true)
            fi
        fi
        [ -n "$BOT_TOKEN" ] && echo "  Bot-token hittad i $cfg" && break
    fi
done

# Om de inte hittades automatiskt – fråga användaren
if [ -z "$BOT_TOKEN" ]; then
    echo ""
    echo "  Kunde inte hitta Telegram-credentials automatiskt."
    echo "  Hämta bot-token med: sudo -u hermes cat ~/.hermes/config.toml"
    echo "  (eller fråga Hermes i Telegram: skriv /config telegram)"
    echo ""
    read -rp "  Klistra in bot-token: " BOT_TOKEN
fi

if [ -z "$CHAT_ID" ]; then
    echo ""
    echo "  Chat-ID hittas i Telegram genom att skriva /start till boten."
    echo "  Ditt Telegram-användar-ID är normalt ditt chat-ID för direktmeddelanden."
    read -rp "  Klistra in chat-ID: " CHAT_ID
fi

# Spara credentials
mkdir -p "${HERMES_HOME}/.config/hermes-monitoring"
cat > "$CREDENTIALS_FILE" << EOF
TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
TELEGRAM_CHAT_ID=${CHAT_ID}
EOF
chown -R hermes:hermes "${HERMES_HOME}/.config/hermes-monitoring"
chmod 600 "$CREDENTIALS_FILE"
echo "  Credentials sparade i $CREDENTIALS_FILE (läsbar bara av hermes-användaren)"

# --- 5. Installera systemd-units ---
echo "[5/6] Installerar systemd-units..."
for unit in \
    hermes-site-check.service \
    hermes-site-check.timer \
    hermes-ssl-check.service \
    hermes-ssl-check.timer \
    hermes-daily-report.service \
    hermes-daily-report.timer
do
    cp "$REPO_ROOT/systemd/${unit}" "/etc/systemd/system/${unit}"
    echo "  Installerade /etc/systemd/system/${unit}"
done
systemctl daemon-reload

# --- 6. Aktivera och starta timers ---
echo "[6/6] Aktiverar och startar timers..."
for timer in hermes-site-check.timer hermes-ssl-check.timer hermes-daily-report.timer; do
    systemctl enable "$timer"
    systemctl start "$timer"
    echo "  $timer aktiverad och startad"
done

# Kör en första site-check direkt för att verifiera att det fungerar
echo ""
echo "Kör första site-check nu..."
sudo -u hermes TELEGRAM_BOT_TOKEN="$BOT_TOKEN" TELEGRAM_CHAT_ID="$CHAT_ID" \
    bash "$LIB_DIR/site-check.sh" 2>&1 | tail -5 || true

echo ""
echo "✔ Fas 3 klar!"
echo ""
echo "Vad händer nu:"
echo "  • Site-check körs var 5:e minut"
echo "  • SSL/DNS-check körs var 6:e timme"
echo "  • Daglig rapport skickas kl 08:00"
echo ""
echo "Verifiera med:"
echo "  sudo bash scripts/hermes/phase3-verify.sh"
