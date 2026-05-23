#!/usr/bin/env bash
# Verifierar fas 5 (uppdateringsövervakning).

set -uo pipefail

pass=0
fail=0
ok()   { echo "  pass: $*"; pass=$(( pass + 1 )); }
nok()  { echo "  FAIL: $*"; fail=$(( fail + 1 )); }

echo "=== Fas 5 verifiering ==="

echo
echo "[1] Skript"
[ -x /usr/local/lib/hermes-monitoring/update-check.sh ] \
    && ok "update-check.sh installerat" \
    || nok "update-check.sh saknas eller inte körbart"

# Verifiera att daily-report känner till update-sektionen
grep -q 'Uppdateringar:' /usr/local/lib/hermes-monitoring/daily-report.sh \
    && ok "daily-report.sh innehåller uppdateringssektion" \
    || nok "daily-report.sh saknar uppdateringssektion (kör phase5-setup-updates.sh)"

echo
echo "[2] Systemd"
systemctl list-unit-files hermes-update-check.service >/dev/null 2>&1 \
    && ok "hermes-update-check.service installerad" \
    || nok "service saknas"
systemctl list-unit-files hermes-update-check.timer >/dev/null 2>&1 \
    && ok "hermes-update-check.timer installerad" \
    || nok "timer saknas"
systemctl is-active --quiet hermes-update-check.timer \
    && ok "hermes-update-check.timer kör" \
    || nok "timer kör inte"

echo
echo "[3] State-filer"
for f in updates.atm-shops.txt updates.mailcow.txt updates.web-hosting.txt updates.mailcow-app.txt; do
    if [ -f "/var/lib/hermes/monitoring/state/$f" ]; then
        ok "state: $f finns"
    else
        nok "state: $f saknas (kanske inte kört än, kör 'sudo systemctl start hermes-update-check.service')"
    fi
done

echo
echo "[4] Automatiska säkerhetspatcher (lokalt, ATM-shops)"
if [ -f /etc/apt/apt.conf.d/20auto-upgrades ] && \
   grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
    ok "unattended-upgrades aktiverat lokalt"
else
    nok "unattended-upgrades inte aktiverat – kör setup-unattended-upgrades.sh"
fi

if [ -f /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf ] && \
   grep -q '05:00:00' /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf 2>/dev/null; then
    ok "apt-daily-upgrade.timer körtid satt till 05:00"
else
    nok "apt-daily-upgrade.timer kör inte 05:00 (kör setup-unattended-upgrades.sh för att åtgärda)"
fi

echo
echo "[5] Logg"
if [ -f /var/log/hermes/monitoring.log ] && \
   grep -q 'update-check' /var/log/hermes/monitoring.log 2>/dev/null; then
    ok "Update-check har skrivit till loggen"
else
    nok "Ingen update-check-rad i loggen ännu"
fi

echo
echo "--- pass: $pass  fail: $fail ---"

if [ "$fail" -gt 0 ]; then
    echo "✘ Fas 5 ej helt klar – kolla felmeddelandena ovan."
    exit 1
else
    echo "✔ Fas 5 verifiering OK!"
fi
