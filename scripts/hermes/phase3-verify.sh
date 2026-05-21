#!/usr/bin/env bash
# Verifierar att fas 3 (site-övervakning) är korrekt installerad.
# Körs som root (sudo) på 77.42.81.134.

set -euo pipefail

PASS=0
FAIL=0

ok()   { echo "  pass: $*"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }
info() { echo "  info: $*"; }

echo "=== Fas 3 verifiering ==="
echo ""

# [1] Skript installerade
echo "[1] Övervakningsskript"
for f in site-check.sh ssl-check.sh daily-report.sh; do
    if [ -x "/usr/local/lib/hermes-monitoring/$f" ]; then
        ok "/usr/local/lib/hermes-monitoring/$f"
    else
        fail "/usr/local/lib/hermes-monitoring/$f saknas eller inte körbar"
    fi
done

# [2] sites.conf
echo ""
echo "[2] Konfiguration"
if [ -f "/etc/hermes-monitoring/sites.conf" ]; then
    count=$(grep -c '^https' /etc/hermes-monitoring/sites.conf 2>/dev/null || echo 0)
    ok "/etc/hermes-monitoring/sites.conf ($count sajter)"
else
    fail "/etc/hermes-monitoring/sites.conf saknas"
fi

# [3] Credentials
if [ -f "/home/hermes/.config/hermes-monitoring/env" ]; then
    perm=$(stat -c '%a' /home/hermes/.config/hermes-monitoring/env)
    if [ "$perm" = "600" ]; then
        ok "credentials-fil finns med korrekt rättigheter (600)"
    else
        fail "credentials-fil har fel rättigheter: $perm (ska vara 600)"
    fi
    token_len=$(sudo -u hermes bash -c 'source ~/.config/hermes-monitoring/env 2>/dev/null; echo ${#TELEGRAM_BOT_TOKEN}' || echo 0)
    if [ "$token_len" -gt 20 ] 2>/dev/null; then
        ok "TELEGRAM_BOT_TOKEN är satt (${token_len} tecken)"
    else
        fail "TELEGRAM_BOT_TOKEN saknas eller verkar tom"
    fi
else
    fail "/home/hermes/.config/hermes-monitoring/env saknas"
fi

# [4] Systemd-units
echo ""
echo "[4] Systemd-units"
for unit in \
    hermes-site-check.service \
    hermes-site-check.timer \
    hermes-ssl-check.service \
    hermes-ssl-check.timer \
    hermes-daily-report.service \
    hermes-daily-report.timer
do
    if [ -f "/etc/systemd/system/${unit}" ]; then
        ok "$unit installerad"
    else
        fail "$unit saknas i /etc/systemd/system/"
    fi
done

# [5] Timers aktiva
echo ""
echo "[5] Timers körs"
for timer in hermes-site-check.timer hermes-ssl-check.timer hermes-daily-report.timer; do
    status=$(systemctl is-active "$timer" 2>/dev/null || echo "inactive")
    if [ "$status" = "active" ]; then
        next=$(systemctl show "$timer" -p NextElapseUSecRealtime --value 2>/dev/null | head -1 || echo "okänt")
        ok "$timer kör (nästa: $next)"
    else
        fail "$timer är inte aktiv (status: $status)"
    fi
done

# [6] Senaste loggpost
echo ""
echo "[6] Logg"
if [ -f "/var/log/hermes/monitoring.log" ]; then
    last=$(tail -1 /var/log/hermes/monitoring.log)
    ok "monitoring.log finns: $last"
else
    info "monitoring.log saknas – körs site-check.sh någon gång än?"
fi

# [7] State-katalog
if [ -d "/var/lib/hermes/monitoring/state" ]; then
    files=$(ls /var/lib/hermes/monitoring/state/ 2>/dev/null | wc -l)
    ok "state-katalog finns ($files tillståndsfiler)"
else
    info "state-katalog saknas – skapas vid första körning"
fi

echo ""
echo "--- pass: $PASS  fail: $FAIL ---"
if [ "$FAIL" -eq 0 ]; then
    echo "✔ Fas 3 verifiering OK – övervakningen kör!"
else
    echo "✗ $FAIL kontroller misslyckades. Kolla felen ovan."
    exit 1
fi
