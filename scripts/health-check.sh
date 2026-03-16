#!/bin/bash
set -euo pipefail

ERRORS=0

echo "=== Site Health Check: $(date) ==="

# Check all sites externally
SITES=(
  "https://schiffer.agiletransition.se"
  "https://seatower.agiletransition.se"
  "https://hemsidor.agiletransition.se"
  "https://azprofil.agiletransition.se"
  "https://azp2b.agiletransition.se"
  "https://agiletransition.agiletransition.se"
  "https://azstore.agiletransition.se"
  "https://stegvis.agiletransition.se"
  "https://voxtera.agiletransition.se"
  "https://forfor.agiletransition.se"
)

for url in "${SITES[@]}"; do
  STATUS=$(curl -o /dev/null -s -w "%{http_code}" --max-time 15 "$url" || echo "000")
  if [ "$STATUS" -ge 200 ] && [ "$STATUS" -lt 400 ]; then
    echo "OK:   $url ($STATUS)"
  else
    echo "FAIL: $url ($STATUS)"
    ERRORS=$((ERRORS+1))
  fi
done

echo ""
echo "=== Results: $ERRORS failure(s) ==="
exit $ERRORS
