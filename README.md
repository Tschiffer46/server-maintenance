# Server Maintenance

Automated maintenance for the Hetzner VPS (89.167.90.112) hosting all agiletransition.se sites.

## Scheduled Workflows

| Workflow | Schedule | What it does |
|----------|----------|-------------|
| **Daily Backup** | 02:00 CET daily | pg_dump ForFor + Voxtera databases, 14-day rotation |
| **Health Check** | Every 6 hours | HTTP checks all 10 sites + server disk/memory/containers |
| **Weekly Update** | Sunday 03:00 CET | OS updates, Docker image pulls, container restarts |

All workflows can also be triggered manually from GitHub Actions.

GitHub sends email notifications automatically on failure.

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
- Unattended security upgrades
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
| azp2b | Static | azp2b.agiletransition.se |
| agiletransition | Static | agiletransition.agiletransition.se |
| hemsidor | Static | hemsidor.agiletransition.se |
| azstore | Static | azstore.agiletransition.se |
| schiffer | Static | schiffer.agiletransition.se |
| seatower | Static | seatower.agiletransition.se |
| stegvis | Docker App | stegvis.agiletransition.se |
| voxtera | Docker App + PostgreSQL | voxtera.agiletransition.se |
| forfor | Docker App + PostgreSQL | forfor.agiletransition.se |
