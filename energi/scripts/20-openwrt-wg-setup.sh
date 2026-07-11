#!/bin/sh
# STEG 2 — WireGuard på OpenWrt-routern. Körs PÅ ROUTERN (BusyBox/ash):
#
#   scp scripts/20-openwrt-wg-setup.sh root@192.168.1.1:/tmp/
#   # Förhandsvisning (ändrar INGENTING):
#   ssh root@192.168.1.1 'sh /tmp/20-openwrt-wg-setup.sh <SERVER_PUBKEY> <PSK>'
#   # Applicera (backup -> uci -> visar ändringar -> kräver JA före commit):
#   ssh -t root@192.168.1.1 'sh /tmp/20-openwrt-wg-setup.sh <SERVER_PUBKEY> <PSK> --apply'
#
# <SERVER_PUBKEY> och <PSK> skrivs ut av 10-hetzner-wg-setup.sh.
#
# Vad som konfigureras:
#   - WireGuard-interface "wghem" (10.8.20.2) som initierar mot Hetzner
#     (routern står bakom NAT; PersistentKeepalive håller tunneln uppe)
#   - Brandväggszon "wghem" med forward=REJECT och ENDAST tre öppningar:
#     TCP 502 -> 192.168.1.202 (Sungrow Modbus), TCP 80 -> 192.168.1.96
#     (Shelly) samt ICMP till de två för felsökning
#   - Masquerade på lan-zonen ENBART för tunnelnätet (masq_src 10.8.20.0/24)
#     så att mätarna ser trafiken som kommande från routern
#
# Återställning: scripts/openwrt-rollback.sh, eller kopiera tillbaka
# /etc/config.pre-energi-wg/ (skapas här före ändring).
#
# OBS: Värdena nedan måste matcha scripts/config.env.
set -eu

HETZNER_IP="89.167.90.112"
WG_PORT="51820"
WG_NET="10.8.20.0/24"
WG_HETZNER_IP="10.8.20.1"
WG_ROUTER_IP="10.8.20.2"
SUNGROW_IP="192.168.1.202"
SUNGROW_PORT="502"
SHELLY_IP="192.168.1.96"
SHELLY_PORT="80"

HETZNER_PUB="${1:-}"
WG_PSK="${2:-}"
MODE="${3:-dry-run}"

usage() {
  echo "Användning: sh $0 <SERVER_PUBKEY> <PSK> [--apply]" >&2
  echo "Utan --apply visas bara vad som skulle göras." >&2
  exit 1
}
[ -n "$HETZNER_PUB" ] || usage
[ -n "$WG_PSK" ] || usage
if [ ${#HETZNER_PUB} -ne 44 ]; then
  echo "FEL: servernyckeln ser inte ut som en WireGuard-nyckel (44 tecken base64)." >&2
  exit 1
fi

# Hitta lan-zonens sektionsnamn i brandväggskonfigen
LAN_SEC="$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='lan'\$/\1/p" | head -n1)"
if [ -z "$LAN_SEC" ]; then
  echo "FEL: hittar ingen brandväggszon med name='lan'. Avbryter." >&2
  exit 1
fi

CMDS=/tmp/energi-wg-uci.sh
cat > "$CMDS" <<EOF
# --- Genererat av 20-openwrt-wg-setup.sh $(date) ---
# \$ROUTER_PRIV och \$WG_PSK skickas in som miljövariabler vid körning
# (skrivs aldrig till den här filen).

# WireGuard-interface
uci set network.wghem=interface
uci set network.wghem.proto='wireguard'
uci set network.wghem.private_key="\$ROUTER_PRIV"
uci add_list network.wghem.addresses='${WG_ROUTER_IP}/24'

# Peer: Hetzner-servern. allowed_ips = endast serverns tunnel-IP, så
# routern skickar aldrig annan trafik in i tunneln.
uci set network.hetzner_energi=wireguard_wghem
uci set network.hetzner_energi.description='Energi-tunnel till Hetzner'
uci set network.hetzner_energi.public_key='${HETZNER_PUB}'
uci set network.hetzner_energi.preshared_key="\$WG_PSK"
uci set network.hetzner_energi.endpoint_host='${HETZNER_IP}'
uci set network.hetzner_energi.endpoint_port='${WG_PORT}'
uci set network.hetzner_energi.persistent_keepalive='25'
uci set network.hetzner_energi.route_allowed_ips='1'
uci add_list network.hetzner_energi.allowed_ips='${WG_HETZNER_IP}/32'

# Brandväggszon för tunneln: allt förbjudet som standard
uci set firewall.wghem=zone
uci set firewall.wghem.name='wghem'
uci add_list firewall.wghem.network='wghem'
uci set firewall.wghem.input='REJECT'
uci set firewall.wghem.output='ACCEPT'
uci set firewall.wghem.forward='REJECT'

# Tillåt ping mot routerns tunnel-IP (felsökning/verifiering)
uci set firewall.wghem_ping_router=rule
uci set firewall.wghem_ping_router.name='wghem-ping-router'
uci set firewall.wghem_ping_router.src='wghem'
uci set firewall.wghem_ping_router.proto='icmp'
uci set firewall.wghem_ping_router.target='ACCEPT'

# ENDA öppningarna in mot hemmanätet: Sungrow Modbus + Shelly HTTP
uci set firewall.wghem_sungrow=rule
uci set firewall.wghem_sungrow.name='wghem-Sungrow-Modbus'
uci set firewall.wghem_sungrow.src='wghem'
uci set firewall.wghem_sungrow.dest='lan'
uci set firewall.wghem_sungrow.dest_ip='${SUNGROW_IP}'
uci set firewall.wghem_sungrow.dest_port='${SUNGROW_PORT}'
uci set firewall.wghem_sungrow.proto='tcp'
uci set firewall.wghem_sungrow.target='ACCEPT'

uci set firewall.wghem_shelly=rule
uci set firewall.wghem_shelly.name='wghem-Shelly-HTTP'
uci set firewall.wghem_shelly.src='wghem'
uci set firewall.wghem_shelly.dest='lan'
uci set firewall.wghem_shelly.dest_ip='${SHELLY_IP}'
uci set firewall.wghem_shelly.dest_port='${SHELLY_PORT}'
uci set firewall.wghem_shelly.proto='tcp'
uci set firewall.wghem_shelly.target='ACCEPT'

# Ping till de två mätarna (felsökning)
uci set firewall.wghem_lan_ping=rule
uci set firewall.wghem_lan_ping.name='wghem-ping-matare'
uci set firewall.wghem_lan_ping.src='wghem'
uci set firewall.wghem_lan_ping.dest='lan'
uci add_list firewall.wghem_lan_ping.dest_ip='${SUNGROW_IP}'
uci add_list firewall.wghem_lan_ping.dest_ip='${SHELLY_IP}'
uci set firewall.wghem_lan_ping.proto='icmp'
uci set firewall.wghem_lan_ping.target='ACCEPT'

# NAT:a ENBART tunneltrafik ut mot lan (masq_src begränsar till ${WG_NET}),
# så mätarna svarar routern och vanlig LAN-trafik påverkas inte alls.
uci set firewall.${LAN_SEC}.masq='1'
uci add_list firewall.${LAN_SEC}.masq_src='${WG_NET}'
EOF

echo "================================================================"
echo " Följande uci-kommandon kommer att köras (lan-zon: ${LAN_SEC}):"
echo "================================================================"
cat "$CMDS"
echo "================================================================"

if [ "$MODE" != "--apply" ]; then
  echo ""
  echo "FÖRHANDSVISNING — inget har ändrats."
  echo "Kör igen med --apply som tredje argument för att applicera."
  exit 0
fi

echo ""
echo "[1/6] Säkerhetskopierar..."
BK="/tmp/energi-pre-wg-$(date +%Y%m%d-%H%M%S).tar.gz"
sysupgrade -b "$BK"
echo "  Full backup: $BK  (hämta hem: scp root@192.168.1.1:$BK .)"
if [ ! -d /etc/config.pre-energi-wg ]; then
  mkdir -p /etc/config.pre-energi-wg
  cp -a /etc/config/. /etc/config.pre-energi-wg/
  echo "  Orörd kopia av /etc/config -> /etc/config.pre-energi-wg/"
fi

echo "[2/6] Installerar WireGuard-paket (om de saknas)..."
if ! opkg list-installed 2>/dev/null | grep -q '^wireguard-tools '; then
  opkg update
  opkg install kmod-wireguard wireguard-tools luci-proto-wireguard
else
  echo "  Redan installerat."
fi

echo "[3/6] Genererar routerns nyckelpar..."
umask 077
ROUTER_PRIV="$(wg genkey)"
ROUTER_PUB="$(printf '%s' "$ROUTER_PRIV" | wg pubkey)"

echo "[4/6] Kör uci-kommandona..."
ROUTER_PRIV="$ROUTER_PRIV" WG_PSK="$WG_PSK" sh "$CMDS"

echo ""
echo "================================================================"
echo " Ännu INTE sparat. Så här blir ändringarna (uci changes):"
echo "================================================================"
uci changes network
uci changes firewall
echo "================================================================"
printf 'Spara och aktivera? Skriv JA: '
read -r ANSWER
if [ "$ANSWER" != "JA" ]; then
  uci revert network
  uci revert firewall
  echo "Avbrutet — alla ändringar bortkastade, inget sparat."
  exit 1
fi

echo "[5/6] Sparar och aktiverar..."
uci commit network
uci commit firewall
ifup wghem
/etc/init.d/firewall reload

echo "[6/6] Status:"
sleep 3
wg show

echo ""
echo "================================================================"
echo " ROUTERNS PUBLIKA NYCKEL (argument till steg 3 på Hetzner):"
echo "   ${ROUTER_PUB}"
echo ""
echo " Handskakningen syns först när steg 3 är kört på servern."
echo " Ångra allt: sh /tmp/openwrt-rollback.sh"
echo "================================================================"
rm -f "$CMDS"
