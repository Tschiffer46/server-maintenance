#!/bin/bash
#
# One-time setup for the PocketBase container that backs padeltobusiness.se.
#
# Run it on the Hetzner VPS, not on Freja7:
#
#   scp scripts/setup-pocketbase.sh deploy@89.167.90.112:/tmp/
#   ssh deploy@89.167.90.112 'PB_VERSION=<version> bash /tmp/setup-pocketbase.sh'
#
# It only creates files under ~/hosting/pocketbase and builds the image. It does
# NOT touch docker-compose.yml — that edit is printed at the end and made by
# hand, because a script that rewrites the compose file every site depends on is
# a bad trade for the few seconds it saves.
#
# Re-running is safe: the Dockerfile is rewritten, pb_data is never touched.
set -euo pipefail

BASE="$HOME/hosting/pocketbase"

if [ -z "${PB_VERSION:-}" ]; then
  cat >&2 <<'MSG'
ERROR: PB_VERSION is not set.

Pin the version deliberately rather than tracking "latest" — PocketBase has
spent a long time before 1.0 and its API has changed between minor releases,
so an unpinned image can break the site on an unrelated rebuild.

Look up the current version at:
  https://github.com/pocketbase/pocketbase/releases

Then re-run, without the leading "v":
  PB_VERSION=0.00.0 bash /tmp/setup-pocketbase.sh
MSG
  exit 1
fi

# The release assets are named pocketbase_<version>_linux_amd64.zip, so a "v"
# prefix here produces a 404 that looks like a network problem.
if [[ "$PB_VERSION" == v* ]]; then
  echo "ERROR: drop the leading 'v' — use PB_VERSION=${PB_VERSION#v}" >&2
  exit 1
fi

echo "=== PocketBase setup (version $PB_VERSION) ==="

mkdir -p "$BASE/pb_data" "$BASE/pb_migrations"

cat > "$BASE/Dockerfile" <<DOCKERFILE
FROM alpine:3.20
ARG PB_VERSION
RUN apk add --no-cache unzip ca-certificates
ADD https://github.com/pocketbase/pocketbase/releases/download/v\${PB_VERSION}/pocketbase_\${PB_VERSION}_linux_amd64.zip /tmp/pb.zip
RUN unzip /tmp/pb.zip -d /pb/ && rm /tmp/pb.zip
EXPOSE 8090
CMD ["/pb/pocketbase", "serve", "--http=0.0.0.0:8090"]
DOCKERFILE

echo "Wrote $BASE/Dockerfile"

echo "Building image pocketbase-p2b:$PB_VERSION ..."
docker build --build-arg "PB_VERSION=$PB_VERSION" -t "pocketbase-p2b:$PB_VERSION" "$BASE"

cat <<MSG

=== Image built. Two steps left, both by hand. ===

1. Add this service to ~/hosting/docker-compose.yml, at the same indentation as
   the other services (two spaces). YAML is whitespace-sensitive — if the file
   will not parse afterwards, 'docker compose config' says which line.

  pocketbase:
    image: pocketbase-p2b:$PB_VERSION
    container_name: pocketbase
    restart: unless-stopped
    volumes:
      - ./pocketbase/pb_data:/pb/pb_data
      - ./pocketbase/pb_migrations:/pb/pb_migrations

   Deliberately no 'ports:' mapping. Nginx Proxy Manager reaches the container
   over the compose network, and not publishing the port keeps the database off
   the public internet even while UFW is off.

2. Start it:

     docker compose -f ~/hosting/docker-compose.yml up -d pocketbase
     docker compose -f ~/hosting/docker-compose.yml logs --tail 20 pocketbase

Then point DNS and an NPM proxy host at it (forward to host 'pocketbase', port
8090) and open the admin UI to create the first account. The README section
"PocketBase" has the rest.

Do NOT add it to scripts/sites.txt or scripts/backup-databases.sh until it is
actually answering — both would fail on something that does not exist yet.
MSG
