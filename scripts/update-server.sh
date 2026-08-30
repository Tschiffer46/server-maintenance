#!/bin/bash
# Note: deliberately NOT using `set -e` — this is a maintenance run that must attempt
# every step and report a count at the end, rather than abort on the first hiccup
# (e.g. a transient `apt-get update` mirror error) and exit "successfully early".
set -uo pipefail

LOG="/tmp/maintenance-$(date +%Y%m%d).log"
HOSTING_DIR="/home/deploy/hosting"
ERRORS=0
REGISTRY_DENIED=0

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

# 1. OS package updates (security AND non-security)
#
# This runs over SSH with no TTY, so sudo cannot prompt for a password. Without
# passwordless sudo every apt step fails with "a terminal is required to read
# the password" — two cryptic errors per run and no OS updates, which is what
# had been happening unnoticed. Check once and say exactly how to fix it.
log "=== OS Updates ==="
if sudo -n true 2>/dev/null; then
  sudo -n apt-get update >> "$LOG" 2>&1 || { log "ERROR: apt-get update failed"; ERRORS=$((ERRORS+1)); }
  sudo -n DEBIAN_FRONTEND=noninteractive apt-get -y upgrade >> "$LOG" 2>&1 || { log "ERROR: apt upgrade failed"; ERRORS=$((ERRORS+1)); }
  sudo -n DEBIAN_FRONTEND=noninteractive apt-get -y autoremove >> "$LOG" 2>&1 || true
else
  log "ERROR: no passwordless sudo for $(whoami) — OS updates skipped"
  log "       Fix once on the server, as a user with sudo:"
  log "         echo '$(whoami) ALL=(ALL) NOPASSWD: /usr/bin/apt-get' | sudo tee /etc/sudoers.d/90-apt-maintenance"
  log "         sudo chmod 0440 /etc/sudoers.d/90-apt-maintenance && sudo visudo -c"
  log "       Until then unattended-upgrades still applies security patches; this weekly full upgrade does not run."
  ERRORS=$((ERRORS+1))
fi

# 2. Pull latest base images
log "=== Docker Image Updates ==="
for img in nginx:alpine node:20-alpine postgres:16-alpine jc21/nginx-proxy-manager:latest; do
  docker pull "$img" >> "$LOG" 2>&1 || { log "ERROR: Failed to pull $img"; ERRORS=$((ERRORS+1)); }
done

cd "$HOSTING_DIR" || { log "ERROR: $HOSTING_DIR not found"; exit 1; }

# Services actually defined in docker-compose.yml right now.
#
# Everything below is checked against this list first. A service that was
# decommissioned on the server but left behind in this script used to abort the
# whole `docker compose pull` — that is how voxtera's removal silently stopped
# stegvis and forfor from being updated for ten weeks. Now a stale name is
# reported on its own line and the rest of the run continues.
COMPOSE_SERVICES=$(docker compose config --services 2>/dev/null | sort)
if [ -z "$COMPOSE_SERVICES" ]; then
  log "ERROR: could not read services from $HOSTING_DIR/docker-compose.yml"
  ERRORS=$((ERRORS+1))
fi
has_service() { printf '%s\n' "$COMPOSE_SERVICES" | grep -qx "$1"; }

# 3. Recreate static site containers (picks up new nginx:alpine)
log "=== Restarting static site containers ==="
for svc in azprofil azp2b agiletransition hemsidor ehandel azstore schiffer seatower client-akeobygg; do
  if ! has_service "$svc"; then
    log "SKIP: $svc is not a service in docker-compose.yml — remove it here if it is gone for good"
    continue
  fi
  docker compose up -d --force-recreate "$svc" >> "$LOG" 2>&1 \
    || { log "ERROR: Failed to restart $svc"; ERRORS=$((ERRORS+1)); }
done

# digitaltoberoende (euproof.eu) must NOT be recreated from a bare compose definition:
# it requires its nginx.conf mount or the dev-phase gate silently disappears. Always
# use the dedicated script. The container was removed from this VPS in August 2026 —
# euproof.eu is still answering, so it is served from somewhere else now. Skip the
# redeploy unless the container is actually here, rather than failing the whole run.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if docker ps -a --format '{{.Names}}' | grep -qx digitaltoberoende; then
  if [ -x "$SCRIPT_DIR/redeploy-digitaltoberoende.sh" ]; then
    "$SCRIPT_DIR/redeploy-digitaltoberoende.sh" >> "$LOG" 2>&1 \
      || { log "ERROR: Failed to restart digitaltoberoende"; ERRORS=$((ERRORS+1)); }
  else
    log "ERROR: $SCRIPT_DIR/redeploy-digitaltoberoende.sh missing — the workflow must upload it alongside this script"
    ERRORS=$((ERRORS+1))
  fi
else
  log "SKIP: digitaltoberoende is not on this host (euproof.eu is served elsewhere)"
fi

# 4. Pull and restart GHCR app images, one service at a time so a single stale
#    or decommissioned app cannot block updates for the others.
log "=== Updating Docker apps ==="
for svc in stegvis forfor vadskavi; do
  if ! has_service "$svc"; then
    log "SKIP: $svc is not a service in docker-compose.yml — remove it here if it is gone for good"
    continue
  fi
  if ! pull_out=$(docker compose pull "$svc" 2>&1); then
    printf '%s\n' "$pull_out" >> "$LOG"
    log "ERROR: Failed to pull $svc"
    case "$pull_out" in
      *denied*|*unauthorized*|*authentication*) REGISTRY_DENIED=1 ;;
    esac
    ERRORS=$((ERRORS+1))
  else
    printf '%s\n' "$pull_out" >> "$LOG"
  fi
  docker compose up -d "$svc" >> "$LOG" 2>&1 || { log "ERROR: Failed to restart $svc"; ERRORS=$((ERRORS+1)); }
done

# One hint rather than one per service. The containers keep running on their
# existing image, so this is a "not updating" problem, not an outage.
if [ "${REGISTRY_DENIED:-0}" = "1" ]; then
  log "       ghcr.io refused the pull — the server's registry credentials are missing or expired."
  log "       Fix once on the server:"
  log "         docker login ghcr.io -u <github-user>   # PAT with read:packages"
  log "       Running containers are unaffected; they simply stay on their current image."
fi

# 5. Recreate proxy manager if base image updated
log "=== Updating Nginx Proxy Manager ==="
docker compose up -d --force-recreate nginx-proxy-manager >> "$LOG" 2>&1 || { log "ERROR: Failed to restart proxy manager"; ERRORS=$((ERRORS+1)); }

# 6. Wait for services to stabilize
sleep 10

# 7. Post-update health check.
#    Expectations come from docker-compose.yml itself rather than a hand-kept
#    list, so decommissioning a service updates this check automatically.
#
#    A compose service may legitimately run OUTSIDE compose: digitaltoberoende
#    is defined in docker-compose.yml but is started by
#    redeploy-digitaltoberoende.sh with `docker run`, because it needs the
#    nginx.conf mount that a bare compose definition would drop. Compose does
#    not consider such a service "running", so check the container name too —
#    otherwise a healthy site is reported as down every week.
log "=== Post-update health check ==="
RUNNING_SERVICES=$(docker compose ps --services --filter "status=running" 2>/dev/null | sort)
RUNNING_CONTAINERS=$(docker ps --format '{{.Names}}' | sort)
for name in $COMPOSE_SERVICES; do
  if printf '%s\n' "$RUNNING_SERVICES" | grep -qx "$name"; then
    log "OK: $name is running"
  elif printf '%s\n' "$RUNNING_CONTAINERS" | grep -qx "$name"; then
    log "OK: $name is running (started outside compose)"
  else
    log "ERROR: $name is NOT running"
    ERRORS=$((ERRORS+1))
  fi
done

# Containers running outside this compose project are informational, not
# failures — this is how a manually-run container (or a leftover) becomes
# visible instead of silent. Services already reported above are skipped.
COMPOSE_CONTAINERS=$(docker compose ps -a --format '{{.Name}}' 2>/dev/null | sort)
for name in $RUNNING_CONTAINERS; do
  printf '%s\n' "$COMPOSE_CONTAINERS" | grep -qx "$name" && continue
  printf '%s\n' "$COMPOSE_SERVICES"   | grep -qx "$name" && continue
  log "NOTE: $name is running but is not managed by docker-compose.yml"
done

# 8. Prune old images
log "=== Cleanup ==="
docker image prune -f >> "$LOG" 2>&1

# 9. Check if reboot needed
if [ -f /var/run/reboot-required ]; then
  log "WARN: Server reboot required for kernel/system updates"
  ERRORS=$((ERRORS+1))
fi

log "=== Complete. Errors: $ERRORS ==="
cat "$LOG"
exit $ERRORS
