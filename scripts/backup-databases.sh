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

# Energi dashboard (SQLite) — does NOT run on this server. It runs on
# Freja7, Thomas's home server, reached over Tailscale (see
# Tschiffer46/energi RUNBOOK.md). sqlite3's .backup is safe against
# concurrent writes from the poller.
#
# One-time setup on THIS server before this block does anything:
#   1. RUNBOOK.md steps 1-2 in Tschiffer46/energi (Tailscale on both ends)
#   2. ssh-keygen -t ed25519 -f ~/.ssh/energi-backup -N ""
#   3. Copy ~/.ssh/energi-backup.pub into Freja7's ~/.ssh/authorized_keys
#      for the user that owns /opt/energi (see HEMSERVER.md)
#   4. Fill in FREJA7_TAILSCALE_IP and FREJA7_USER below
# Skipped silently until FREJA7_TAILSCALE_IP is filled in.
FREJA7_TAILSCALE_IP=""
FREJA7_USER="thomas"
if [ -n "$FREJA7_TAILSCALE_IP" ]; then
  echo "Backing up energi (Freja7, via Tailscale)..."
  SSH_KEY="$HOME/.ssh/energi-backup"
  SSH_ENERGI="ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -i $SSH_KEY $FREJA7_USER@$FREJA7_TAILSCALE_IP"
  if $SSH_ENERGI 'sqlite3 /opt/energi/energi.db ".backup /tmp/energi-backup.db"' \
    && scp -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" \
       "$FREJA7_USER@$FREJA7_TAILSCALE_IP:/tmp/energi-backup.db" "$BACKUP_DIR/energi-$DATE.db" \
    && gzip -f "$BACKUP_DIR/energi-$DATE.db"; then
    $SSH_ENERGI 'rm -f /tmp/energi-backup.db'
  else
    echo "ERROR: energi backup failed"
    ERRORS=$((ERRORS+1))
  fi
fi

# Verify backups are non-empty
for f in "$BACKUP_DIR"/*-"$DATE".sql.gz "$BACKUP_DIR"/*-"$DATE".db.gz; do
  [ -e "$f" ] || continue
  SIZE=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null)
  if [ "$SIZE" -lt 100 ]; then
    echo "ERROR: Backup $f is suspiciously small (${SIZE} bytes)"
    ERRORS=$((ERRORS+1))
  else
    echo "OK: $(basename "$f") - $(numfmt --to=iec "$SIZE" 2>/dev/null || echo "${SIZE} bytes")"
  fi
done

# Rotate: delete backups older than 14 days
DELETED=$(find "$BACKUP_DIR" \( -name "*.sql.gz" -o -name "*.db.gz" \) -mtime +$RETAIN_DAYS -delete -print | wc -l)
echo "Rotated: $DELETED old backup(s) removed"

# Summary
echo "=== Backup summary ==="
echo "Total backups on disk:"
ls -lh "$BACKUP_DIR"/*.gz 2>/dev/null || echo "  (none)"
du -sh "$BACKUP_DIR" 2>/dev/null

exit $ERRORS
