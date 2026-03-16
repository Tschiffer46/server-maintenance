#!/bin/bash
set -euo pipefail

ERRORS=0

echo "=== Server Internal Health Check: $(date) ==="

# 1. Disk space
echo ""
echo "--- Disk Usage ---"
DISK_USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
df -h /
if [ "$DISK_USAGE" -gt 85 ]; then
  echo "WARN: Disk usage at ${DISK_USAGE}%"
  ERRORS=$((ERRORS+1))
fi

# 2. Memory
echo ""
echo "--- Memory ---"
free -m
MEM_AVAIL=$(free -m | awk '/Mem:/ {print $7}')
if [ "$MEM_AVAIL" -lt 200 ]; then
  echo "WARN: Available memory low (${MEM_AVAIL}MB)"
  ERRORS=$((ERRORS+1))
fi

# 3. Docker containers
echo ""
echo "--- Docker Containers ---"
docker ps --format "table {{.Names}}\t{{.Status}}" | sort

# Check for unhealthy or exited containers
UNHEALTHY=$(docker ps --filter "health=unhealthy" --format "{{.Names}}" 2>/dev/null || true)
if [ -n "$UNHEALTHY" ]; then
  echo "WARN: Unhealthy containers: $UNHEALTHY"
  ERRORS=$((ERRORS+1))
fi

EXITED=$(docker ps -a --filter "status=exited" --format "{{.Names}}" 2>/dev/null || true)
if [ -n "$EXITED" ]; then
  echo "WARN: Exited containers: $EXITED"
  ERRORS=$((ERRORS+1))
fi

# 4. Backups
echo ""
echo "--- Backup Status ---"
if [ -d /home/deploy/backups ]; then
  LATEST=$(ls -t /home/deploy/backups/*.sql.gz 2>/dev/null | head -1)
  if [ -n "$LATEST" ]; then
    AGE_HOURS=$(( ($(date +%s) - $(stat -c%Y "$LATEST")) / 3600 ))
    echo "Latest backup: $(basename "$LATEST") (${AGE_HOURS}h ago)"
    if [ "$AGE_HOURS" -gt 48 ]; then
      echo "WARN: Latest backup is more than 48 hours old"
      ERRORS=$((ERRORS+1))
    fi
  else
    echo "WARN: No backups found"
    ERRORS=$((ERRORS+1))
  fi
  du -sh /home/deploy/backups/
else
  echo "WARN: Backup directory does not exist"
  ERRORS=$((ERRORS+1))
fi

# 5. Uptime and load
echo ""
echo "--- System ---"
uptime

# 6. Check if reboot required
if [ -f /var/run/reboot-required ]; then
  echo "WARN: System reboot required"
  ERRORS=$((ERRORS+1))
fi

echo ""
echo "=== Results: $ERRORS warning(s) ==="
exit $ERRORS
