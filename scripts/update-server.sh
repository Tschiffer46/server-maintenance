#!/bin/bash
# Note: deliberately NOT using `set -e` — this is a maintenance run that must attempt
# every step and report a count at the end, rather than abort on the first hiccup
# (e.g. a transient `apt-get update` mirror error) and exit "successfully early".
set -uo pipefail

LOG="/tmp/maintenance-$(date +%Y%m%d).log"
HOSTING_DIR="/home/deploy/hosting"
ERRORS=0

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

# 1. OS package updates (security AND non-security)
log "=== OS Updates ==="
sudo apt-get update >> "$LOG" 2>&1 || { log "ERROR: apt-get update failed"; ERRORS=$((ERRORS+1)); }
sudo DEBIAN_FRONTEND=noninteractive apt-get -y upgrade >> "$LOG" 2>&1 || { log "ERROR: apt upgrade failed"; ERRORS=$((ERRORS+1)); }
sudo DEBIAN_FRONTEND=noninteractive apt-get -y autoremove >> "$LOG" 2>&1 || true

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
  docker compose pull "$svc" >> "$LOG" 2>&1 || { log "ERROR: Failed to pull $svc"; ERRORS=$((ERRORS+1)); }
  docker compose up -d "$svc" >> "$LOG" 2>&1 || { log "ERROR: Failed to restart $svc"; ERRORS=$((ERRORS+1)); }
done

# 5. Recreate proxy manager if base image updated
log "=== Updating Nginx Proxy Manager ==="
docker compose up -d --force-recreate nginx-proxy-manager >> "$LOG" 2>&1 || { log "ERROR: Failed to restart proxy manager"; ERRORS=$((ERRORS+1)); }

# 6. Wait for services to stabilize
sleep 10

# 7. Post-update health check.
#    Expectations come from docker-compose.yml itself rather than a hand-kept
#    list, so decommissioning a service updates this check automatically.
#    Compare by SERVICE name, not container name — compose services may set
#    container_name (nginx-proxy-manager runs as the container "proxy-manager"),
#    so matching service names against `docker ps` output reports false failures.
log "=== Post-update health check ==="
RUNNING_SERVICES=$(docker compose ps --services --filter "status=running" 2>/dev/null | sort)
for name in $COMPOSE_SERVICES; do
  if printf '%s\n' "$RUNNING_SERVICES" | grep -qx "$name"; then
    log "OK: $name is running"
  else
    log "ERROR: $name is NOT running"
    ERRORS=$((ERRORS+1))
  fi
done

# Containers running outside this compose project are informational, not
# failures — this is how a manually-run container (or a leftover) becomes
# visible instead of silent.
COMPOSE_CONTAINERS=$(docker compose ps -a --format '{{.Name}}' 2>/dev/null | sort)
if [ -n "$COMPOSE_CONTAINERS" ]; then
  for name in $(docker ps --format '{{.Names}}' | sort); do
    printf '%s\n' "$COMPOSE_CONTAINERS" | grep -qx "$name" \
      || log "NOTE: $name is running but is not managed by docker-compose.yml"
  done
fi

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
