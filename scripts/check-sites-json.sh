#!/bin/bash
# Probes each public site for HTTP status, response time, and TLS certificate expiry.
# Emits a single JSON object to stdout. Runs from the GitHub Actions runner (no SSH needed).
set -uo pipefail

SITES=(
  "https://schiffer.agiletransition.se"
  "https://seatower.agiletransition.se"
  "https://hemsidor.agiletransition.se"
  "https://azprofil.agiletransition.se"
  "https://azp2b.agiletransition.se"
  "https://agiletransition.se"
  "https://azstore.agiletransition.se"
  "https://stegvis.agiletransition.se"
  "https://voxtera.agiletransition.se"
  "https://forfor.agiletransition.se"
  "https://euproof.eu/en/"
)

# euproof.eu is behind dev-phase basic auth (non-sensitive dev credentials).
# We probe it with credentials so status reflects the actual site, and record
# whether the protection is enforced (no-auth request must get 401).
EUPROOF_CREDS="euproof:EUDigSov2026"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cert_days_left() {
  local host="$1"
  local end_date
  end_date=$(echo | openssl s_client -servername "$host" -connect "$host:443" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')
  if [ -z "$end_date" ]; then
    echo "null"
    return
  fi
  local end_ts now_ts
  end_ts=$(date -d "$end_date" +%s 2>/dev/null || echo 0)
  now_ts=$(date +%s)
  if [ "$end_ts" -gt 0 ]; then
    echo $(( (end_ts - now_ts) / 86400 ))
  else
    echo "null"
  fi
}

results=()
for url in "${SITES[@]}"; do
  host=${url#https://}
  host=${host%%/*}

  auth_args=()
  auth_enforced="null"
  if [ "$host" = "euproof.eu" ]; then
    auth_args=(-u "$EUPROOF_CREDS")
    noauth_status=$(curl -o /dev/null -s -w "%{http_code}" --max-time 15 \
      -A "Mozilla/5.0 HealthCheck" "$url" 2>/dev/null || echo "000")
    if [ "$noauth_status" = "401" ]; then auth_enforced="true"; else auth_enforced="false"; fi
  fi

  read -r status time_total < <(
    curl -o /dev/null -s -w "%{http_code} %{time_total}\n" --max-time 15 \
      -A "Mozilla/5.0 HealthCheck" "${auth_args[@]}" "$url" 2>/dev/null || echo "000 0"
  )
  ok="false"
  if [ "$status" -ge 200 ] && [ "$status" -lt 500 ]; then ok="true"; fi
  # The dev-phase password protection counts as part of site health.
  if [ "$auth_enforced" = "false" ]; then ok="false"; fi
  cert_days=$(cert_days_left "$host")

  entry=$(jq -n \
    --arg url "$url" \
    --arg host "$host" \
    --argjson status "${status:-0}" \
    --argjson rt "${time_total:-0}" \
    --argjson ok "$ok" \
    --argjson cert "${cert_days:-null}" \
    --argjson auth "$auth_enforced" \
    '{url:$url, host:$host, status:$status, response_time_s:$rt, ok:$ok, cert_days_left:$cert, auth_enforced:$auth}')
  results+=("$entry")
done

printf '%s\n' "${results[@]}" | jq -s --arg ts "$NOW" '{ts: $ts, sites: .}'
