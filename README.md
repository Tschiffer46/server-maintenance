# Server Maintenance

Automated maintenance for the Hetzner VPS (89.167.90.112) hosting all agiletransition.se sites.

## Scheduled Workflows

| Workflow | Schedule | What it does |
|----------|----------|-------------|
| **Daily Backup** | 02:00 CET daily | `pg_dump` every database in `scripts/backup-databases.sh`, 14-day rotation |
| **Health Check** | Manual only | HTTP checks every site in `scripts/sites.txt` + server disk/memory/containers |
| **Weekly Update** | Sunday 03:00 CET | OS updates, Docker image pulls, container restarts |
| **Collect Dashboard Metrics** | Every 6 hours | Snapshots usage/risk/status JSON into `docs/data/`, then alerts on critical risks |
| **Restore euproof.eu** | Manual only | Recreates the `digitaltoberoende` container behind euproof.eu, then verifies the site answers and is still gated |

All workflows can also be triggered manually from GitHub Actions.

### What actually alerts you

GitHub emails the repo owner when a **scheduled** workflow fails. That only
helps if a workflow fails when something is wrong, so:

- **Collect Dashboard Metrics** is the standing site/server alert. After it
  commits the snapshot it runs `scripts/check-risks.sh`, which fails the run on
  anything operationally broken — a site down, a dev-phase gate that stopped
  being enforced, no valid backup or one older than 48 h, an empty backup stub,
  a stopped or unhealthy container, a disk over 90 %, a TLS certificate under
  14 days. Worst case you hear about it within six hours.
- Standing posture items (UFW disabled, pending OS updates, reboot required)
  are printed in the run summary but deliberately do **not** fail the run.
  They need a maintenance decision, not an incident response, and a workflow
  that is permanently red is a workflow nobody reads.
- **Health Check** stays manual — it is the on-demand deep check, and the
  metrics gate already covers the same ground on a schedule.

A critical that nobody fixes therefore mails you **four times a day**, because
the condition is still true four times a day. That is the design working, not a
bug in it: the way to stop the mail is to fix or retire the thing it names.
Silencing a rule instead puts the repo back in the state described below, where
everything was green and voxtera served 502 for twelve days.

> Collecting metrics never used to fail, which is how voxtera served 502 for
> twelve days and the nightly backup wrote empty files for five weeks while
> every workflow stayed green.

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

> **The firewall is currently off.** Recent snapshots report
> `ufw_enabled: false` with 0 rules, so port 81 (NPM admin) may be reachable
> from the internet rather than only through the SSH tunnel described below.
> Re-running this script is the fix; the metrics run reports it every six hours.

### After Hardening: Access NPM Admin

Port 81 is blocked by the firewall. Use an SSH tunnel:

```bash
ssh -L 8081:localhost:81 deploy@89.167.90.112
```

Then open http://localhost:8081 in your browser.

## Server-side prerequisites for the weekly update

Two things the weekly update needs that live on the server, not in this repo.
Both fail loudly in the run log with the exact command to fix them, but they
need a one-time SSH session.

Neither has been done: **every weekly run since 2 August (runs 20–25) failed on
these two errors and nothing else** — one failure email every Sunday. The OS
upgrade step has not run in that time, and the three app images have stayed on
whatever tag they were pulled at last.

> Run these on the **Hetzner VPS**, not on Freja7. This repo touches two
> machines and only one of them hosts the sites:
>
> ```bash
> ssh deploy@89.167.90.112     # prompt should read deploy@web-hosting-prod
> ```

**Passwordless sudo for apt.** The update runs over SSH with no TTY, so `sudo`
cannot prompt. Without this every apt step fails with *"a terminal is required
to read the password"* and no OS updates are applied by this workflow —
unattended-upgrades still handles security patches, but the weekly full upgrade
silently does nothing:

```bash
echo 'deploy ALL=(ALL) NOPASSWD: /usr/bin/apt-get' | sudo tee /etc/sudoers.d/90-apt-maintenance
sudo chmod 0440 /etc/sudoers.d/90-apt-maintenance && sudo visudo -c
```

**Registry credentials for ghcr.io.** Pulling the app images (`stegvis`,
`forfor`, `vadskavi`) needs a login, or the pull fails with `denied` and the
containers stay on their current image:

```bash
docker login ghcr.io -u Tschiffer46   # paste a PAT with read:packages as the password
```

## Required GitHub Secrets

These must be configured in this repo's settings:

- `SERVER_HOST` — Server IP (89.167.90.112)
- `SERVER_USER` — SSH user (deploy)
- `SERVER_SSH_KEY` — SSH private key

## Hosted Sites

`Monitored` means the URL is probed by `scripts/sites.txt`, the single list read
by both `health-check.sh` and `check-sites-json.sh`. Add a new public site there
once and both pick it up.

| Site | Type | URL | Monitored |
|------|------|-----|-----------|
| azprofil | Static | azprofil.agiletransition.se | yes |
| azp2b | Static | padeltobusiness.se (was azp2b.agiletransition.se, now 301) | yes |
| agiletransition | Static | agiletransition.se | yes |
| hemsidor | Static | hemsidor.agiletransition.se | yes |
| azstore | Static | azstore.agiletransition.se | yes |
| schiffer | Static + PostgreSQL | schiffer.agiletransition.se | yes |
| seatower | Static | seatower.agiletransition.se | yes |
| stegvis | Docker App + PostgreSQL | stegvis.agiletransition.se | yes |
| forfor | Docker App + PostgreSQL | forfor.agiletransition.se | yes |
| euproof | Static, dev-phase cookie gate | euproof.eu | yes |
| energi | Home server (Freja7) + Tailscale | energi.agiletransition.se | yes |
| ehandel | Static | — internal only | no, by design |
| vadskavi | Docker App + PostgreSQL | — internal only | no, by design |
| client-akeobygg | Static | — internal only | no, by design |

The three internal-only containers run on the VPS but are not reachable from the
public internet, so probing them would produce a permanently red check. They are
listed here so they are not mistaken for a monitoring gap — and they *are*
covered indirectly: the metrics collector alerts if any container stops or turns
unhealthy, and `vadskavi`'s database is backed up like the rest.

**voxtera was decommissioned in August 2026** and removed from the site list,
the backup list and the database-size collector. Its container disappeared from
the server on 17 August; the last restorable dump was 24 July and 14-day
rotation has since deleted it.

**euproof.eu is down (502), and this VPS is what serves it.** The earlier claim
that the site had moved off this server was wrong. `euproof.eu` resolves to
89.167.90.112, NPM here terminates its TLS, and the `digitaltoberoende`
container was the upstream behind that proxy host. Removing that container on
30 August as "leftover cleanup" is what took the site down: NPM kept answering
on a valid certificate — which is why the site looked alive — and returned 502
for everything behind it. Every metrics run since `2026-08-30T18:26Z` has
reported it.

**The site is to be restored here.** Run the **Restore euproof.eu** workflow
(Actions → Restore euproof.eu → Run workflow). It uploads and runs
`scripts/redeploy-digitaltoberoende.sh` on the VPS over the same SSH secrets
every other workflow uses, then probes the site and fails if it is not actually
back — or is back but answering 200 without the preview cookie.

It needs `dist/`, `nginx.conf` and `.htpasswd` under
`~/hosting/sites/client-digitaltoberoende` on the VPS; the deploy workflow in
[Tschiffer46/digitaltoberoende](https://github.com/Tschiffer46/digitaltoberoende)
is what puts them there. If they are gone the redeploy script stops with the
missing path rather than starting a container that would serve the site
unprotected — run that deploy first, then this workflow again.

By hand, if you would rather:

```bash
scp scripts/redeploy-digitaltoberoende.sh deploy@89.167.90.112:/tmp/
ssh deploy@89.167.90.112 'bash /tmp/redeploy-digitaltoberoende.sh'
```

Retiring the domain instead would mean pointing DNS away, deleting the NPM
proxy host, and only then dropping the URL from `scripts/sites.txt` — dropping
it from the site list alone silences the alert while euproof.eu still answers
502 from this server.

### Server-side cleanup — done, and what it cost

Both leftover containers are gone: weekly run 24 (30 August) still reported
`moss` and `digitaltoberoende` as running but unmanaged, run 25 (6 September)
reports neither. Removing `moss` was right. Removing `digitaltoberoende` is
what took euproof.eu down — see the hosted-sites table above.

**Open: the metrics collector does not list every container.** Run 24 saw both
containers running via `docker ps` on 30 August, while all three metrics
snapshots from that same day list 17 containers and neither of them — in fact
neither has ever appeared in a snapshot. `scripts/collect-metrics.sh`
enumerates with `docker ps -a`, so the two should agree and do not. Until that
is explained, "container stopped or unhealthy" — a critical in
`scripts/check-risks.sh` — can only be trusted for containers the collector
already lists, and a container that vanishes the way this one did raises
nothing. Compare the two lists on the VPS:

```bash
ssh deploy@89.167.90.112
docker ps -a --format '{{.Names}}'
```

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
