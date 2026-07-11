#!/bin/bash
# STEG 4 — Testa tunneln från Hetzner-servern. Körs PÅ SERVERN (utan sudo):
#
#   bash /tmp/40-test-tunnel.sh
#
# Verifierar att EXAKT rätt saker är nåbara genom tunneln:
#   ✅ ping routerns tunnel-IP        ✅ Sungrow Modbus (TCP 502)
#   ✅ Shelly HTTP (/shelly)          ✅ ...och att övriga hemmanätet INTE nås
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
source "$SCRIPT_DIR/config.env"

FAIL=0

# TCP-test utan att kräva nc (bash /dev/tcp finns alltid)
check_tcp() {
  timeout 5 bash -c "cat < /dev/null > /dev/tcp/$1/$2" 2>/dev/null
}

echo "== 1) Ping mot routerns tunnel-IP (${WG_ROUTER_IP}) =="
if ping -c 3 -W 2 "$WG_ROUTER_IP" > /dev/null 2>&1; then
  echo "✅ Routern svarar genom tunneln."
else
  echo "❌ Ingen kontakt med routern — kör 'sudo wg show ${WG_IF}' och kolla handskakningen."
  FAIL=1
fi

echo ""
echo "== 2) Sungrow Modbus TCP (${SUNGROW_IP}:${SUNGROW_PORT}) =="
if check_tcp "$SUNGROW_IP" "$SUNGROW_PORT"; then
  echo "✅ Modbus-porten öppen genom tunneln."
else
  echo "❌ Når inte växelriktaren — kolla brandväggsregeln wghem-Sungrow-Modbus på routern."
  FAIL=1
fi

echo ""
echo "== 3) Shelly Pro 3EM HTTP (http://${SHELLY_IP}/shelly) =="
SHELLY_JSON="$(curl -s -m 5 "http://${SHELLY_IP}/shelly" || true)"
if [[ -n "$SHELLY_JSON" ]]; then
  echo "✅ Shellyn svarar:"
  echo "$SHELLY_JSON" | python3 -m json.tool 2>/dev/null || echo "$SHELLY_JSON"
else
  echo "❌ Inget svar från Shellyn — kolla brandväggsregeln wghem-Shelly-HTTP på routern."
  FAIL=1
fi

echo ""
echo "== 4) Isolering: resten av hemmanätet ska INTE vara nåbart =="
if check_tcp "192.168.1.1" "80"; then
  echo "⚠️  192.168.1.1:80 svarade — tunneln är öppnare än tänkt (kolla AllowedIPs i ${WG_IF}.conf)."
  FAIL=1
else
  echo "✅ 192.168.1.1 är inte nåbar — endast mätarna släpps igenom, precis som tänkt."
fi

echo ""
if [[ "$FAIL" == "0" ]]; then
  echo "🎉 Alla tunneltester gröna — dags för steg 5 (flytta appen)."
else
  echo "Minst ett test föll — åtgärda innan du går vidare."
  exit 1
fi
