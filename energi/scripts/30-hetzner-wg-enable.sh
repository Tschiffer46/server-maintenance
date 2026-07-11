#!/bin/bash
# STEG 3 — Aktivera tunneln på Hetzner-servern. Körs PÅ SERVERN:
#
#   ssh -t deploy@89.167.90.112 'sudo bash /tmp/30-hetzner-wg-enable.sh <ROUTER_PUBKEY>'
#
# <ROUTER_PUBKEY> skrivs ut av 20-openwrt-wg-setup.sh (--apply) på routern.
# Skriver in routerns publika nyckel i confen, startar wg-hem (autostart vid
# boot) och väntar på handskakning.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
source "$SCRIPT_DIR/config.env"

CONF="/etc/wireguard/${WG_IF}.conf"
ROUTER_PUB="${1:-}"

if [[ $EUID -ne 0 ]]; then
  echo "Kör med sudo: sudo bash $0 <ROUTER_PUBKEY>" >&2
  exit 1
fi
if [[ -z "$ROUTER_PUB" || ${#ROUTER_PUB} -ne 44 ]]; then
  echo "Användning: sudo bash $0 <ROUTER_PUBKEY>  (44 tecken base64, från steg 2)" >&2
  exit 1
fi
if [[ ! -f "$CONF" ]]; then
  echo "FEL: $CONF saknas — kör 10-hetzner-wg-setup.sh först." >&2
  exit 1
fi

# Enda "PublicKey ="-raden i confen är peer-sektionens (interfacet har PrivateKey)
sed -i "s|^PublicKey = .*|PublicKey = ${ROUTER_PUB}|" "$CONF"

if systemctl is-active --quiet "wg-quick@${WG_IF}"; then
  wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF")
  echo "Tunneln kör redan — ny peer-nyckel laddad utan avbrott."
else
  systemctl enable --now "wg-quick@${WG_IF}"
  echo "wg-quick@${WG_IF} startad och aktiverad vid boot."
fi

echo "Väntar på handskakning från routern (max 90 s)..."
HANDSHAKE=0
for _ in $(seq 1 30); do
  TS="$(wg show "$WG_IF" latest-handshakes | awk '{print $2}' | head -n1)"
  if [[ -n "$TS" && "$TS" != "0" ]]; then
    HANDSHAKE=1
    break
  fi
  sleep 3
done

echo ""
wg show "$WG_IF"
echo ""
if [[ "$HANDSHAKE" == "1" ]]; then
  echo "✅ Handskakning etablerad!"
  echo "Pingtest mot routerns tunnel-IP:"
  ping -c 3 -W 2 "$WG_ROUTER_IP" && echo "✅ Tunneln fungerar." || echo "⚠️  Handskakning OK men ping svarar inte — kolla brandväggszonen på routern."
else
  echo "❌ Ingen handskakning ännu. Kontrollera:"
  echo "   - Hetzner Cloud Firewall: är UDP ${WG_PORT} öppen där (om en är kopplad)?"
  echo "   - På routern: wg show   (Endpoint rätt? = ${HETZNER_IP}:${WG_PORT})"
  echo "   - Nycklarna: har rätt publik nyckel hamnat på rätt sida?"
fi
