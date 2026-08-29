# Server Maintenance

Automated maintenance for the Hetzner VPS (89.167.90.112) hosting all agiletransition.se sites.

## Scheduled Workflows

| Workflow | Schedule | What it does |
|----------|----------|-------------|
| **Daily Backup** | 02:00 CET daily | pg_dump ForFor + Voxtera databases, 14-day rotation |
| **Health Check** | Manual only | HTTP checks all 10 sites + server disk/memory/containers |
| **Weekly Update** | Sunday 03:00 CET | OS updates, Docker image pulls, container restarts |
| **Collect Dashboard Metrics** | Every 6 hours | Snapshots usage/risk/status JSON into `docs/data/` for the dashboard |

All workflows can also be triggered manually from GitHub Actions.

GitHub sends email notifications automatically on failure.

## Dashboard

A static dashboard lives in `docs/`, fed by the **Collect Dashboard Metrics** workflow.
It has three tabs:

- **Status** — sites up/down, container state/health/CPU/mem, latest backup, system summary.
- **Usage** — CPU load, memory, disk, network rate, container count, sites OK, DB size, backup-dir size — over 2 d / 7 d / 30 d / all.
- **Risks** — prioritised list of issues (pending OS / security updates, reboot-required, stale backups, unhealthy or stopped containers, low memory or disk, UFW disabled, SSH brute-force pressure, TLS certificates expiring soon).

### Enabling GitHub Pages

Repo → Settings → Pages → **Source: Deploy from a branch** →
Branch: `main` (or the branch this repo publishes from) · Folder: `/docs`.
The dashboard is then served at `https://<owner>.github.io/server-maintenance/`.

### Server prerequisite

The collector uses `jq`. Install once on the VPS:

```bash
sudo apt-get install -y jq
```

Then trigger **Collect Dashboard Metrics** once manually to generate the first
`docs/data/latest.json` and `docs/data/history.jsonl`.

## One-time Setup

### Server Hardening

SSH into the server and run:

```bash
sudo bash /tmp/harden-server.sh
```

This sets up:
- UFW firewall (ports 22, 80, 443 only — port 81 blocked)
- fail2ban (SSH brute force protection)
- SSH hardening (no root login, no password auth)
- Unattended upgrades (security **and** non-security, auto-reboot at 04:00 only when an update requires it)
- Docker log rotation

### After Hardening: Access NPM Admin

Port 81 is blocked by the firewall. Use an SSH tunnel:

```bash
ssh -L 8081:localhost:81 deploy@89.167.90.112
```

Then open http://localhost:8081 in your browser.

## Required GitHub Secrets

These must be configured in this repo's settings:

- `SERVER_HOST` — Server IP (89.167.90.112)
- `SERVER_USER` — SSH user (deploy)
- `SERVER_SSH_KEY` — SSH private key

## Hosted Sites

| Site | Type | URL |
|------|------|-----|
| azprofil | Static | azprofil.agiletransition.se |
| azp2b | Static | padeltobusiness.se (was azp2b.agiletransition.se, now 301) |
| agiletransition | Static | agiletransition.agiletransition.se |
| hemsidor | Static | hemsidor.agiletransition.se |
| azstore | Static | azstore.agiletransition.se |
| schiffer | Static | schiffer.agiletransition.se |
| seatower | Static | seatower.agiletransition.se |
| stegvis | Docker App | stegvis.agiletransition.se |
| voxtera | Docker App + PostgreSQL | voxtera.agiletransition.se |
| forfor | Docker App + PostgreSQL | forfor.agiletransition.se |
| energi | Home server (Freja7) + Tailscale | energi.agiletransition.se |

## Energi Dashboard

Unlike every other row above, energi does **not** run on this VPS at all —
it runs on Freja7, an always-on Ubuntu Server at Thomas's home that reads
two meters (Sungrow inverter, Shelly Pro 3EM) and the Easee/Qvantum cloud
APIs directly over the home LAN. This VPS only proxies it: Freja7 makes an
outbound [Tailscale](https://tailscale.com) connection to this server, and
NPM forwards `energi.agiletransition.se` to Freja7's Tailscale address, with
Let's Encrypt + an access list in front — expect HTTP 401 without
credentials. There is no `wg-hem` WireGuard tunnel and no `energi` Docker
container on this VPS; an earlier plan used both, but the design changed
before either was deployed here. If `ufw status` still shows `51820/udp`
allowed, that rule predates the pivot and is safe to remove.

Setup and the Tailscale/NPM runbook live in
[Tschiffer46/energi](https://github.com/Tschiffer46/energi) (`HEMSERVER.md`
and `RUNBOOK.md`). Its SQLite database is covered by the daily backup as
`energi-*.db.gz`, pulled from Freja7 over the same Tailscale link (see
`scripts/backup-databases.sh` — skipped automatically until
`FREJA7_TAILSCALE_IP` is filled in there, a one-time step done once Tailscale
is up).
