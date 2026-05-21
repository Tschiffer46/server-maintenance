#!/usr/bin/env bash
# Verifierar att fas 4 (infrastruktur-övervakning) är korrekt installerad.

set -euo pipefail

PASS=0
FAIL=0

ok()   { echo "  pass: $*"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }
info() { echo "  info: $*"; }

echo "=== Fas 4 verifiering ==="
echo ""

# Ladda in infra.conf
# shellcheck source=/dev/null
[ -f /etc/hermes-monitoring/infra.conf ] && source /etc/hermes-monitoring/infra.conf
WEBHOSTING_HOST="${WEBHOSTING_HOST:-89.167.90.112}"
WEBHOSTING_SSH_KEY="${WEBHOSTING_SSH_KEY:-/home/hermes/.ssh/id_ed25519_webhosting}"

# [1] Konfiguration
echo "[1] Konfiguration"
if [ -f /etc/hermes-monitoring/infra.conf ]; then
    ok "/etc/hermes-monitoring/infra.conf"
else
    fail "/etc/hermes-monitoring/infra.conf saknas"
fi

# [2] Skript
echo ""
echo "[2] Övervakningsskript"
for f in mailcow-check.sh webhosting-check.sh; do
    if [ -x "/usr/local/lib/hermes-monitoring/$f" ]; then
        ok "/usr/local/lib/hermes-monitoring/$f"
    else
        fail "/usr/local/lib/hermes-monitoring/$f saknas eller inte körbar"
    fi
done

# [3] SSH-nyckel
echo ""
echo "[3] SSH-nyckel för web-hosting-prod"
if [ -f "$WEBHOSTING_SSH_KEY" ]; then
    perm=$(stat -c '%a' "$WEBHOSTING_SSH_KEY")
    owner=$(stat -c '%U' "$WEBHOSTING_SSH_KEY")
    if [ "$perm" = "600" ] && [ "$owner" = "hermes" ]; then
        ok "$WEBHOSTING_SSH_KEY (600, ägd av hermes)"
    else
        fail "$WEBHOSTING_SSH_KEY har fel rättigheter: perm=$perm owner=$owner"
    fi
else
    fail "$WEBHOSTING_SSH_KEY saknas"
fi

# known_hosts
if sudo -u hermes grep -q "$WEBHOSTING_HOST" /home/hermes/.ssh/known_hosts 2>/dev/null; then
    ok "$WEBHOSTING_HOST finns i known_hosts"
else
    fail "$WEBHOSTING_HOST saknas i known_hosts"
fi

# [4] Systemd
echo ""
echo "[4] Systemd-units"
for unit in hermes-infra-check.service hermes-infra-check.timer; do
    if [ -f "/etc/systemd/system/${unit}" ]; then
        ok "$unit installerad"
    else
        fail "$unit saknas"
    fi
done

status=$(systemctl is-active hermes-infra-check.timer 2>/dev/null || echo "inactive")
if [ "$status" = "active" ]; then
    next=$(systemctl show hermes-infra-check.timer -p NextElapseUSecRealtime --value 2>/dev/null || echo "okänt")
    ok "hermes-infra-check.timer kör (nästa: $next)"
else
    fail "hermes-infra-check.timer är inte aktiv"
fi

# [5] SSH-anslutning till web-hosting-prod
echo ""
echo "[5] SSH-anslutning till web-hosting-prod"
if sudo -u hermes ssh \
    -i "$WEBHOSTING_SSH_KEY" \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    "${WEBHOSTING_SSH_USER:-deploy}@${WEBHOSTING_HOST}" \
    'echo OK' 2>/dev/null | grep -q 'OK'; then
    ok "SSH till $WEBHOSTING_HOST fungerar"
else
    fail "SSH till $WEBHOSTING_HOST misslyckades"
fi

# [6] Senaste logg
echo ""
echo "[6] Logg"
if grep -q 'mailcow-check\|webhosting-check' /var/log/hermes/monitoring.log 2>/dev/null; then
    last=$(grep -E 'mailcow-check|webhosting-check' /var/log/hermes/monitoring.log | tail -1)
    ok "Infra-logg finns: $last"
else
    info "Inga infra-loggposter än – kör första checken manuellt"
fi

echo ""
echo "--- pass: $PASS  fail: $FAIL ---"
if [ "$FAIL" -eq 0 ]; then
    echo "✔ Fas 4 verifiering OK – infrastruktur-övervakning kör!"
else
    echo "✗ $FAIL kontroller misslyckades."
    exit 1
fi
