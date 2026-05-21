# OpenClaw -> Hermes Agent migration plan

Target host: **77.42.81.134** (currently runs OpenClaw in production).
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
| 3 | Site / uptime monitoring as systemd timers | `scripts/hermes/phase3-setup-monitoring.sh` | scripts ready |
| 4 | Infra monitoring (mailcow, web-hosting-prod, local) | tbd | pending |
| 5 | Email triage over IMAP | tbd | pending |
| 6 | History / trends in SQLite | tbd | pending |
| 7 | Remove OpenClaw | tbd | pending |
| 8 | Hardening, backups, docs freeze | tbd | pending |

---

## Phase 0 - backup OpenClaw

**Goal:** capture everything OpenClaw needs to be restored from scratch,
before touching anything. Non-destructive: OpenClaw keeps running.

**Run on:** 77.42.81.134, as the user OpenClaw is installed under (likely
`deploy` or `thomas`; the script auto-detects from the systemd unit).

```bash
bash scripts/hermes/phase0-backup-openclaw.sh
```

Produces `~/openclaw-backup/<UTC-timestamp>/` containing:

- `dot-openclaw/` - full copy of `~/.openclaw/` (openclaw.json, identity,
  memory.sqlite, telegram, credentials, agents, flows, plugins, workspace)
- `systemd/` - the OpenClaw `.service` file if discoverable
- `state.txt` - systemctl status, npm/nvm versions, ufw, cron, listening ports
- `MANIFEST.md` - human-readable summary

### Verification

```bash
ls -la ~/openclaw-backup/$(ls -1t ~/openclaw-backup | head -1)/
cat ~/openclaw-backup/$(ls -1t ~/openclaw-backup | head -1)/MANIFEST.md
```

Expected: openclaw.json, identity/device.json, memory/main.sqlite and
credentials/ all present in the manifest. Copy the backup off-host
(`rsync` to a workstation or Hetzner Storage Box) before phase 1.

---

## Phase 1 - install Hermes alongside OpenClaw

**Goal:** install Hermes Agent under a dedicated `hermes` system user and
bring it up as a systemd service, without touching the running OpenClaw.

**Run on:** 77.42.81.134 as a user with sudo.

```bash
sudo bash scripts/hermes/phase1-install-hermes.sh
```

What the script does:

1. Creates a `hermes` system user with home `/home/hermes` (if missing).
2. Downloads the upstream installer to `/tmp/hermes-install.sh`, prints
   its SHA256, and **prompts for confirmation** before piping it to bash.
3. Runs the installer as the `hermes` user. The installer also triggers
   `hermes setup` interactively - choose **Nous Portal** as provider,
   keep "Local" as terminal backend, and **skip** messaging (phase 2
   imports the OpenClaw Telegram config).
4. Drops the unit at `/etc/systemd/system/hermes.service` and reloads
   systemd. Does **not** start the service - that happens in phase 2.

### Verification

```bash
sudo bash scripts/hermes/phase1-verify.sh
```

Must pass: hermes user, hermes binary, hermes.service installed,
openclaw still listening on 18789. `hermes doctor` will warn about
unconfigured optional providers - those are expected.

---

## Phase 2 - cut Telegram over to Hermes

**Goal:** stop OpenClaw, import its state into Hermes (including the
Telegram bot token), and bring up the Hermes gateway. Telegram users
start talking to Hermes instead of OpenClaw at this point.

**Prerequisites:**

- Phase 0 backup exists at `~deploy/openclaw-backup/<ts>/`
- Phase 1 verification was green

**Run on:** 77.42.81.134 as a user with sudo.

```bash
sudo bash scripts/hermes/phase2-cutover.sh
```

The script:

1. Confirms the phase 0 backup exists. Grants the `hermes` user a
   temporary read-only ACL on `~deploy/.openclaw/` (restored on exit).
2. Runs `hermes claw migrate --dry-run` and **prompts you to confirm**
   before any destructive action.
3. Stops OpenClaw (systemctl stop if managed; otherwise SIGTERM, then
   SIGKILL after 3 s grace). Verifies port 18789 is free.
4. Runs `hermes claw migrate` for real (imports SOUL, MEMORY, USER,
   skills, command allowlist, channel credentials including the
   Telegram bot token, into `/home/hermes/.hermes/`).
5. Enables and starts `hermes.service`. Waits a few seconds and checks
   `systemctl is-active hermes` == `active`. If not, prints recent
   journal lines and exits non-zero (OpenClaw is already stopped at
   this point - see rollback doc).

### Verification

```bash
sudo bash scripts/hermes/phase2-verify.sh
```

Must pass: hermes.service active and enabled, no openclaw process,
port 18789 free, openclaw-imports/ present under `~hermes/.hermes/`.

**Manual check:** open Telegram, send any message to your bot. You
should get a reply from Hermes (it may introduce itself differently than
OpenClaw did - that's expected; same bot token, different agent behind it).

If Telegram does **not** respond:

- `sudo journalctl -u hermes -n 100 --no-pager` for errors
- `sudo -u hermes -i hermes doctor` for missing config
- If unrecoverable: `docs/hermes/rollback.md` -> "Rolling back phase 2"

---

## Phase 3 - site/uptime-övervakning

**Goal:** Hermes bevakar 14 sajter var 5:e minut med HTTP-check, var 6:e
timme med SSL/DNS-check, och skickar en daglig rapport kl 08:00.
Varningar går direkt till Telegram. Inga åtgärder krävs från din sida
när en sajt återhämtar sig – Hermes skickar ett grönt meddelande självt.

**Sajter som övervakas** (redigera `config/sites.conf` för att ändra):
- Egna domäner: agiletransition.se, schiffer.se, digitaltoberoende.se,
  digitalsovereignty.eu, euproof.eu
- WaaS-kundsajter: azprofil, azp2b, hemsidor, azstore, schiffer (WaaS),
  seatower, stegvis, voxtera, forfor (alla under .agiletransition.se)

**Arkitektur:**
- Tre systemd-services körs som `hermes`-användaren
- Styrda av tre systemd-timers (site-check, ssl-check, daily-report)
- Loggar till `/var/log/hermes/monitoring.log`
- Tillståndsfiler i `/var/lib/hermes/monitoring/state/` (för
  up/down-detektering utan upprepade varningar)
- Telegram-credentials lagras i `/home/hermes/.config/hermes-monitoring/env`
  (rättigheter 600, bara läsbar av hermes)

**Installera på servern:**

```bash
# 1. Hämta senaste koden
git -C ~/server-maintenance pull

# 2. Kör installationsskriptet
sudo bash ~/server-maintenance/scripts/hermes/phase3-setup-monitoring.sh
```

Skriptet frågar efter Telegram-credentials om de inte hittas automatiskt.

### Verification

```bash
sudo bash ~/server-maintenance/scripts/hermes/phase3-verify.sh
```

Måste vara grönt: skript installerade, sites.conf, credentials, alla 6
systemd-units, alla 3 timers aktiva.

**Manuellt test:**
```bash
# Kör site-check direkt (för att se output och få ett Telegram-test)
sudo -u hermes bash /usr/local/lib/hermes-monitoring/site-check.sh

# Kontrollera logg
tail -20 /var/log/hermes/monitoring.log

# Se när timers körs nästa gång
systemctl list-timers hermes-*
```

Fel och åtgärder:
- Sajt visas som NER fast den är uppe: kontrollera att URL är korrekt i
  `config/sites.conf` och att förväntat HTTP-svar stämmer (vissa
  sajter returnerar 301/302)
- Telegram-notifiering kommer inte: kolla `/var/log/hermes/monitoring.log`
  för "Telegram-credentials saknas"

---

## Phase 4-8

Fylls i i nästa commits.

- **Phase 4:** SSH-baserade hälsokontroller mot mailcow och
  web-hosting-prod; lokala kontroller för ops-hosten.
- **Phase 5:** IMAP-polling mot mail.schiffer.se:993 för tre konton;
  LLM-triage; WhatsApp-pings för röda mail.
- **Phase 6:** SQLite-schema för metrics + incidenter; konversationell
  fråga-skärmk.
- **Phase 7:** avinstallera OpenClaw npm-paketet, ta bort unit-filer,
  droppa UFW-regel för 18789, ta bort nvm om oanvänd.
- **Phase 8:** härdning, daglig backup av `/home/hermes/.hermes/` till
  Hetzner Storage Box, fräs README + rollback-doc.

De befintliga GitHub Actions-workflows (`.github/workflows/`) och skripten
de anropar (`backup-databases.sh`, `health-check.sh`, `collect-metrics.sh`,
`update-server.sh`) lämnas berörda tills fas 7 bekräftar att Hermes tagit
över deras funktion. De inaktiveras sedan (workflow `on:`-block tas bort)
i samma PR som tar bort OpenClaw.
