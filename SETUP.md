# SETUP.md — VadSkaVi (vadskavi.nu)

Driftsättningsunderlag för den planerade familjereceptbok-appen **VadSkaVi**
(Next.js 15 + PostgreSQL) på den befintliga Hetzner-VPS:en.

> **Källa & metod:** Det gick **inte** att SSH:a till servern från denna
> miljö (utgående port 22 är blockerad och ingen SSH-nyckel finns här — nyckeln
> ligger som GitHub Actions-secret `SERVER_SSH_KEY`). Inventeringen nedan bygger
> därför på **verklig telemetri** som `server-maintenance`-repots insamlare
> hämtade från servern: `docs/data/latest.json`, daterad **2026-05-15**, plus
> insamlings-/backup-skripten i `scripts/`. Punkter som telemetrin inte täcker
> är markerade **⚠️ ej verifierat** med instruktion för hur du bekräftar dem.

---

## 1. Serverspecifikationer

| Resurs | Värde |
|--------|-------|
| Hostname | `web-hosting-prod` |
| IP | 89.167.90.112 (Hetzner VPS) |
| OS | **Ubuntu 24.04.4 LTS** |
| Kernel | 6.8.0-101-generic |
| CPU | **2 vCPU** (last 0.01 / 0.06 / 0.11 — i princip idle) |
| RAM | **3819 MiB (~3,7 GB)**, ~2218 MiB ledigt vid mätning |
| Swap | **0 MB (ingen swap konfigurerad)** |
| Disk `/` | 40 GB total, **73 % använt, ~8,8 GB ledigt** |
| Uptime | ~69 dagar |
| SSH-användare | `deploy` |

**Flaggor att notera:** 39 väntande OS-uppdateringar (0 säkerhets), och
**reboot krävs** (`/var/run/reboot-required`). Planera en omstart.

---

## 2. Databaser

**PostgreSQL 16** är den etablerade databasen — körs som flera fristående
`postgres:16-alpine`-containrar, **en DB-container per app**:

| Container | Image | Tillhör app | Backas upp? |
|-----------|-------|-------------|-------------|
| `forfor-db` | postgres:16-alpine | forfor | ✅ ja |
| `voxtera-db` | postgres:16-alpine | voxtera | ✅ ja |
| `stegvis-db` | postgres:16-alpine | stegvis | ❌ **nej** |
| `schiffer-db` | postgres:16-alpine | schiffer | ❌ **nej** |

DB-storlekar (telemetri): forfor ~10 MB, voxtera ~8,7 MB. Mycket små.

- **MySQL/MariaDB:** Image `mariadb:11` finns nedladdad men **ingen MariaDB-container
  körs** → MySQL/MariaDB används i praktiken inte just nu.
- **SQLite:** ⚠️ ej verifierat (telemetrin scannar inte filsystemet efter
  `.sqlite`-filer). Inga tecken på SQLite-baserade tjänster.

> **Lucka i backup-rutinen:** `scripts/backup-databases.sh` dumpar **endast**
> `forfor` och `voxtera`. `stegvis-db` och `schiffer-db` säkerhetskopieras inte.
> En ny `vadskavi-db` måste läggas till explicit i backup-skriptet (se §3).

---

## 3. Docker

- **Installerat:** Ja. Docker används som primär driftsplattform.
- **Version:** ⚠️ exakt version ej i telemetrin (verifiera med `docker --version`).
- **Containrar:** **17 st körs, alla `healthy`.** Compose-fil ligger på servern:
  `/home/deploy/hosting/docker-compose.yml`.

Körande containrar (urval):

| Container | Image | Roll |
|-----------|-------|------|
| `proxy-manager` | jc21/nginx-proxy-manager:latest | **Reverse proxy / TLS** |
| `stegvis` + `stegvis-db` | ghcr.io/tschiffer46/stegvis-app | Next/Node-app + Postgres |
| `forfor` + `forfor-db` | ghcr.io/tschiffer46/forfor | Node-app + Postgres |
| `voxtera` + `voxtera-db` | ghcr.io/tschiffer46/voxtera | Node-app + Postgres |
| `schiffer` + `schiffer-db` | ghcr.io/tschiffer46/client-schiffer | App + Postgres |
| `ehandel`, `azp2b`, `azstore`, `azprofil`, `agiletransition`, `hemsidor`, `seatower`, `client-akeobygg` | nginx:alpine | Statiska sajter |

Nedladdade images inkluderar `node:20-alpine`, `postgres:16-alpine`,
`nginx:alpine`, `httpd:alpine`, `mariadb:11`.

---

## 4. Node.js

- **På host:** ⚠️ ej i telemetrin. Reza-projektets dokumentation visar att Node
  installeras via **nvm** för `deploy`-användaren (standalone-deploy). Verifiera
  med `. ~/.nvm/nvm.sh && node -v`.
- **I containrar:** `node:20-alpine` finns nedladdad; Docker-apparna byggs med
  egna Node-baser. För VadSkaVi spelar host-Node ingen roll om vi kör i Docker.

---

## 5. Webbserver / Reverse proxy

- **Nginx Proxy Manager (NPM)** är den enda publika ingången — container
  `jc21/nginx-proxy-manager`, hanterar 80/443 + Let's Encrypt-certifikat.
- Vhosts/proxy-hosts konfigureras i **NPM:s admin-UI (port 81)**, inte i
  textfiler i repo → den fullständiga vhost-listan kan inte läsas härifrån
  (⚠️ ej verifierat på filnivå). Port 81 är tänkt att vara blockerad; nås via
  SSH-tunnel: `ssh -L 8081:localhost:81 deploy@89.167.90.112`.
- De statiska sajterna serveras av egna `nginx:alpine`-containrar bakom NPM.
- **Apache:** används inte (image `httpd:alpine` finns men ingen container kör).

10 sajter övervakas, alla svarar (200/307) med giltiga TLS-cert (~68 dagar kvar):
`schiffer`, `seatower`, `hemsidor`, `azprofil`, `azp2b`, `agiletransition.se`,
`azstore`, `stegvis`, `voxtera`, `forfor` (alla under `agiletransition.se`).

---

## 6. Portar och brandvägg

- **UFW: AVSTÄNGT** (`ufw_enabled: false`, 0 regler) vid mätning — trots att
  härdnings-skriptet är tänkt att öppna endast 22/80/443. Brandväggsskydd vilar
  alltså på Hetzners nätverk + ev. iptables-regler, inte UFW.
- fail2ban: 0 bans, 0 SSH-misslyckanden senaste 24 h.
- Publika portar i praktiken: **80 + 443** (via NPM), **22** (SSH).
- Reza-mönstret använder en iptables-regel för Docker→host:
  `iptables -I INPUT -s 172.18.0.0/16 -p tcp --dport <port> -j ACCEPT`.

**Portar vi kan använda för VadSkaVi:** appen behöver ingen egen publik port —
den ansluts till NPM:s interna Docker-nätverk och proxas på 443. Om en
host-mappad port ändå önskas (reza använder t.ex. **3456**), välj en ledig
high-port, förslagsvis **3457**. Inga portkonflikter syns i telemetrin.

---

## 7. Befintliga Next.js / webbappar

Ja — det finns redan ett etablerat mönster:

- **Docker-apps:** `stegvis`, `forfor`, `voxtera`, `schiffer` (Node/Next-appar,
  var och en med egen `*-db` Postgres-container, byggda som GHCR-images och
  publicerade via NPM). Detta är den **rekommenderade mallen** för VadSkaVi.
- **Standalone (utanför Docker):** Reza (`reza.agiletransition.se`) är enligt sin
  egen dokumentation en Next.js 15 standalone-app via **systemd** (`reza.service`)
  på port 3456. (Reza syns inte i `server-maintenance`-övervakningen.)

---

## 8. Rekommenderad deployment-strategi

**→ Docker Compose, en app-container + en dedikerad `postgres:16-alpine`,
bakom Nginx Proxy Manager.** Detta matchar exakt det befintliga
stegvis/forfor/voxtera-mönstret och är att föredra framför reza:s
systemd-standalone (svårare att underhålla, bryter mot husets konvention).

Konkret upplägg:

1. **Bygg** VadSkaVi som image → publicera till `ghcr.io/tschiffer46/vadskavi`
   (samma CI/CD-flöde som övriga Docker-appar).
2. **Lägg till** `vadskavi` + `vadskavi-db` i
   `/home/deploy/hosting/docker-compose.yml`, anslutna till NPM:s proxy-nätverk
   (samma nätverk som de övriga app-containrarna använder).
3. **DNS:** `vadskavi.nu` är en **ny, extern domän** (inte `*.agiletransition.se`).
   Peka A-record → 89.167.90.112 (via Cloudflare om det ska matcha resten) och
   skapa en ny **Proxy Host i NPM** med Let's Encrypt-cert.
4. **Backup:** Lägg till en `vadskavi`-dump i `scripts/backup-databases.sh`
   (och gärna åtgärda att `stegvis`/`schiffer` saknas där). Lägg ev. till
   `vadskavi-db` i `scripts/collect-metrics.sh` (rad ~93) för storleksmätning.
5. **Health check:** Lägg `vadskavi.nu` i sajtlistan för health-check.

Migrationer (Prisma) körs i container-start eller via engångskommando, likt reza.

---

## 9. Konflikter & saker att vara medveten om

| Risk | Detalj | Åtgärd |
|------|--------|--------|
| **Disk 73 % / ~8,8 GB ledigt** | En Next.js-image väger ~0,5–0,7 GB (jfr stegvis 717 MB) + Postgres-data | Kör `docker image prune`; bevaka disk efter deploy |
| **Endast ~3,7 GB RAM, ingen swap** | 17 containrar drar redan ~1,6 GB; ~2,2 GB headroom | Next.js standalone-container är lätt, men överväg att lägga till swap |
| **UFW avstängt** | Brandväggen är inte aktiv enligt telemetri | Säkerhetsbrist — kör `harden-server.sh`, men inget driftshinder |
| **Reboot krävs + 39 uppdateringar** | Pågående kernel/paket-uppdateringar | Planera underhållsfönster med omstart före/efter deploy |
| **Backup-lucka** | Endast forfor/voxtera dumpas idag | Lägg till vadskavi (+ stegvis/schiffer) i backup-skriptet |
| **Ny domän** | `vadskavi.nu` ≠ befintligt cert-mönster | Nytt DNS + ny NPM proxy host + nytt LE-cert |
| **Port 3456 upptagen** | Reza (om host-mappad port behövs) | Använd 3457 eller håll appen helt internt i Docker-nätet |

---

## 10. Att verifiera direkt på servern (ej täckt av telemetri)

```bash
ssh deploy@89.167.90.112

docker --version && docker compose version      # Docker-version
. ~/.nvm/nvm.sh && node -v                       # Host Node-version
docker ps --format 'table {{.Names}}\t{{.Ports}}'# Faktiska portmappningar
sudo ss -tlnp                                     # Lyssnande portar
sudo ufw status verbose                           # Brandväggsstatus
sudo iptables -L INPUT -n                         # iptables-regler
ls /home/deploy/hosting/                          # Compose + ev. nginx-confs
find / -name '*.sqlite*' 2>/dev/null              # Ev. SQLite-databaser
mysql --version 2>/dev/null || echo "ingen host-MySQL"
df -h && free -m                                  # Aktuell disk/RAM
```

---

*Underlag genererat 2026-06-03 från `server-maintenance`-telemetri (snapshot
2026-05-15). Verifiera de ⚠️-markerade punkterna på servern innan bygget startar.*
