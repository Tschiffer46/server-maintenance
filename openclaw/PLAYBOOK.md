# OpenClaw setup — step by step

Follow this top to bottom. Each step is a single command you paste into your
terminal. **Stop and ping me if something errors** — don't try to fix it yourself.

---

## Before you start — collect these

Open a text file and paste these in. You'll need them in step 4.

1. **Anthropic API key** — get one at https://console.anthropic.com/settings/keys
   (Pick "Create Key", name it `openclaw`, copy the `sk-ant-...` string.)
2. **Telegram bot token** — we'll create this together in step 5 (skip for now).

That's it for now. WhatsApp + email come in a later iteration.

---

## Step 1 — SSH into the server

From your laptop:

```bash
ssh deploy@77.42.81.134
```

(If the username isn't `deploy`, use whatever user you normally SSH in as.)

If this works you'll see a shell prompt like `deploy@hostname:~$`. **Stay in this shell for the rest of the playbook.**

---

## Step 2 — Pull this repo onto the server

```bash
cd ~
if [ -d server-maintenance ]; then
  cd server-maintenance && git fetch --all && git checkout claude/setup-openclaw-hetzner-gmHe4 && git pull
else
  git clone -b claude/setup-openclaw-hetzner-gmHe4 https://github.com/Tschiffer46/server-maintenance.git
  cd server-maintenance
fi
```

---

## Step 3 — Recon: see what Shopware is doing (read-only, safe)

```bash
bash openclaw/scripts/00-recon.sh
```

This prints disk, RAM, Docker containers, and listening ports. **Copy the output and send it to me** before continuing — I want to verify we have enough headroom and won't collide with Shopware.

---

## Step 4 — Prepare the server

This installs OS updates, fail2ban (if missing), and nvm + Node 24. It does NOT touch Shopware, Docker, or any existing services.

```bash
sudo bash openclaw/scripts/01-prepare-server.sh
```

It will ask for your sudo password once. Takes ~3–5 min. When it finishes you should see `✅ Server prep complete`.

---

## Step 5 — Create your Telegram bot (do this on your phone)

1. Open Telegram, search for **@BotFather**, start a chat.
2. Send `/newbot`.
3. Name: `Thomas Server Monitor` (or anything you like).
4. Username: must end in `bot`, e.g. `thomas_server_monitor_bot`.
5. BotFather replies with a token like `7891234567:AAH...`. **Copy it.**
6. Send `/start` to your new bot (find it via the username), then send any message like `hi`. This makes Telegram remember your chat ID.
7. Paste the bot token into the text file from "Before you start".

---

## Step 6 — Install OpenClaw and run the onboarding wizard

Back in the SSH shell:

```bash
bash openclaw/scripts/02-install-openclaw.sh
```

This loads Node 24 (via nvm) and runs `openclaw onboard --install-daemon`. The wizard is **interactive** — here's what to pick:

| Prompt | Answer |
|---|---|
| Model provider | **Anthropic** |
| API key | paste your `sk-ant-...` |
| Model | `claude-sonnet-4-6` (good balance of cost/quality for monitoring) |
| Install daemon? | **Yes** |
| Add a channel now? | **Yes → Telegram** |
| Telegram bot token | paste from step 5 |

If any prompt is different from this list, **stop and tell me what it says** — don't guess.

When it finishes, verify:

```bash
openclaw --version
openclaw doctor
openclaw gateway status
```

All three should run without error. `doctor` may show warnings — that's OK, send me the output.

---

## Step 7 — Smoke test from Telegram

On your phone, open the chat with your bot. Send:

```
What host are you running on? Run `hostname` and `uname -a` and tell me.
```

OpenClaw should reply with the server's hostname. If yes — **we're done with iteration 1.** 🎉

Report back: "step 7 works" and I'll start iteration 2 (site monitoring cron jobs).

---

## Iteration 2 — Site monitoring (HTTP + SSL)

Adds cron jobs that check 5 sites every 5 minutes (HTTP) and every 6 hours
(SSL cert expiry), pinging your Telegram bot **only when status changes**.

Sites monitored (edit `openclaw/config/sites.txt` to change):
agiletransition.se · schiffer.se · digitaltoberoende.se · digitalsovereignty.eu · euproof.eu

### Step 2.1 — Find your Telegram chat id

When you ran `/start` on your bot earlier, it replied with:

> Your Telegram user id: **XXXXXXXXX**

Copy that number — it's also your **chat id**. (If you've lost it, send `/start`
to the bot again.)

### Step 2.2 — Run the installer

SSH in as `deploy`, then:

```bash
cd ~/server-maintenance
git pull
bash openclaw/scripts/03-install-monitoring.sh
```

The script will:

1. Read your bot token from OpenClaw's config (no need to paste it).
2. Ask for your **Telegram chat id** — paste the number from step 2.1.
3. Send a test message to Telegram (you should see "🦞 OpenClaw monitor installed…").
4. Install two cron jobs:
   - `*/5 * * * *` site-check.sh — HTTP status every 5 minutes
   - `17 */6 * * *` ssl-check.sh — SSL expiry every 6 hours
5. Run the first HTTP check immediately to seed state.

### Step 2.3 — Verify

```bash
crontab -l                              # should show the openclaw-monitor block
tail -f ~/.openclaw-monitor/monitor.log # live log
ls ~/.openclaw-monitor/state/           # one file per site
```

To test a real alert, temporarily add a bogus URL to `openclaw/config/sites.txt`
(e.g. `https://this-does-not-exist.example`), wait 5 minutes — you should get a
🚨 DOWN message. Then remove the line and wait 5 more minutes for ✅ RECOVERED…
or just delete its state file.

### Step 2.4 — To stop monitoring

```bash
crontab -e   # delete the lines between # >>> openclaw-monitor >>> markers
```

---

## Iteration 3 — Infrastructure checks (disk / RAM / Docker / services)

Adds a 15-minute cron job that watches the *server itself*:

- **Disk** at `/` — warn at 85%, critical at 95%
- **Memory** — warn at 90% used
- **Swap** — warn at 50% used (skipped on swap-less hosts)
- **Load average** — warn when 1-min load > 4× CPU count
- **Docker containers** — warn if any of `azprofil-shopware`, `azprofil-redis`, `npm` is not `running`
- **Systemd services** — warn if any of `fail2ban`, `ufw`, `docker`, `ssh` is not active

Same transition-based alerts: you only hear about it when state changes.
Edit `openclaw/config/infra.conf` to tweak thresholds or the expected container list.

### Step 3.1 — Install

```bash
cd ~/server-maintenance
git pull
bash openclaw/scripts/04-install-infra-monitoring.sh
```

The installer runs one check immediately (no notifications unless something is
actually wrong) and appends `*/15 * * * * infra-check.sh` to your cron block.

### Step 3.2 — Verify

```bash
crontab -l | grep openclaw -A 5     # should now show 3 cron lines
ls ~/.openclaw-monitor/state/       # one infra-*.state file per metric
tail ~/.openclaw-monitor/monitor.log
```

### Step 3.3 — Test an alert (optional)

Trigger a fake container outage:

```bash
echo 'EXPECTED_CONTAINERS="azprofil-shopware azprofil-redis npm does-not-exist"' \
  >> openclaw/config/infra.conf
bash openclaw/scripts/infra-check.sh
```

You should get a 🚨 ALERT in Telegram about `does-not-exist`. Then `git checkout
openclaw/config/infra.conf` to undo and run the check again to clear the state.

---

## Iteration 5 — Email triage (IMAP → Claude → Telegram)

Watches 3 Mailcow inboxes **read-only** (cannot modify, move, delete, or mark
read), classifies each new message with Claude as IMPORTANT / NORMAL / JUNK,
and pings Telegram only for IMPORTANT ones. Runs every 5 minutes.

Inboxes (edit `openclaw/config/email.conf` to change):
- `thomas@schiffer.se`
- `thomas@agiletransition.se`
- `info@agiletransition.se`

**Data minimisation:** only sender, subject, and the first 500 characters of
the plain-text body are sent to Claude. Full bodies are never written to disk.

### Step 5.1 — Create Mailcow app-passwords (one per inbox)

App-passwords are separate, revocable passwords just for IMAP — your main
password isn't shared with this script.

1. Sign in to Mailcow at https://mail.schiffer.se as each mailbox owner
2. **Account → App passwords → Create new**
3. Name it `openclaw-monitor`, **enable IMAP**, leave SMTP off
4. Copy the generated password (it's only shown once)

You'll need three of these — one for each inbox.

### Step 5.2 — Install

SSH in as `deploy`, then:

```bash
cd ~/server-maintenance
git pull
bash openclaw/scripts/05-install-email-triage.sh
```

The script asks for the three app-passwords (one at a time, hidden input),
then tests each connection in read-only mode. The first cron run is silent
— it just records the current "top UID" per inbox so you don't get blasted
with historical mail.

### Step 5.3 — Verify

```bash
crontab -l | grep email-triage          # should show the */5 line
tail -f ~/.openclaw-monitor/monitor.log # watch classifications
ls ~/.openclaw-monitor/state/email-*    # one per inbox
```

Send yourself a test mail with subject `URGENT: test from Thomas` — within 5
minutes it should classify as IMPORTANT and arrive in Telegram.

### Notes

- **Cost:** Haiku 4.5 ≈ €0.001 per classified message. 100 mails/day ≈ €3/mo.
- **Change the model** in `openclaw/config/email.conf` (`CLASSIFIER_MODEL=`).
- **Pause triage:** `crontab -e` and comment out the `email-triage.py` line.
- **Add more inboxes:** edit `email.conf` `INBOXES=` and add a corresponding
  `IMAP_PASS_*` entry to `~/.openclaw-monitor/.env`.

---

## If something goes wrong

- **Don't run any cleanup or `rm` commands.** Stop and message me with:
  - Which step number you were on
  - The exact command you ran
  - The full error output (copy-paste the whole thing)

- **Safe to re-run:** scripts 00, 01, 02 are idempotent. You can run them again without harm.

- **To completely undo (if you ever need to):** `openclaw onboard --uninstall` removes the daemon; `npm uninstall -g openclaw` removes the binary. Shopware is untouched.
