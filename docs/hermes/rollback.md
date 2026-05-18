# Rollback

If Hermes misbehaves, you can back out cleanly because OpenClaw is left
untouched through phase 6.

## Rolling back phase 1 (Hermes installed)

On 77.42.81.134:

```bash
sudo systemctl stop hermes 2>/dev/null || true
sudo systemctl disable hermes 2>/dev/null || true
sudo rm -f /etc/systemd/system/hermes.service
sudo systemctl daemon-reload

sudo deluser --remove-home hermes
```

OpenClaw is unaffected. Verify with `systemctl status openclaw` and a
ping in Telegram.

## Rolling back phase 2 (channels migrated)

`hermes claw migrate` copies state into `/home/hermes/.hermes/`; it does
not mutate `~/.openclaw/`. To revert:

1. `sudo systemctl stop hermes`
2. The original OpenClaw process owns the Telegram/WhatsApp webhooks
   again as soon as Hermes stops polling. If you used the same bot
   tokens, restart OpenClaw with `sudo systemctl restart openclaw` to
   reclaim the connection.
3. If you want to discard the Hermes-side import:
   `sudo rm -rf /home/hermes/.hermes/skills/openclaw-imports/`.

## Rolling back phase 3-6 (monitoring skills)

All monitoring lives under `/home/hermes/.hermes/skills/` and
`/home/hermes/.hermes/cron/`. Disable a skill by removing its file and
restarting the service, or stop the gateway entirely with
`sudo systemctl stop hermes`. The legacy GitHub Actions workflows are
still armed and will resume on their schedule.

## Full restore from a phase 0 backup

If `~/.openclaw/` is somehow corrupted later:

```bash
sudo systemctl stop openclaw
cp -a ~/openclaw-backup/<timestamp>/dot-openclaw/ ~/.openclaw
sudo cp ~/openclaw-backup/<timestamp>/systemd/openclaw.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start openclaw
```

Then verify `systemctl status openclaw` is `active (running)` and that
you get a reply on Telegram.
