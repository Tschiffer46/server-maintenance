#!/bin/bash
set -euo pipefail

ERRORS=0

echo "=== Site Health Check: $(date) ==="

# Check all sites externally
# Note: Cloudflare may return 403 for bot-like requests, which still confirms the site is reachable
SITES=(
  "https://schiffer.agiletransition.se"
  "https://seatower.agiletransition.se"
  "https://hemsidor.agiletransition.se"
  "https://azprofil.agiletransition.se"
  "https://padeltobusiness.se"
  "https://agiletransition.se"
  "https://azstore.agiletransition.se"
  "https://stegvis.agiletransition.se"
  "https://voxtera.agiletransition.se"
  "https://forfor.agiletransition.se"
  # energi is behind an NPM access list: 401 without credentials still
  # confirms the proxy + container are up (counted OK by the <500 rule)
  "https://energi.agiletransition.se"
)

for url in "${SITES[@]}"; do
  STATUS=$(curl -o /dev/null -s -w "%{http_code}" --max-time 15 \
    -A "Mozilla/5.0 HealthCheck" "$url" || echo "000")
  if [ "$STATUS" -ge 200 ] && [ "$STATUS" -lt 500 ]; then
    echo "OK:   $url ($STATUS)"
  else
    echo "FAIL: $url ($STATUS)"
    ERRORS=$((ERRORS+1))
  fi
done

echo ""
echo "--- euproof.eu dev-phase basic auth ---"
# The site must be password-protected during development: 401 without credentials,
# 200 with the dev credentials (user euproof, non-sensitive password). Anything else
# means the protection is missing or rejecting valid logins.
NOAUTH=$(curl -o /dev/null -s -w "%{http_code}" --max-time 15 \
  -A "Mozilla/5.0 HealthCheck" "https://euproof.eu/en/" || echo "000")
WITHAUTH=$(curl -o /dev/null -s -w "%{http_code}" --max-time 15 \
  -A "Mozilla/5.0 HealthCheck" -u 'euproof:EUDigSov2026' "https://euproof.eu/en/" || echo "000")
if [ "$NOAUTH" = "401" ] && [ "$WITHAUTH" = "200" ]; then
  echo "OK:   https://euproof.eu/en/ (401 without auth, 200 with auth)"
elif [ "$NOAUTH" = "200" ]; then
  echo "FAIL: https://euproof.eu/en/ is NOT password-protected (200 without auth)"
  ERRORS=$((ERRORS+1))
else
  echo "FAIL: https://euproof.eu/en/ auth broken (no-auth=$NOAUTH with-auth=$WITHAUTH)"
  ERRORS=$((ERRORS+1))
fi

echo ""
echo "=== Results: $ERRORS failure(s) ==="
exit $ERRORS
