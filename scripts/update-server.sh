#!/bin/bash
set -euo pipefail

LOG="/tmp/maintenance-$(date +%Y%m%d).log"
ERRORS=0

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

# 1. OS package updates
log "=== OS Updates ==="
sudo apt-get update >> "$LOG" 2>&1
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y >> "$LOG" 2>&1 || { log "ERROR: apt upgrade failed"; ERRORS=$((ERRORS+1)); }

# 2. Pull latest base images
log "=== Docker Image Updates ==="
for img in nginx:alpine node:20-alpine postgres:16-alpine jc21/nginx-proxy-manager:latest; do
  docker pull "$img" >> "$LOG" 2>&1 || { log "ERROR: Failed to pull $img"; ERRORS=$((ERRORS+1)); }
done

# 3. Recreate static site containers (picks up new nginx:alpine)
log "=== Restarting static site containers ==="
cd /home/deploy/hosting
for svc in azprofil azp2b agiletransition hemsidor azstore schiffer seatower; do
  docker compose up -d --force-recreate "$svc" >> "$LOG" 2>&1 || { log "ERROR: Failed to restart $svc"; ERRORS=$((ERRORS+1)); }
done

# 4. Pull and restart GHCR app images
log "=== Updating Docker apps ==="
docker compose pull stegvis voxtera forfor >> "$LOG" 2>&1 || { log "ERROR: Failed to pull app images"; ERRORS=$((ERRORS+1)); }
docker compose up -d stegvis voxtera forfor >> "$LOG" 2>&1 || { log "ERROR: Failed to restart apps"; ERRORS=$((ERRORS+1)); }

# 5. Recreate proxy manager if base image updated
log "=== Updating Nginx Proxy Manager ==="
docker compose up -d --force-recreate nginx-proxy-manager >> "$LOG" 2>&1 || { log "ERROR: Failed to restart proxy manager"; ERRORS=$((ERRORS+1)); }

# 6. Wait for services to stabilize
sleep 10

# 7. Quick health check after update
log "=== Post-update health check ==="
CONTAINERS=$(docker ps --format '{{.Names}}' | sort)
EXPECTED="agiletransition azp2b azprofil azstore forfor forfor-db hemsidor proxy-manager schiffer seatower stegvis voxtera voxtera-db"
for name in $EXPECTED; do
  if echo "$CONTAINERS" | grep -q "^${name}$"; then
    log "OK: $name is running"
  else
    log "ERROR: $name is NOT running"
    ERRORS=$((ERRORS+1))
  fi
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
