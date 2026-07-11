#!/bin/bash
# STEG 7b — Slutverifiering. Körs PÅ SERVERN (som deploy, utan sudo):
#
#   bash /home/deploy/hosting/energi/scripts/70-verify.sh
#   # eller med inloggning för att även verifiera datainnehållet utifrån:
#   ENERGI_AUTH="användare:lösenord" bash .../70-verify.sh
#
# Kontrollerar allt ur målbilden:
#   1. https://<domän> kräver inloggning (401 utan, 200 med)
#   2. /api/now svarar med färsk data
#   3. En NY mätpunkt skrivs inom 5 minuter (räknar databasrader, väntar 6 min)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
source "$SCRIPT_DIR/config.env"

FAIL=0

echo "== 1) Åtkomstskydd på https://${ENERGI_DOMAIN} =="
NOAUTH="$(curl -o /dev/null -s -w "%{http_code}" -m 15 "https://${ENERGI_DOMAIN}/api/now" || echo 000)"
case "$NOAUTH" in
  401|403)
    echo "✅ Utan inloggning: HTTP $NOAUTH — dashboarden ligger INTE öppen mot internet." ;;
  200)
    echo "❌ HTTP 200 UTAN inloggning — åtkomstskyddet saknas! Koppla Access List i NPM (steg 7)."
    FAIL=1 ;;
  000)
    echo "❌ Inget svar alls — DNS-posten eller NPM-proxyn är inte på plats än (steg 7)."
    FAIL=1 ;;
  *)
    echo "⚠️  Oväntat svar: HTTP $NOAUTH — kolla NPM-loggen."
    FAIL=1 ;;
esac

if [[ -n "${ENERGI_AUTH:-}" ]]; then
  WITHAUTH="$(curl -o /dev/null -s -w "%{http_code}" -m 15 -u "$ENERGI_AUTH" "https://${ENERGI_DOMAIN}/api/now" || echo 000)"
  if [[ "$WITHAUTH" == "200" ]]; then
    echo "✅ Med inloggning: HTTP 200. Färskt svar från /api/now:"
    curl -s -m 15 -u "$ENERGI_AUTH" "https://${ENERGI_DOMAIN}/api/now" | head -c 400
    echo ""
  else
    echo "❌ Med inloggning: HTTP $WITHAUTH — fel användare/lösenord eller trasig proxy."
    FAIL=1
  fi
else
  echo "(Hoppar över inloggat test — kör med ENERGI_AUTH=\"user:pass\" för att ta med det.)"
fi

echo ""
echo "== 2) /api/now direkt mot containern =="
if curl -s -m 10 "http://127.0.0.1:8420/api/now" | head -c 400; then
  echo ""
  echo "✅ Containern svarar lokalt."
else
  echo "❌ Containern svarar inte — se 'docker logs energi'."
  exit 1
fi

echo ""
echo "== 3) Skrivs nya mätpunkter? (räknar rader, väntar 6 min, räknar igen) =="
count_rows() {
  docker exec energi sh -c '
    for t in $(sqlite3 /app/energi.db ".tables"); do
      sqlite3 /app/energi.db "SELECT COUNT(*) FROM $t"
    done' | awk '{s+=$1} END {print s+0}'
}
BEFORE="$(count_rows)"
echo "Rader i databasen nu: $BEFORE — väntar 6 minuter (pollintervall är 5)..."
sleep 360
AFTER="$(count_rows)"
if (( AFTER > BEFORE )); then
  echo "✅ $((AFTER - BEFORE)) nya rader på 6 min — pollern skriver mätpunkter."
else
  echo "❌ Inga nya rader — pollern kör inte."
  echo "   Vanligaste orsaken: appen startades med uvicorn-CLI (APP_CMD i .env)"
  echo "   men pollern startas bara under 'if __name__ == \"__main__\":' i app.py."
  echo "   Fix: lägg host=\"0.0.0.0\" i uvicorn.run(...) i app/app.py, ta bort"
  echo "   APP_CMD-raden ur .env och kör: docker compose up -d --force-recreate"
  FAIL=1
fi

echo ""
echo "== Containerstatus =="
docker inspect -f 'Health: {{.State.Health.Status}}  Startad: {{.State.StartedAt}}' energi
docker logs --tail 10 energi

echo ""
if [[ "$FAIL" == "0" ]]; then
  echo "🎉 Allt grönt! Kvar: öppna https://${ENERGI_DOMAIN} i mobilen på MOBILNÄT"
  echo "   (inte WiFi) och logga in — sedan steg 8 (städa Macen)."
else
  echo "Minst en kontroll föll — se ovan."
  exit 1
fi
