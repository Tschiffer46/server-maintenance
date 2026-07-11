#!/bin/bash
# STEG 1 — WireGuard på Hetzner-servern. Körs PÅ SERVERN:
#
#   scp scripts/10-hetzner-wg-setup.sh scripts/config.env deploy@89.167.90.112:/tmp/
#   ssh -t deploy@89.167.90.112 'sudo bash /tmp/10-hetzner-wg-setup.sh'
#
# Skapar det isolerade interfacet wg-hem (rör ingen annan trafik), genererar
# nycklar + PSK och öppnar UDP-porten i UFW. Tunneln STARTAS INTE här —
# routerns publika nyckel saknas ännu. Den skrivs in av 30-hetzner-wg-enable.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
source "$SCRIPT_DIR/config.env"

CONF="/etc/wireguard/${WG_IF}.conf"

if [[ $EUID -ne 0 ]]; then
  echo "Kör med sudo: sudo bash $0" >&2
  exit 1
fi

if [[ -f "$CONF" && "${1:-}" != "--force" ]]; then
  echo "$CONF finns redan. Kör med --force för att skriva över (genererar NYA nycklar!)." >&2
  exit 1
fi

# Förkontroller: är UDP-porten ledig och tunnelnätet oanvänt?
if ss -ulpn | grep -q ":${WG_PORT} "; then
  echo "FEL: UDP-port ${WG_PORT} används redan (se 'ss -ulpn'). Byt WG_PORT i config.env." >&2
  exit 1
fi
WG_NET_PREFIX="${WG_NET%.*}"   # "10.8.20.0/24" -> "10.8.20"
if ip route | grep -qF "$WG_NET_PREFIX"; then
  echo "FEL: ${WG_NET} verkar redan användas (se 'ip route'). Byt WG_NET i config.env." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard

umask 077
SERVER_PRIV="$(wg genkey)"
SERVER_PUB="$(printf '%s' "$SERVER_PRIV" | wg pubkey)"
PSK="$(wg genpsk)"

cat > "$CONF" <<EOF
[Interface]
# Energi-tunnel till hemmanätet (OpenWrt-routern). Isolerat interface —
# påverkar ingen annan trafik eller routing på servern.
Address = ${WG_HETZNER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}

[Peer]
# OpenWrt-routern hemma. Ingen Endpoint här — routern står bakom NAT och
# initierar anslutningen själv (PersistentKeepalive på routersidan).
# AllowedIPs är avsiktligt snäv: servern kan BARA nå routerns tunnel-IP,
# växelriktaren och Shellyn — inget annat på hemmanätet.
PublicKey = ROUTER_PUBLIC_KEY_PLACEHOLDER
PresharedKey = ${PSK}
AllowedIPs = ${WG_ROUTER_IP}/32, ${SUNGROW_IP}/32, ${SHELLY_IP}/32
EOF
chmod 600 "$CONF"

ufw allow "${WG_PORT}/udp" comment 'WireGuard energi-tunnel'

echo ""
echo "================================================================"
echo " Serversidan klar (tunneln aktiveras först i steg 3)."
echo ""
echo " SERVERNS PUBLIKA NYCKEL (argument 1 till steg 2 på routern):"
echo "   ${SERVER_PUB}"
echo ""
echo " DELAD HEMLIGHET / PSK (argument 2 till steg 2 på routern):"
echo "   ${PSK}"
echo ""
echo " OBS: Har servern en Hetzner Cloud Firewall kopplad (Hetzner"
echo " Console -> Firewalls) måste UDP ${WG_PORT} öppnas ÄVEN där."
echo " UFW på servern är redan öppnad."
echo "================================================================"
