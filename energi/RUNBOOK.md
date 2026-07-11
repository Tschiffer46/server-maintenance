# RUNBOOK — flytta energidashboarden till Hetzner

Kör stegen i ordning och gå inte vidare förrän stegets ✅-kontroll är grön.
Allt är förberett för **89.167.90.112** och **energi.agiletransition.se** —
stämmer inte det: ändra i `scripts/config.env` (och motsvarande variabler i
toppen av `scripts/20-openwrt-wg-setup.sh`, som är självbärande för routern).

**Förutsättningar** (allt körs från Macen, hemma på ditt WiFi):

- `ssh deploy@89.167.90.112` fungerar (och `deploy` har sudo)
- `ssh root@192.168.1.1` fungerar (OpenWrt)
- Detta repo klonat på Macen: `git clone https://github.com/Tschiffer46/energi && cd energi`

**Rör aldrig:** växelriktarens/WiNet-donglens eller Shellyns konfiguration —
allt är endast läsning. Ingen del av något steg loggar in på mätarna.

---

## Steg 1 — WireGuard på Hetzner-servern

```bash
scp scripts/10-hetzner-wg-setup.sh scripts/config.env deploy@89.167.90.112:/tmp/
ssh -t deploy@89.167.90.112 'sudo bash /tmp/10-hetzner-wg-setup.sh'
```

Scriptet skapar det isolerade interfacet `wg-hem`, öppnar UDP 51820 i UFW och
skriver ut **serverns publika nyckel** och **PSK** — spara båda till steg 2.
Tunneln startas inte än.

✅ **Verifiera:** utskriften slutar med nyckel + PSK utan felmeddelanden.
⚠️ Om servern har en **Hetzner Cloud Firewall** kopplad (Hetzner Console →
Firewalls): öppna UDP 51820 även där innan du går vidare.

## Steg 2 — OpenWrt-routern (STOPP-GRIND: förhandsvisning först)

Backup + förhandsvisning är inbyggt: utan `--apply` ändras **ingenting**, och
även med `--apply` visas alla ändringar (`uci changes`) och du måste skriva
`JA` innan något sparas. Full backup (`sysupgrade -b` + kopia av `/etc/config`)
tas automatiskt före ändring.

```bash
scp scripts/20-openwrt-wg-setup.sh scripts/openwrt-rollback.sh root@192.168.1.1:/tmp/

# 2a. FÖRHANDSVISNING — läs igenom exakt vad som kommer köras:
ssh root@192.168.1.1 'sh /tmp/20-openwrt-wg-setup.sh <SERVER_PUBKEY> <PSK>'

# 2b. Applicera (svara JA på kontrollfrågan när ändringarna ser rätt ut):
ssh -t root@192.168.1.1 'sh /tmp/20-openwrt-wg-setup.sh <SERVER_PUBKEY> <PSK> --apply'

# 2c. Hämta hem router-backupen (överlever inte en router-reboot i /tmp):
scp "root@192.168.1.1:/tmp/energi-pre-wg-*.tar.gz" ~/Desktop/
```

Det som konfigureras: WG-interface `wghem` (10.8.20.2 → servern, keepalive 25 s),
brandväggszon med **endast** TCP 502→192.168.1.202, TCP 80→192.168.1.96 och
ICMP till dessa, samt masquerade enbart för tunnelnätet. Scriptet skriver ut
**routerns publika nyckel** — spara till steg 3.

✅ **Verifiera:** `ssh root@192.168.1.1 wg show` visar interface `wghem` med
peer och `endpoint 89.167.90.112:51820` (handskakning kommer först efter steg 3).
🔙 **Ångra:** `ssh root@192.168.1.1 'sh /tmp/openwrt-rollback.sh'`

## Steg 3 — Aktivera tunneln på Hetzner

```bash
scp scripts/30-hetzner-wg-enable.sh deploy@89.167.90.112:/tmp/
ssh -t deploy@89.167.90.112 'sudo bash /tmp/30-hetzner-wg-enable.sh <ROUTER_PUBKEY>'
```

✅ **Verifiera:** scriptet väntar in handskakningen och pingar 10.8.20.2 —
båda ska bli ✅. (`latest handshake` under 2 min = tunneln lever.)

## Steg 4 — Testa tunneln

```bash
scp scripts/40-test-tunnel.sh deploy@89.167.90.112:/tmp/
ssh deploy@89.167.90.112 'bash /tmp/40-test-tunnel.sh'
```

✅ **Verifiera:** alla fyra testerna gröna — ping router, Modbus-port öppen,
Shellyn svarar med JSON, och 192.168.1.1 är **inte** nåbar (isoleringen håller).

## Steg 5 — Flytta appen och databasen (körs på Macen)

Detta stoppar och avaktiverar Mac-appen permanent (launchd `unload -w`) **före**
kopieringen, så att inga skrivningar tappas — därefter checkpointas och
integritetskontrolleras databasen, allt kopieras, och checksumman jämförs.

```bash
bash scripts/50-migrate-from-mac.sh
```

✅ **Verifiera:** scriptet slutar med "Checksumman stämmer".
OBS: Sungrow-donglar brukar bara tåla en Modbus-klient åt gången — därför
måste Mac-appen vara stoppad (sker automatiskt här) innan containern startas.

## Steg 6 — Bygg och starta containern

```bash
ssh deploy@89.167.90.112
bash /home/deploy/hosting/energi/scripts/60-deploy.sh
```

Containern: `python:3.12-slim`, `TZ=Europe/Stockholm` (elprisdygnen!),
`restart: always`, `./app` monterad som volym (databasen överlever ombyggen),
endast `127.0.0.1:8420` publicerat på servern, ansluten till NPM:s dockernät.

✅ **Verifiera:** "Containern är healthy", `/api/now` svarar lokalt **och**
från NPM-containern.

## Steg 7 — DNS + NPM-proxy + inloggningsskydd

1. **DNS:** lägg en A-post `energi.agiletransition.se → 89.167.90.112` hos din
   DNS-leverantör. Ligger zonen i Cloudflare: välj **DNS only** (grått moln).
2. **NPM-admin** (port 81 är brandväggad — SSH-tunnel enligt server-maintenance):
   ```bash
   ssh -L 8081:localhost:81 deploy@89.167.90.112   # öppna sedan http://localhost:8081
   ```
3. **Access List** (skyddet): Access Lists → Add — namn `energi`,
   fliken *Authorization*: lägg upp användare + lösenord, bocka i **Satisfy Any**.
4. **Proxy Host:** Hosts → Proxy Hosts → Add:
   - *Details:* Domain `energi.agiletransition.se` · Scheme `http` ·
     Forward Hostname `energi` · Forward Port `8420` ·
     **Block Common Exploits** ✔ · **Access List: energi**
   - *SSL:* Request a new SSL Certificate (Let's Encrypt) · **Force SSL** ✔ ·
     HTTP/2 ✔
   (Let's Encrypt-utfärdandet påverkas inte av access-listan — NPM undantar
   challenge-sökvägen automatiskt.)
5. **Slutverifiering på servern** (tar ~6 min — kontrollerar auth, färsk data
   och att en ny mätpunkt skrivs):
   ```bash
   ssh deploy@89.167.90.112
   ENERGI_AUTH="användare:lösenord" bash /home/deploy/hosting/energi/scripts/70-verify.sh
   ```

✅ **Verifiera:** 70-verify helt grönt **plus** det viktigaste testet: öppna
`https://energi.agiletransition.se` i mobilen på **mobilnät** (WiFi av) —
inloggningsruta → dashboarden laddar med färska värden.

## Steg 8 — Städa Macen + efterarbete

Launchd-jobbet avaktiverades redan i steg 5 (`unload -w` överlever omstart).
När allt varit grönt några dagar:

```bash
mkdir -p ~/energi-retired
PLIST=$(grep -l -i energi ~/Library/LaunchAgents/*.plist 2>/dev/null); [ -n "$PLIST" ] && mv $PLIST ~/energi-retired/
mv ~/energi ~/energi-retired/energi        # behåll som kall backup ett tag
rm -rf ~/energi-venv                       # venv:en behövs aldrig mer
```

Efterarbete:

- **Backup:** merga PR:en i `server-maintenance` — då ingår `energi.db` i den
  dagliga backuprutinen (SQLite `.backup` via containern, 14 dagars rotation)
  och sajten i hälsokollen.
- **Koden i git:** lägg gärna in appfilerna i det här repot:
  ```bash
  cp ~/energi-retired/energi/app.py ~/energi-retired/energi/index.html deploy/app/
  git add deploy/app/app.py deploy/app/index.html && git commit -m "Add app source" && git push
  ```
  (databasen git-ignoreras — den ska aldrig ligga i git)

---

## Felsökning

| Symptom | Trolig orsak → åtgärd |
|---------|----------------------|
| Ingen handskakning (steg 3) | UDP 51820 stängd i Hetzner Cloud Firewall; fel endpoint på routern; pub-nycklarna förväxlade (vanligast!) |
| Handskakning men ping tyst | Brandväggszonen på routern — kolla `wghem-ping-router`-regeln: `uci show firewall \| grep wghem` |
| Modbus/Shelly nås inte (steg 4) | Forward-reglerna på routern; testa från routern själv: `nc -z 192.168.1.202 502` |
| NPM ger 502 | Containern inte på NPM-nätet — `docker network inspect <nät>`; kör om 60-deploy |
| API svarar men inga nya mätpunkter | Pollern startades inte (uvicorn-CLI vs `__main__`) — se instruktionen i 70-verify-utskriften |
| Sungrow svarar nyckfullt | Två Modbus-klienter samtidigt — säkerställ att Mac-appen är död (`lsof -i :8420` på Macen) |
| Fel dygn i elpriserna | `docker exec energi date` ska visa svensk tid — annars är TZ-raderna i compose/Dockerfile ändrade |

## Total återställning

- **Routern:** `sh /tmp/openwrt-rollback.sh`, eller kopiera tillbaka
  `/etc/config.pre-energi-wg/` → `/etc/config/` + `reboot`, eller restore av
  `energi-pre-wg-*.tar.gz` via LuCI (System → Backup).
- **Servern:** `sudo systemctl disable --now wg-quick@wg-hem`,
  `sudo rm /etc/wireguard/wg-hem.conf`, `sudo ufw delete allow 51820/udp`,
  `docker compose -f /home/deploy/hosting/energi/docker-compose.yml down`.
- **Macen:** flytta tillbaka `~/energi`, `launchctl load -w <plist>` — allt
  ligger kvar orört tills steg 8.
