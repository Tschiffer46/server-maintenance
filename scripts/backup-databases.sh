#!/bin/bash
set -euo pipefail

BACKUP_DIR="/home/deploy/backups"
COMPOSE_FILE="/home/deploy/hosting/docker-compose.yml"
DATE=$(date +%Y%m%d_%H%M)
RETAIN_DAYS=14
MIN_DUMP_BYTES=100
ERRORS=0

mkdir -p "$BACKUP_DIR"

echo "=== Database Backup: $DATE ==="

# One entry per PostgreSQL container: label:container:user:database
#
# Keep this in sync with the *-db containers actually running on the server
# (`docker ps`) — a database missing from this list is silently never backed up.
# voxtera was removed here when it was decommissioned in August 2026.
DATABASES=(
  "forfor:forfor-db:forfor:forfor"
  "stegvis:stegvis-db:stegvis:stegvis"
  "vadskavi:vadskavi-db:vadskavi:vadskavi"
  "schiffer:schiffer-db:schiffer:schiffer"
)

for entry in "${DATABASES[@]}"; do
  IFS=: read -r label container user db <<<"$entry"
  target="$BACKUP_DIR/$label-$DATE.sql.gz"

  echo "Backing up $label..."
  if ! docker compose -f "$COMPOSE_FILE" exec -T "$container" \
      pg_dump -U "$user" -d "$db" 2>/dev/null | gzip > "$target"; then
    echo "ERROR: $label backup failed (container $container)"
    # Remove the empty/partial file. A failed gzip still leaves a ~20-byte
    # archive behind, and that stub is newer than the last good dump — it
    # becomes the "latest backup" the dashboard reports, making a broken
    # backup look fresh. Deleting it keeps the freshness signal honest.
    rm -f "$target"
    ERRORS=$((ERRORS+1))
    continue
  fi

  SIZE=$(stat -c%s "$target" 2>/dev/null || stat -f%z "$target" 2>/dev/null || echo 0)
  if [ "$SIZE" -lt "$MIN_DUMP_BYTES" ]; then
    echo "ERROR: $label dump is suspiciously small (${SIZE} bytes) — discarding"
    rm -f "$target"
    ERRORS=$((ERRORS+1))
  else
    echo "OK: $(basename "$target") - $(numfmt --to=iec "$SIZE" 2>/dev/null || echo "${SIZE} bytes")"
  fi
done

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
    echo "OK: energi-$DATE.db.gz"
  else
    echo "ERROR: energi backup failed"
    rm -f "$BACKUP_DIR/energi-$DATE.db" "$BACKUP_DIR/energi-$DATE.db.gz"
    ERRORS=$((ERRORS+1))
  fi
fi

# Rotate: delete backups older than 14 days
DELETED=$(find "$BACKUP_DIR" \( -name "*.sql.gz" -o -name "*.db.gz" \) -mtime +$RETAIN_DAYS -delete -print | wc -l)
echo "Rotated: $DELETED old backup(s) removed"

# Summary
echo "=== Backup summary ==="
echo "Total backups on disk:"
ls -lh "$BACKUP_DIR"/*.gz 2>/dev/null || echo "  (none)"
du -sh "$BACKUP_DIR" 2>/dev/null

echo "=== Complete. Errors: $ERRORS ==="
exit $ERRORS
