#!/bin/bash
set -euo pipefail

BACKUP_DIR="/home/deploy/backups"
COMPOSE_FILE="/home/deploy/hosting/docker-compose.yml"
DATE=$(date +%Y%m%d_%H%M)
RETAIN_DAYS=14
ERRORS=0

mkdir -p "$BACKUP_DIR"

echo "=== Database Backup: $DATE ==="

# ForFor database
echo "Backing up ForFor..."
docker compose -f "$COMPOSE_FILE" exec -T forfor-db \
  pg_dump -U forfor -d forfor 2>/dev/null | gzip > "$BACKUP_DIR/forfor-$DATE.sql.gz" || {
  echo "ERROR: ForFor backup failed"
  ERRORS=$((ERRORS+1))
}

# Voxtera database
echo "Backing up Voxtera..."
docker compose -f "$COMPOSE_FILE" exec -T voxtera-db \
  pg_dump -U voxtera -d voxtera 2>/dev/null | gzip > "$BACKUP_DIR/voxtera-$DATE.sql.gz" || {
  echo "ERROR: Voxtera backup failed"
  ERRORS=$((ERRORS+1))
}

# Verify backups are non-empty
for f in "$BACKUP_DIR"/*-"$DATE".sql.gz; do
  SIZE=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null)
  if [ "$SIZE" -lt 100 ]; then
    echo "ERROR: Backup $f is suspiciously small (${SIZE} bytes)"
    ERRORS=$((ERRORS+1))
  else
    echo "OK: $(basename "$f") - $(numfmt --to=iec "$SIZE" 2>/dev/null || echo "${SIZE} bytes")"
  fi
done

# Rotate: delete backups older than 14 days
DELETED=$(find "$BACKUP_DIR" -name "*.sql.gz" -mtime +$RETAIN_DAYS -delete -print | wc -l)
echo "Rotated: $DELETED old backup(s) removed"

# Summary
echo "=== Backup summary ==="
echo "Total backups on disk:"
ls -lh "$BACKUP_DIR"/*.sql.gz 2>/dev/null || echo "  (none)"
du -sh "$BACKUP_DIR" 2>/dev/null

exit $ERRORS
