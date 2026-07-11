#!/bin/bash
# STEG 6 — Bygg och starta containern. Körs PÅ SERVERN (som deploy, utan sudo):
#
#   bash /home/deploy/hosting/energi/scripts/60-deploy.sh
#
# Detekterar NPM:s dockernät (samma logik som server-maintenance-repots
# redeploy-script), bygger imagen, startar containern och testar att
# API:t svarar — både lokalt och från NPM:s nät.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
source "$SCRIPT_DIR/config.env"
cd "$DEPLOY_DIR"

echo "== Förkontroller =="
for f in app/app.py app/index.html app/energi.db docker-compose.yml Dockerfile; do
  [[ -f "$f" ]] || { echo "FEL: $DEPLOY_DIR/$f saknas — kör steg 5 (50-migrate-from-mac.sh) först." >&2; exit 1; }
done

echo "== Detekterar Nginx Proxy Managers dockernät =="
NPM_CONTAINER=""
NPM_NETWORK=""
for name in nginx-proxy-manager npm nginx-proxy; do
  NET="$(docker inspect "$name" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null || true)"
  if [[ -n "$NET" ]]; then
    NPM_CONTAINER="$name"
    NPM_NETWORK="$NET"
    break
  fi
done
if [[ -z "$NPM_NETWORK" ]]; then
  NPM_NETWORK="$(docker network ls --format '{{.Name}}' | grep -i web | head -1 || true)"
fi
if [[ -z "$NPM_NETWORK" ]]; then
  echo "FEL: hittar inget NPM-nät. Kolla 'docker network ls' och skriv NPM_NETWORK=<namn> i $DEPLOY_DIR/.env manuellt." >&2
  exit 1
fi
echo "NPM_NETWORK=$NPM_NETWORK" > .env
echo "✅ Använder dockernätet: $NPM_NETWORK (container: ${NPM_CONTAINER:-okänd})"

# I containern måste appen lyssna på 0.0.0.0 (inte 127.0.0.1) för att NPM
# ska nå den. Kör via uvicorn-CLI om app.py inte verkar göra det själv.
if ! grep -q "0\.0\.0\.0" app/app.py; then
  echo "APP_CMD=uvicorn app:app --host 0.0.0.0 --port 8420" >> .env
  echo "⚠️  app.py verkar inte lyssna på 0.0.0.0 — startar via uvicorn-CLI istället."
  echo "   OBS: om pollern bara startas under 'if __name__ == \"__main__\":' i app.py"
  echo "   kommer den INTE igång med uvicorn-CLI. Lägg då hellre host=\"0.0.0.0\""
  echo "   i uvicorn.run(...) i app.py, ta bort APP_CMD-raden ur .env och kör om."
  echo "   (70-verify.sh avslöjar direkt om mätpunkter uteblir.)"
fi

echo ""
echo "== Bygger och startar =="
docker compose up -d --build

echo "Väntar på att containern ska bli frisk (healthcheck, max 90 s)..."
STATUS="starting"
for _ in $(seq 1 18); do
  STATUS="$(docker inspect -f '{{.State.Health.Status}}' energi 2>/dev/null || echo saknas)"
  [[ "$STATUS" == "healthy" ]] && break
  sleep 5
done
if [[ "$STATUS" != "healthy" ]]; then
  echo "❌ Containern blev inte frisk (status: $STATUS). Loggar:"
  docker logs --tail 40 energi
  exit 1
fi
echo "✅ Containern är healthy."

echo ""
echo "== API-test lokalt på servern (127.0.0.1:8420) =="
if curl -s -m 10 "http://127.0.0.1:8420/api/now" | head -c 400; then
  echo ""
  echo "✅ /api/now svarar."
else
  echo "❌ /api/now svarar inte — se 'docker logs energi'."
  exit 1
fi

echo ""
echo "== API-test från NPM:s nät =="
if [[ -n "$NPM_CONTAINER" ]]; then
  if docker exec "$NPM_CONTAINER" curl -s -m 10 -o /dev/null "http://energi:8420/api/now"; then
    echo "✅ NPM når http://energi:8420 — det är den adressen du anger i proxy hosten."
  else
    echo "⚠️  NPM når inte energi:8420 — kolla att båda är på nätet '$NPM_NETWORK' (docker network inspect $NPM_NETWORK)."
  fi
else
  echo "⚠️  Hittade ingen NPM-container att testa från — verifiera manuellt efter NPM-steget."
fi

echo ""
echo "================================================================"
echo " Deploy klar! Nästa: steg 7 i RUNBOOK.md (DNS + NPM-proxy + auth)."
echo " Forward Hostname/IP: energi   Forward Port: 8420"
echo "================================================================"
