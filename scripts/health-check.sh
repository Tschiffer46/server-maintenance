#!/bin/bash
# Pass/fail health check for every publicly reachable site.
# Exits non-zero on the first problem so the GitHub Actions run turns red and
# GitHub emails the failure. The site list lives in scripts/sites.txt.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITES_FILE="$SCRIPT_DIR/sites.txt"

# euproof.eu is gated by a dev-phase secret-link cookie (non-sensitive dev value).
# Without it the gate answers 401/403; with it the real site answers 200.
EUPROOF_COOKIE="euproof_preview=0432885f1a"

ERRORS=0

echo "=== Site Health Check: $(date) ==="

if [ ! -r "$SITES_FILE" ]; then
  echo "FAIL: cannot read site list at $SITES_FILE"
  exit 1
fi

mapfile -t SITES < <(grep -vE '^\s*(#|$)' "$SITES_FILE")

if [ "${#SITES[@]}" -eq 0 ]; then
  echo "FAIL: site list $SITES_FILE is empty"
  exit 1
fi

# Cloudflare may answer 403 to bot-like requests, which still confirms the site
# is reachable — hence the <500 rule rather than a strict 200.
for url in "${SITES[@]}"; do
  host=${url#https://}
  host=${host%%/*}

  auth_args=()
  if [ "$host" = "euproof.eu" ]; then
    auth_args=(-H "Cookie: $EUPROOF_COOKIE")
  fi

  STATUS=$(curl -o /dev/null -s -w "%{http_code}" --max-time 15 \
    -A "Mozilla/5.0 HealthCheck" "${auth_args[@]}" "$url" || echo "000")

  if [ "$STATUS" -ge 200 ] && [ "$STATUS" -lt 500 ]; then
    echo "OK:   $url ($STATUS)"
  else
    echo "FAIL: $url ($STATUS)"
    ERRORS=$((ERRORS+1))
  fi
done

echo ""
echo "--- euproof.eu dev-phase gate ---"
# The site must stay password-protected while it is a draft. The gate is a
# cookie now, not basic auth: 401/403 without the cookie proves it is enforced,
# a 200 without it means the protection has silently disappeared.
NOAUTH=$(curl -o /dev/null -s -w "%{http_code}" --max-time 15 \
  -A "Mozilla/5.0 HealthCheck" "https://euproof.eu/en/" || echo "000")
case "$NOAUTH" in
  401|403)
    echo "OK:   euproof.eu gate is enforced ($NOAUTH without the preview cookie)" ;;
  200)
    echo "FAIL: euproof.eu is NOT protected (200 without the preview cookie)"
    ERRORS=$((ERRORS+1)) ;;
  *)
    echo "FAIL: euproof.eu gate check inconclusive (no-cookie status $NOAUTH)"
    ERRORS=$((ERRORS+1)) ;;
esac

echo ""
echo "=== Results: $ERRORS failure(s) across ${#SITES[@]} site(s) ==="
exit $ERRORS
