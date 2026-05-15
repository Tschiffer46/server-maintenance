# CLAUDE.md — OpenClaw on Shopware server

Context for future Claude Code sessions on this subfolder.

## Target machine

- IP: `77.42.81.134`
- Hosts: Shopware (Docker) + frontend static sites under `~/hosting/sites/*`
- SSH secrets live in the **ehandel** repo Actions secrets (SERVER_HOST, SERVER_USER, SERVER_SSH_KEY)
- This repo (`server-maintenance`) is the home for OpenClaw setup and ops scripts
- Other servers (read-only monitoring targets, not the OpenClaw host):
  - `mail.schiffer.se` — Mailcow (Docker), fail2ban; domains: schiffer.se, agiletransition.se, euproof.eu, digitalsovereignty.eu
  - `web-hosting-prod` (89.167.90.112) — multi-site Docker, Cloudflare DNS; managed in this repo's root scripts/

## Hard rules

1. **Never touch Shopware** containers, volumes, or configs. OpenClaw runs *next to* it, isolated.
2. **Read-only** posture on all servers: OpenClaw observes & reports, never restarts/deletes/edits.
3. **OpenClaw Gateway never exposed to the internet** — bind localhost only, UFW closed except 22/80/443 + existing Shopware ports.
4. **Secrets in `.env` with 600 perms** on the server. Never commit secrets to git.
5. **Email IMAP is READ-ONLY** — never SEEN-flag, move, delete, or send. App-passwords only (Mailcow).
6. **LLM payloads minimized** — for email classification send only sender/subject/first 500 chars.

## Spec source

The full ambition is in the prompt the user attached (Swedish, 7 phases). We're
implementing it incrementally:

- **Iteration 1 (current):** server prep + install OpenClaw + Telegram channel + Anthropic LLM
- **Iteration 2:** Site monitoring (cron HTTP checks for the 5 sites)
- **Iteration 3:** Infra cron checks (disk/RAM/Docker/fail2ban) on this server
- **Iteration 4:** SSH monitor-user on mail.schiffer.se and 89.167.90.112; cross-server checks
- **Iteration 5:** IMAP → WhatsApp email triage with Claude classification
- **Iteration 6:** Morning digest (08:00) on both channels, SQLite history

## OpenClaw quick facts (as of install)

- Install: `npm i -g openclaw@latest` then `openclaw onboard --install-daemon`
- Daemon: systemd **user** service (so it runs as the deploy user, not root)
- Node: 24 (recommended) or 22.16+ — installed via nvm to avoid conflict with Shopware Node
- Gateway: local-only HTTP control plane (default port 18789)
- Channels: Telegram (bot token), WhatsApp (Business API or web bridge), Slack, Discord, etc.
- Provider: Anthropic Claude — API key entered in onboarding wizard
- Cron tool: built-in; used for scheduled checks
- Docs: https://docs.openclaw.ai (use raw.githubusercontent.com/openclaw/openclaw/main/docs/* when 403)

## Branching

Development branch for this work: `claude/setup-openclaw-hetzner-gmHe4`
Do NOT push to main without explicit user permission.

## Tone for the user

User self-describes as non-technical. Every step must be copy-pasteable. Explain
what each command does. Ask one question at a time. Prefer scripts over manual edits.
