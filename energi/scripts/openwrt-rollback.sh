#!/bin/sh
# NÖDBROMS — tar bort allt som 20-openwrt-wg-setup.sh lade till på routern.
#
#   scp scripts/openwrt-rollback.sh root@192.168.1.1:/tmp/
#   ssh root@192.168.1.1 'sh /tmp/openwrt-rollback.sh'
#
# Garanterad total återställning finns dessutom alltid i:
#   /etc/config.pre-energi-wg/   (kopiera tillbaka till /etc/config/ + reboot)
#   /tmp/energi-pre-wg-*.tar.gz  (sysupgrade-backup, överlever INTE reboot — hämta hem den!)
set -eu

WG_NET="10.8.20.0/24"

LAN_SEC="$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='lan'\$/\1/p" | head -n1)"

uci -q delete network.wghem || true
uci -q delete network.hetzner_energi || true
uci -q delete firewall.wghem || true
uci -q delete firewall.wghem_ping_router || true
uci -q delete firewall.wghem_sungrow || true
uci -q delete firewall.wghem_shelly || true
uci -q delete firewall.wghem_lan_ping || true

if [ -n "$LAN_SEC" ]; then
  uci -q del_list firewall."$LAN_SEC".masq_src="$WG_NET" || true
  # masq slogs på av setup-scriptet enbart för tunnelnätet — stäng av igen
  # om ingen annan masq_src finns kvar på lan-zonen
  if ! uci -q get firewall."$LAN_SEC".masq_src >/dev/null 2>&1; then
    uci -q delete firewall."$LAN_SEC".masq || true
  fi
fi

uci commit network
uci commit firewall
/etc/init.d/network reload
/etc/init.d/firewall reload

echo "Klart — wghem-interface, zon, regler och masquerade borttagna."
echo "Kontrollera: uci show network | grep -i wg ; uci show firewall | grep -i wghem"
