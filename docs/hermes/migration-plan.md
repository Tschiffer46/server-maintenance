# OpenClaw -> Hermes Agent migration plan

Target host: **77.42.81.134** (ATM-shops, Hetzner Helsinki, CPX22, Ubuntu 24.04).
Hermes Agent: https://github.com/NousResearch/hermes-agent (v0.14.0+).
LLM provider: **Nous Portal** – modell `deepseek/deepseek-v4-flash`.

The plan is shipped stepwise. Run each phase, run its verification, only
then move to the next. Phase 7 (remove OpenClaw) does not run until
phase 1-6 are green.

| Phase | Goal | Script | Status |
|------:|------|--------|--------|
| 0 | Snapshot OpenClaw state | `scripts/hermes/phase0-backup-openclaw.sh` | shipped |
| 1 | Install Hermes alongside OpenClaw | `scripts/hermes/phase1-install-hermes.sh` | shipped |
| 2 | Cut Telegram over to Hermes via `hermes claw migrate` | `scripts/hermes/phase2-cutover.sh` | shipped |
| 3 | Site / uptime monitoring – 14 sajter, 5-min HTTP, 6h SSL, 08:00 rapport | `scripts/hermes/phase3-setup-monitoring.sh` | shipped |
| 4 | Infra monitoring – mailcow, web-hosting-prod, disk/RAM | `scripts/hermes/phase4-setup-infra.sh` | scripts ready |
| 5 | Email triage over IMAP | tbd | pending |
| 6 | History / trends in SQLite | tbd | pending |
| 7 | Remove OpenClaw | tbd | pending |
| 8 | Hardening, backups, docs freeze | tbd | pending |

---

## Phase 0 - backup OpenClaw

**Goal:** capture everything OpenClaw needs to be restored from scratch,
before touching anything. Non-destructive: OpenClaw keeps running.

```bash
bash scripts/hermes/phase0-backup-openclaw.sh
```

Produces `~/openclaw-backup/<UTC-timestamp>/` with MANIFEST.md.

---

## Phase 1 - install Hermes alongside OpenClaw

**Goal:** install Hermes Agent under a dedicated `hermes` system user and
bring it up as a systemd service, without touching the running OpenClaw.

```bash
sudo bash scripts/hermes/phase1-install-hermes.sh
sudo bash scripts/hermes/phase1-verify.sh   # must pass: 8  fail: 0
```

---

## Phase 2 - cut Telegram over to Hermes

**Goal:** stop OpenClaw, import its state into Hermes (including the
Telegram bot token), and bring up the Hermes gateway.

```bash
sudo bash scripts/hermes/phase2-cutover.sh
sudo bash scripts/hermes/phase2-verify.sh   # must pass: 6  fail: 0
```

Manual check: send a Telegram message to the bot → Hermes replies.

---

## Phase 3 - site/uptime-övervakning

**Goal:** Hermes bevakar 14 sajter var 5:e minut (HTTP), var 6:e timme
(SSL/DNS), och skickar daglig rapport kl 08:00.

**Sajter:** agiletransition.se, schiffer.se, digitaltoberoende.se,
digitalsovereignty.eu, euproof.eu + 9 WaaS-subdomäner.

```bash
git -C ~/server-maintenance pull
sudo bash ~/server-maintenance/scripts/hermes/phase3-setup-monitoring.sh
sudo bash ~/server-maintenance/scripts/hermes/phase3-verify.sh  # pass: 17  fail: 0
```

Redigera sajter i `config/sites.conf` och kör setup-skriptet igen.

---

## Phase 4 - infrastruktur-övervakning

**Goal:** Hermes checkar mailcow och web-hosting-prod var 10:e minut.
Varnar via Telegram om: SSH-fel, disk >80%, RAM >85%, webbserver nere,
Mailcow-portar (25/465/587/993) stängda.

**Hosts:**
- **mailcow**: 77.42.81.134 (lokal server, port 81 + SMTP/IMAP-portar)
- **web-hosting-prod**: 89.167.90.112 (SSH med `id_ed25519`)

**Installera på servern:**

```bash
git -C ~/server-maintenance pull
sudo bash ~/server-maintenance/scripts/hermes/phase4-setup-infra.sh
```

Skriptet:
1. Kopierar `config/infra.conf` → `/etc/hermes-monitoring/infra.conf`
2. Kopierar deploy-användarens SSH-nyckel → `/home/hermes/.ssh/id_ed25519_webhosting`
3. Kör `ssh-keyscan` för att lägga till web-hosting-prod i known_hosts
4. Installerar `mailcow-check.sh` och `webhosting-check.sh`
5. Aktiverar `hermes-infra-check.timer` (var 10:e minut)

### Verification

```bash
sudo bash ~/server-maintenance/scripts/hermes/phase4-verify.sh
```

Måste vara grönt: infra.conf, skript, SSH-nyckel, known_hosts,
timer aktiv, SSH-anslutning till web-hosting-prod OK.

**Manuellt test:**
```bash
# Kör mailcow-check direkt
sudo -u hermes bash /usr/local/lib/hermes-monitoring/mailcow-check.sh

# Kör webhosting-check direkt
sudo -u hermes bash /usr/local/lib/hermes-monitoring/webhosting-check.sh

# Kontrollera logg
grep -E 'mailcow|webhosting' /var/log/hermes/monitoring.log | tail -20
```

**Ändra tröskelvärden:** redigera `config/infra.conf` i repo:t och
kör setup-skriptet igen.

---

## Phase 5-8

- **Phase 5:** IMAP-polling mot mail.schiffer.se:993 för tre konton;
  LLM-triage (röd/gul/grön); Telegram-varning för röda mail.
- **Phase 6:** SQLite-schema för metrics + incidenter;
  konversationell fråge-skill (`Hur var uptimen igår?`).
- **Phase 7:** avinstallera OpenClaw npm-paketet, ta bort unit-filer,
  droppa UFW-regel för 18789, ta bort nvm om oanvänd.
- **Phase 8:** härdning, daglig backup av `/home/hermes/.hermes/` till
  Hetzner Storage Box, frys README + rollback-doc.
