# energi — energidashboard på Hetzner

> **Tillfällig placering:** det här kitet ligger just nu som katalogen
> `energi/` i server-maintenance-repot, eftersom GitHub-integrationen inte
> får skapa nya repon. Skapa gärna ett eget privat repo `Tschiffer46/energi`
> och flytta hit innehållet — exakta kommandon finns i PR-beskrivningen.
> Allt fungerar dock precis lika bra att köra härifrån.

Energiinsamlare + dashboard (FastAPI, port 8420) som läser Sungrow-växelriktaren
(Modbus TCP) och Shelly Pro 3EM (HTTP) på hemmanätet var 5:e minut, lagrar i
SQLite och visar en dashboard. Flyttad från en MacBook till Hetzner-VPS:en
enligt **[RUNBOOK.md](RUNBOOK.md)** — börja där.

## Arkitektur

```
Internet ──https+auth──▶ NPM ──▶ [energi-container :8420] Hetzner 89.167.90.112
                                        │ pollar var 5:e min
                                        ▼
                              WireGuard wg-hem (UDP 51820)
                              10.8.20.1 ◀──tunnel──▶ 10.8.20.2
                                                       │ OpenWrt 192.168.1.1
                                          (initierar, bakom NAT, keepalive)
                                                       │ brandvägg: ENDAST
                                                       ├─▶ 192.168.1.202:502  Sungrow (Modbus TCP, läsning)
                                                       └─▶ 192.168.1.96:80    Shelly Pro 3EM (HTTP, läsning)
```

Säkerhetsprinciper:

- **Snäv tunnel.** `AllowedIPs` på serversidan + brandväggsregler på routern
  släpper bara igenom de två mätar-IP:na på exakt rätt portar. Resten av
  hemmanätet är onåbart från servern (verifieras av `scripts/40-test-tunnel.sh`).
- **Inget öppet mot internet.** Containern publicerar bara `127.0.0.1:8420`
  på servern; publikt nås den enbart via Nginx Proxy Manager med Let's
  Encrypt **och** Access List (inloggning).
- **Endast läsning.** Ingenting i växelriktarens/WiNet-donglens eller Shellyns
  konfiguration rörs — appen läser bara värden.

## Innehåll

| Fil | Vad |
|-----|-----|
| `RUNBOOK.md` | Hela migrationen steg för steg, med verifiering per steg |
| `scripts/config.env` | **All konfiguration** (server, domän, IP:n) — ändra här |
| `scripts/10–40-*.sh` | WireGuard: Hetzner-sida, OpenWrt-sida, aktivering, tunneltest |
| `scripts/50-migrate-from-mac.sh` | Stoppar Mac-appen, flyttar app + databas säkert |
| `scripts/60-deploy.sh`, `70-verify.sh` | Bygg/starta containern, slutverifiering |
| `scripts/openwrt-rollback.sh` | Nödbroms: tar bort allt på routern igen |
| `deploy/` | Dockerfile, docker-compose.yml, requirements.txt |
| `deploy/app/` | Hit flyttas `app.py`, `index.html`, `energi.db` (databasen git-ignoreras) |

Drift (backup av `energi.db`, hälsokoll) sköts av
[Tschiffer46/server-maintenance](https://github.com/Tschiffer46/server-maintenance).
