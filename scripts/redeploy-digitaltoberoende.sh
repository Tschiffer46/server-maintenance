#!/bin/bash
# Recreates the digitaltoberoende (euproof.eu) container with the EXACT same mounts
# as the deploy workflow in Tschiffer46/digitaltoberoende (.github/workflows/deploy.yml).
# Use this whenever the container must be recreated outside a normal deploy (e.g. after
# pulling a new nginx:alpine). Recreating it any other way — in particular from a compose
# definition missing the nginx.conf/.htpasswd mounts — silently drops the dev-phase
# password protection on euproof.eu.
set -euo pipefail

SITE_DIR="$HOME/hosting/sites/client-digitaltoberoende"

# All three deployed artifacts must exist; refuse to start an unprotected container.
for f in "$SITE_DIR/dist/index.html" "$SITE_DIR/nginx.conf" "$SITE_DIR/.htpasswd"; do
  if [ ! -e "$f" ]; then
    echo "ERROR: $f missing — run the deploy workflow in Tschiffer46/digitaltoberoende first" >&2
    exit 1
  fi
done

# Detect the Docker network used by Nginx Proxy Manager
NPM_NETWORK=""
for name in nginx-proxy-manager npm nginx-proxy; do
  NPM_NETWORK=$(docker inspect "$name" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null || true)
  [ -n "$NPM_NETWORK" ] && break
done
if [ -z "$NPM_NETWORK" ]; then
  NPM_NETWORK=$(docker network ls --format '{{.Name}}' | grep -i web | head -1 || true)
fi
NPM_NETWORK="${NPM_NETWORK:-web}"
echo "Using Docker network: $NPM_NETWORK"

docker stop digitaltoberoende 2>/dev/null || true
docker rm digitaltoberoende 2>/dev/null || true
docker run -d \
  --name digitaltoberoende \
  --restart unless-stopped \
  --network "$NPM_NETWORK" \
  -v "$SITE_DIR/dist:/usr/share/nginx/html:ro" \
  -v "$SITE_DIR/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
  -v "$SITE_DIR/.htpasswd:/etc/nginx/.htpasswd:ro" \
  nginx:alpine

sleep 2
docker ps --filter name=digitaltoberoende --format "{{.Status}}"
