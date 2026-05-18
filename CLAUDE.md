# CLAUDE.md

Context for Claude Code sessions working on this repository.

## What this repo is

Operational tooling for the Hetzner servers behind Agile Transition AB and
related projects. Originally a thin wrapper around GitHub Actions that ran
backups, health checks and metrics collection against `web-hosting-prod`
(89.167.90.112).

The repo is now also the source of truth for the migration from **OpenClaw**
to **Hermes Agent** (Nous Research, https://github.com/NousResearch/hermes-agent)
on a separate ops host (77.42.81.134). When the migration is complete,
Hermes replaces both OpenClaw and the scheduled GitHub Actions workflows in
this repo.

## Infrastructure

| Role | Host | IP | Notes |
|------|------|----|----|
| Hermes host (ops) | `ops-host` | 77.42.81.134 | Runs OpenClaw today; Hermes installs alongside, then takes over. NPM admin on :81. |
| Web hosting | `web-hosting-prod` | 89.167.90.112 | Docker host for 10 sites incl. stegvis, voxtera, forfor. Today monitored by the GitHub Actions in this repo. |
| Mail | `mailcow-server` | 204.168.157.75 | Mailcow + 18 containers. SSH key on ops-host: `~/.ssh/id_ed25519_mailcow`. |

All hosts: Hetzner, Helsinki.

## Migration layout in this repo

```
docs/hermes/
  migration-plan.md   8-phase plan with verification steps
  rollback.md         How to back out of each phase
scripts/hermes/
  phase0-*.sh         Backup OpenClaw state
  phase1-*.sh         Install Hermes alongside OpenClaw
  phase2+...          (added in later rounds)
systemd/
  hermes.service      Systemd unit for the hermes user
config/hermes/        (added when phase 2 lands)
skills/               (added when phase 3+ lands)
```

The existing top-level `scripts/` (backup-databases.sh, harden-server.sh,
etc.) and the GitHub Actions workflows in `.github/workflows/` belong to
the legacy GH-Actions-driven monitoring. Do not delete them until phase 7
verifies Hermes has taken over their function.

## Working agreements

- Migration is shipped **stepwise**. Don't try to land all 8 phases in one
  commit. Each phase has a verification script the user runs on the server
  before moving on.
- Hermes is configured to use **Nous Portal** as LLM provider (no Anthropic).
- The Hermes process runs as a dedicated `hermes` system user with
  `MemoryMax=1G` and `CPUQuota=30%` so it can't impact other services on
  the host.
- `hermes claw migrate` is the canonical way to import OpenClaw state
  (SOUL.md, MEMORY.md, USER.md, skills, allowlist, channel keys). Don't
  hand-roll that migration.
- The Hermes gateway binds to 127.0.0.1. Never expose it on 0.0.0.0
  without an authenticated reverse proxy in front.
- Scripts use `set -euo pipefail` and avoid destructive operations
  (no `rm -rf`, no `systemctl disable`) unless explicitly in a phase 7 script.
- Do not include model identifiers (e.g. `claude-opus-4-7`) in commits,
  PR bodies or files in this repo.
