# OpenClaw -> Hermes Agent migration plan

Target host: **77.42.81.134** (currently runs OpenClaw in production).
Hermes Agent: https://github.com/NousResearch/hermes-agent (v0.14.0+).
LLM provider: **Nous Portal**.

The plan is shipped stepwise. Run each phase, run its verification, only
then move to the next. Phase 7 (remove OpenClaw) does not run until
phase 1-6 are green.

| Phase | Goal | Script | Status |
|------:|------|--------|--------|
| 0 | Snapshot OpenClaw state | `scripts/hermes/phase0-backup-openclaw.sh` | shipped |
| 1 | Install Hermes alongside OpenClaw | `scripts/hermes/phase1-install-hermes.sh` | shipped |
| 2 | Channels (Telegram, WhatsApp) via `hermes claw migrate` | tbd | pending |
| 3 | Site / uptime monitoring as Hermes skills | tbd | pending |
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

- `dot-openclaw/` - full copy of `~/.openclaw/` (SOUL.md, MEMORY.md,
  USER.md, skills/, sessions/, config)
- `systemd/` - the OpenClaw `.service` file
- `state.txt` - `systemctl status openclaw`, `npm ls -g`, nvm version,
  `ufw status`, `crontab -l`, open ports on 18789
- `MANIFEST.md` - human-readable summary of what was captured

### Verification

```bash
ls -la ~/openclaw-backup/$(ls -1t ~/openclaw-backup | head -1)/
cat ~/openclaw-backup/$(ls -1t ~/openclaw-backup | head -1)/MANIFEST.md
```

Expected: a non-empty `dot-openclaw/` tree and a MANIFEST that lists at
least SOUL.md, USER.md and the systemd unit.

**Do not proceed to phase 1 until the backup directory contains a copy
of `SOUL.md` and the systemd unit.** Consider copying the backup tarball
off the host as well (e.g. `rsync` to a workstation or Hetzner Storage Box).

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
3. Runs the installer as the `hermes` user. This populates
   `/home/hermes/.hermes/` and installs the `hermes` binary at
   `/home/hermes/.local/bin/hermes`.
4. Drops the unit at `/etc/systemd/system/hermes.service` (see
   `systemd/hermes.service`) and reloads systemd.
5. Does **not** start the service yet - that happens after `hermes setup`
   has been run interactively in phase 2 so the gateway has channels and
   an LLM configured.

Manual step after the script:

```bash
sudo -u hermes -i
hermes setup     # interactive: choose Nous Portal as provider,
                 # pick a model, leave channels for phase 2
exit
```

### Verification

```bash
bash scripts/hermes/phase1-verify.sh
```

Checks:

- `hermes` user exists and owns `/home/hermes/.hermes/`
- `/home/hermes/.local/bin/hermes --version` runs and reports >= 0.14.0
- `systemctl status hermes` is `loaded; inactive (dead)` - unit present, not running yet
- OpenClaw is still `active (running)` and listening on 127.0.0.1:18789
- `hermes doctor` (as the hermes user) reports no fatal errors

If any check fails, do not proceed to phase 2. See `docs/hermes/rollback.md`
for how to undo phase 1 cleanly.

---

## Phase 2-8

Filled in in the next commits, once phase 0-1 are verified on the host.
Short outline:

- **Phase 2:** `hermes claw migrate --dry-run` -> review -> live migrate;
  start the gateway; verify Telegram/WhatsApp round-trip.
- **Phase 3:** site uptime + SSL + DNS skills, cron-style schedule, daily
  08:00 site report.
- **Phase 4:** SSH-based health checks against mailcow and
  web-hosting-prod; local checks for the ops host itself.
- **Phase 5:** IMAP poller against mail.schiffer.se:993 for the three
  accounts; LLM triage; WhatsApp pings for red-tier mail.
- **Phase 6:** SQLite schema for metrics + incidents; conversational
  query skill (`Hur var uptimen ...`).
- **Phase 7:** stop and uninstall OpenClaw; drop UFW rule for 18789;
  remove nvm if unused elsewhere; `hermes doctor` confirms independence.
- **Phase 8:** harden (rate limits, secrets workflow, restrict gateway
  to 127.0.0.1), daily backup of `/home/hermes/.hermes/` to Hetzner
  Storage Box, freeze README + rollback doc.

The legacy GitHub Actions in `.github/workflows/` and the scripts they
call (`backup-databases.sh`, `health-check.sh`, `collect-metrics.sh`,
`update-server.sh`) stay in place until phase 7 verifies Hermes has
taken over their function. They are then disabled (workflow `on:` blocks
stripped) in the same PR that removes OpenClaw.
