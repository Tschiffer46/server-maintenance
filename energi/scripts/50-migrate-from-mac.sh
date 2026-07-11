#!/bin/bash
# STEG 5 — Flytta appen från Macen. Körs PÅ MACEN (från repots rot):
#
#   bash scripts/50-migrate-from-mac.sh
#
# Gör i ordning:
#   1. Stoppar och AVAKTIVERAR launchd-jobbet (launchctl unload -w) så att
#      Mac-appen inte startar igen vid omstart — inga fler skrivningar i databasen.
#   2. Checkpointar SQLite (WAL -> huvudfil) och kör integrity_check.
#   3. Kopierar deploy-kitet + app.py/index.html/energi.db till servern.
#   4. Verifierar med checksumma att databasen kom fram intakt.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
source "$SCRIPT_DIR/config.env"

echo "== Förkontroller =="
for f in app.py index.html energi.db; do
  if [[ ! -f "$MAC_APP_DIR/$f" ]]; then
    echo "FEL: $MAC_APP_DIR/$f saknas — är MAC_APP_DIR rätt i config.env?" >&2
    exit 1
  fi
done
ssh -o ConnectTimeout=10 "$HETZNER_SSH" true \
  || { echo "FEL: når inte $HETZNER_SSH via SSH." >&2; exit 1; }
echo "✅ Filer på plats och SSH till servern fungerar."

echo ""
echo "== 1) Stoppar Mac-appen =="
PLISTS="$(grep -l -i energi ~/Library/LaunchAgents/*.plist 2>/dev/null || true)"
if [[ -n "$PLISTS" ]]; then
  while IFS= read -r p; do
    # unload -w sätter disabled-flaggan så jobbet INTE återuppstår vid omstart
    launchctl unload -w "$p" 2>/dev/null || true
    echo "Avaktiverade launchd-jobb: $p"
  done <<< "$PLISTS"
else
  echo "Inget launchd-jobb som nämner 'energi' hittades i ~/Library/LaunchAgents."
fi

if lsof -ti :8420 > /dev/null 2>&1; then
  echo "En process lyssnar fortfarande på port 8420:"
  lsof -i :8420
  read -r -p "Döda den nu? Skriv JA: " ANSWER
  if [[ "$ANSWER" == "JA" ]]; then
    kill "$(lsof -ti :8420)" || true
    sleep 2
  fi
fi
if lsof -ti :8420 > /dev/null 2>&1; then
  echo "FEL: appen kör fortfarande — stoppa den manuellt och kör om scriptet." >&2
  exit 1
fi
echo "✅ Inget lyssnar på 8420 — inga fler skrivningar i energi.db."

echo ""
echo "== 2) Checkpoint + integritetskontroll av databasen =="
sqlite3 "$MAC_APP_DIR/energi.db" "PRAGMA wal_checkpoint(TRUNCATE);" > /dev/null || true
INTEG="$(sqlite3 "$MAC_APP_DIR/energi.db" "PRAGMA integrity_check;")"
if [[ "$INTEG" != "ok" ]]; then
  echo "FEL: integrity_check gav: $INTEG — avbryter, ingenting kopierat." >&2
  exit 1
fi
echo "✅ integrity_check: ok ($(du -h "$MAC_APP_DIR/energi.db" | cut -f1) databas)"

echo ""
echo "== 3) Kopierar till servern ($DEPLOY_DIR) =="
ssh "$HETZNER_SSH" "mkdir -p '$DEPLOY_DIR/app' '$DEPLOY_DIR/scripts'"
rsync -av --exclude app "$SCRIPT_DIR/../deploy/" "$HETZNER_SSH:$DEPLOY_DIR/"
rsync -av "$SCRIPT_DIR/" "$HETZNER_SSH:$DEPLOY_DIR/scripts/"
rsync -av "$MAC_APP_DIR/app.py" "$MAC_APP_DIR/index.html" "$MAC_APP_DIR/energi.db" \
  "$HETZNER_SSH:$DEPLOY_DIR/app/"
# Om WAL/SHM mot förmodan finns kvar efter checkpointen: ta med dem också
for f in energi.db-wal energi.db-shm; do
  [[ -f "$MAC_APP_DIR/$f" ]] && rsync -av "$MAC_APP_DIR/$f" "$HETZNER_SSH:$DEPLOY_DIR/app/"
done

echo ""
echo "== 4) Verifierar att databasen kom fram intakt =="
LOCAL_MD5="$(md5 -q "$MAC_APP_DIR/energi.db")"
REMOTE_MD5="$(ssh "$HETZNER_SSH" "md5sum '$DEPLOY_DIR/app/energi.db'" | awk '{print $1}')"
if [[ "$LOCAL_MD5" == "$REMOTE_MD5" ]]; then
  echo "✅ Checksumman stämmer ($LOCAL_MD5) — historiken är säkrad på servern."
else
  echo "FEL: checksummorna skiljer sig (Mac: $LOCAL_MD5, server: $REMOTE_MD5) — kör om scriptet." >&2
  exit 1
fi

echo ""
echo "================================================================"
echo " Migrering av filerna klar! Nästa: steg 6 på servern:"
echo "   ssh $HETZNER_SSH"
echo "   bash $DEPLOY_DIR/scripts/60-deploy.sh"
echo ""
echo " Macens app är stoppad och avaktiverad, men ~/energi ligger kvar"
echo " orörd som backup tills allt är verifierat (städning = steg 8)."
echo "================================================================"
