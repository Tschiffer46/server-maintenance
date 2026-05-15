# OpenClaw on the Shopware Hetzner server (77.42.81.134)

24/7 AI monitoring agent that runs **alongside** Shopware on the same Hetzner VPS.
Goal: Telegram alerts for infrastructure/sites, WhatsApp pings for important email.

## Status

This is **iteration 1**: server preparation and OpenClaw install only. After this
works (you can chat with OpenClaw from Telegram), we layer on:

- Site/SSL/DNS monitoring (Phase 4 of the spec)
- Infrastructure cron checks (Phase 5)
- Email IMAP monitoring → WhatsApp (Phase 3)
- SSH to mail.schiffer.se / web-hosting-prod (Phase 6)

Keeping it incremental on purpose so we don't overengineer before basics work.

## What's here

```
openclaw/
├── README.md           ← this file
├── CLAUDE.md           ← context for future Claude Code sessions
├── PLAYBOOK.md         ← THE step-by-step you follow
└── scripts/
    ├── 00-recon.sh             ← inspect Shopware ports/resources (read-only)
    ├── 01-prepare-server.sh    ← OS update, fail2ban, ufw, nvm + Node 24
    └── 02-install-openclaw.sh  ← npm install -g openclaw + onboard wizard
```

## Start here

Open [PLAYBOOK.md](./PLAYBOOK.md) and follow it top to bottom.
