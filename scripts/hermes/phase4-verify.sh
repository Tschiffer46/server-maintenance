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

# shellcheck source=/dev/null
[ -f /etc/hermes-monitoring/infra.conf ] && source /etc/hermes-monitoring/infra.conf
MAILCOW_HOST="${MAILCOW_HOST:-204.168.157.75}"
MAILCOW_SSH_KEY="${MAILCOW_SSH_KEY:-/home/hermes/.ssh/id_ed25519_mailcow}"
MAILCOW_SSH_USER="${MAILCOW_SSH_USER:-deploy}"
WEBHOSTING_HOST="${WEBHOSTING_HOST:-89.167.90.112}"
WEBHOSTING_SSH_KEY="${WEBHOSTING_SSH_KEY:-/home/hermes/.ssh/id_ed25519_webhosting}"
WEBHOSTING_SSH_USER="${WEBHOSTING_SSH_USER:-deploy}"

# [1] Konfiguration
echo "[1] Konfiguration"
if [ -f /etc/hermes-monitoring/infra.conf ]; then
    ok "/etc/hermes-monitoring/infra.conf (MAILCOW_HOST=$MAILCOW_HOST)"
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
        fail "/usr/local/lib/hermes-monitoring/$f saknas"
    fi
done

# [3] SSH-nycklar
echo ""
echo "[3] SSH-nycklar"
for key_info in "$MAILCOW_SSH_KEY:mailcow" "$WEBHOSTING_SSH_KEY:web-hosting"; do
    key_path="${key_info%%:*}"
    key_name="${key_info##*:}"
    if [ -f "$key_path" ]; then
        perm=$(stat -c '%a' "$key_path")
        owner=$(stat -c '%U' "$key_path")
        if [ "$perm" = "600" ] && [ "$owner" = "hermes" ]; then
            ok "$key_name: $key_path (600, hermes)"
        else
            fail "$key_name: $key_path har fel rättigheter perm=$perm owner=$owner"
        fi
    else
        fail "$key_name: $key_path saknas"
    fi
done

for host in "$MAILCOW_HOST" "$WEBHOSTING_HOST"; do
    if sudo -u hermes grep -q "$host" /home/hermes/.ssh/known_hosts 2>/dev/null; then
        ok "$host finns i known_hosts"
    else
        fail "$host saknas i known_hosts"
    fi
done

# [4] Systemd
echo ""
echo "[4] Systemd"
for unit in hermes-infra-check.service hermes-infra-check.timer; do
    if [ -f "/etc/systemd/system/${unit}" ]; then
        ok "$unit installerad"
    else
        fail "$unit saknas"
    fi
done

status=$(systemctl is-active hermes-infra-check.timer 2>/dev/null || echo "inactive")
if [ "$status" = "active" ]; then
    ok "hermes-infra-check.timer kör"
else
    fail "hermes-infra-check.timer är inte aktiv (status: $status)"
fi

# [5] SSH-anslutningar
echo ""
echo "[5] SSH-anslutningar (testas nu)"
for info in "${MAILCOW_SSH_USER}@${MAILCOW_HOST}:${MAILCOW_SSH_KEY}:mailcow" \
            "${WEBHOSTING_SSH_USER}@${WEBHOSTING_HOST}:${WEBHOSTING_SSH_KEY}:web-hosting"
do
    user_host="${info%%:*}"; rest="${info#*:}"
    key="${rest%%:*}"; label="${rest##*:}"
    if sudo -u hermes ssh \
        -i "$key" \
        -o BatchMode=yes \
        -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=accept-new \
        "$user_host" 'echo OK' 2>/dev/null | grep -q 'OK'; then
        ok "SSH till $label ($user_host) fungerar"
    else
        fail "SSH till $label ($user_host) misslyckades"
    fi
done

# [6] Logg
echo ""
echo "[6] Logg"
if grep -q 'mailcow-check\|webhosting-check' /var/log/hermes/monitoring.log 2>/dev/null; then
    last=$(grep -E 'mailcow-check|webhosting-check' /var/log/hermes/monitoring.log | tail -1)
    ok "Infra-logg: $last"
else
    info "Inga infra-loggposter än"
fi

echo ""
echo "--- pass: $PASS  fail: $FAIL ---"
if [ "$FAIL" -eq 0 ]; then
    echo "✔ Fas 4 verifiering OK!"
else
    echo "✗ $FAIL kontroller misslyckades."
    exit 1
fi
