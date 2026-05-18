# Rollback

If Hermes misbehaves, you can back out cleanly because OpenClaw state is
preserved through phase 6 (the npm package is only uninstalled in phase 7).

## Rolling back phase 1 (Hermes installed)

On 77.42.81.134:

```bash
sudo systemctl stop hermes 2>/dev/null || true
sudo systemctl disable hermes 2>/dev/null || true
sudo rm -f /etc/systemd/system/hermes.service
sudo systemctl daemon-reload

sudo deluser --remove-home hermes
```

OpenClaw is unaffected. Verify with a ping in Telegram.

## Rolling back phase 2 (Telegram cut over to Hermes)

Phase 2 stops OpenClaw and starts Hermes. To revert, stop Hermes and
start OpenClaw again:

```bash
# 1. Stop Hermes so it releases the Telegram bot token.
sudo systemctl stop hermes
sudo systemctl disable hermes

# 2. Start OpenClaw the same way it was started before.
#    If systemctl knows the unit, the clean path is:
sudo systemctl start openclaw-gateway

#    If systemctl does NOT know the unit (was started manually), use
#    the exact command line phase 0 captured in state.txt - it looks like:
sudo -u deploy -H bash -lc '\
  source ~/.nvm/nvm.sh && \
  nohup node ~/.nvm/versions/node/v24.15.0/lib/node_modules/openclaw/dist/index.js \
    gateway --port 18789 >/dev/null 2>&1 &'

# 3. Verify port 18789 is listening again.
ss -ltn | grep 18789

# 4. Send a Telegram message and confirm OpenClaw answers.
```

The Hermes-side import is harmless to leave in place; it does not poll
the Telegram bot when the service is stopped. If you want to discard
the imported state entirely:

```bash
sudo rm -rf /home/hermes/.hermes/skills/openclaw-imports/
```

## Rolling back phase 3-6 (monitoring skills)

All monitoring lives under `/home/hermes/.hermes/skills/` and
`/home/hermes/.hermes/cron/`. Disable a skill by removing its file and
restarting the service, or stop the gateway entirely with
`sudo systemctl stop hermes`. The legacy GitHub Actions workflows are
still armed and will resume on their schedule.

## Full restore from a phase 0 backup

If `~/.openclaw/` is somehow corrupted later:

```bash
LATEST=$(ls -1t ~/openclaw-backup | head -1)
sudo systemctl stop hermes 2>/dev/null || true
sudo pkill -f openclaw 2>/dev/null || true
rm -rf ~/.openclaw
cp -a ~/openclaw-backup/${LATEST}/dot-openclaw/ ~/.openclaw
sudo cp ~/openclaw-backup/${LATEST}/systemd/openclaw*.service /etc/systemd/system/ 2>/dev/null || true
sudo systemctl daemon-reload
```

Then restart OpenClaw using one of the methods in "Rolling back phase 2"
above. Verify with a Telegram message.
