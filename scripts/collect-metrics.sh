#!/bin/bash
# Collects a snapshot of server usage / risks / status and prints it as JSON to stdout.
# Intended to run on the VPS over SSH from a GitHub Actions workflow.
set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required. Install with: sudo apt-get install -y jq" >&2
  exit 2
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HOST=$(hostname)
KERNEL=$(uname -r)
OS_NAME=$(. /etc/os-release && echo "$PRETTY_NAME")
UPTIME_SECONDS=$(awk '{print int($1)}' /proc/uptime)
read -r LOAD1 LOAD5 LOAD15 _ < /proc/loadavg
CPUS=$(nproc)

# Memory in MiB
read -r MEM_TOTAL MEM_USED _ _ _ MEM_AVAIL <<<"$(free -m | awk '/^Mem:/ {print $2,$3,$4,$5,$6,$7}')"
read -r SWAP_TOTAL SWAP_USED <<<"$(free -m | awk '/^Swap:/ {print $2,$3}')"

# Disks (real filesystems only)
DISKS_JSON=$(df -PB1 -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null \
  | awk 'NR>1 && $2>0 {printf "{\"mount\":\"%s\",\"fs\":\"%s\",\"size\":%d,\"used\":%d,\"avail\":%d,\"use_pct\":%d}\n",$6,$1,$2,$3,$4,int(($3/$2)*100)}' \
  | jq -s '.')

# Network counters (skip loopback)
NET_JSON=$(awk 'NR>2 {gsub(":",""); if ($1!="lo") printf "{\"iface\":\"%s\",\"rx_bytes\":%d,\"tx_bytes\":%d}\n",$1,$2,$10}' /proc/net/dev | jq -s '.')

# Pending OS updates
APT_PENDING=0
APT_SECURITY=0
if command -v apt-get >/dev/null 2>&1; then
  PLAN=$(LANG=C apt-get -s upgrade 2>/dev/null || true)
  APT_PENDING=$(printf '%s\n' "$PLAN" | grep -c '^Inst ' || true)
  APT_SECURITY=$(printf '%s\n' "$PLAN" | grep -E '^Inst .*-security' | wc -l | tr -d ' ' || true)
fi

REBOOT_REQUIRED=false
[ -f /var/run/reboot-required ] && REBOOT_REQUIRED=true

# fail2ban
F2B_BANS=0
F2B_TOTAL=0
if command -v fail2ban-client >/dev/null 2>&1; then
  F2B_STATUS=$(fail2ban-client status sshd 2>/dev/null || true)
  F2B_BANS=$(printf '%s\n' "$F2B_STATUS" | awk -F'[\t ]+' '/Currently banned/ {print $NF}' | head -1)
  F2B_TOTAL=$(printf '%s\n' "$F2B_STATUS" | awk -F'[\t ]+' '/Total banned/ {print $NF}' | head -1)
fi
F2B_BANS=${F2B_BANS:-0}
F2B_TOTAL=${F2B_TOTAL:-0}

# UFW
UFW_ENABLED=false
UFW_RULES_COUNT=0
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  UFW_ENABLED=true
  UFW_RULES_COUNT=$(ufw status numbered 2>/dev/null | grep -cE '^\[' || echo 0)
fi

# Docker containers
CONTAINERS_JSON='[]'
IMAGES_JSON='[]'
if command -v docker >/dev/null 2>&1; then
  IDS=$(docker ps -a --format '{{.ID}}')
  if [ -n "$IDS" ]; then
    CONTAINERS_JSON=$(printf '%s\n' "$IDS" | while read -r id; do
      docker inspect "$id" --format \
        '{"id":"{{.Id}}","name":"{{.Name}}","image":"{{.Config.Image}}","state":"{{.State.Status}}","health":"{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}","started":"{{.State.StartedAt}}","restart_count":{{.RestartCount}},"exit_code":{{.State.ExitCode}}}'
    done | jq -s 'map(.name |= ltrimstr("/"))')

    STATS_RAW=$(docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemPerc}}' 2>/dev/null || true)
    STATS_JSON=$(printf '%s\n' "$STATS_RAW" | awk -F'|' 'NF==3 {
      cpu=$2; gsub("%","",cpu); if (cpu=="") cpu=0
      memp=$3; gsub("%","",memp); if (memp=="") memp=0
      printf "{\"name\":\"%s\",\"cpu_pct\":%s,\"mem_pct\":%s}\n",$1,cpu,memp
    }' | jq -s '.')

    CONTAINERS_JSON=$(printf '%s' "$CONTAINERS_JSON" | jq --argjson stats "$STATS_JSON" '
      ($stats | map({(.name): {cpu_pct, mem_pct}}) | add) as $m
      | map(. + ($m[.name] // {cpu_pct:0, mem_pct:0}))')
  fi

  IMAGES_JSON=$(docker image ls --format '{{.Repository}}:{{.Tag}}|{{.CreatedAt}}|{{.Size}}|{{.ID}}' 2>/dev/null \
    | awk -F'|' 'NF==4 {printf "{\"image\":\"%s\",\"created\":\"%s\",\"size\":\"%s\",\"id\":\"%s\"}\n",$1,$2,$3,$4}' \
    | jq -s '.')
fi

# Database sizes
DB_SIZES_JSON='[]'
if command -v docker >/dev/null 2>&1; then
  FORFOR_SIZE=$(docker exec forfor-db psql -U forfor -d forfor -tAc "SELECT pg_database_size('forfor')" 2>/dev/null | tr -d ' ' || echo 0)
  VOXTERA_SIZE=$(docker exec voxtera-db psql -U voxtera -d voxtera -tAc "SELECT pg_database_size('voxtera')" 2>/dev/null | tr -d ' ' || echo 0)
  DB_SIZES_JSON=$(jq -n \
    --argjson f "${FORFOR_SIZE:-0}" \
    --argjson v "${VOXTERA_SIZE:-0}" \
    '[{"name":"forfor","size":$f},{"name":"voxtera","size":$v}]')
fi

# Backups
BACKUP_DIR=/home/deploy/backups
BACKUP_TOTAL_BYTES=0
BACKUP_COUNT=0
LATEST_BACKUP_AGE_HOURS=null
LATEST_BACKUP_NAME=null
LATEST_BACKUP_SIZE=0
if [ -d "$BACKUP_DIR" ]; then
  BACKUP_TOTAL_BYTES=$(du -sb "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
  BACKUP_COUNT=$(find "$BACKUP_DIR" -name '*.sql.gz' 2>/dev/null | wc -l | tr -d ' ')
  LATEST=$(ls -t "$BACKUP_DIR"/*.sql.gz 2>/dev/null | head -1)
  if [ -n "$LATEST" ]; then
    LATEST_BACKUP_AGE_HOURS=$(( ($(date +%s) - $(stat -c%Y "$LATEST")) / 3600 ))
    LATEST_BACKUP_NAME="\"$(basename "$LATEST")\""
    LATEST_BACKUP_SIZE=$(stat -c%s "$LATEST")
  fi
fi

# SSH auth log: failed login attempts in last 24h (if readable)
SSH_FAILED_24H=0
if [ -r /var/log/auth.log ]; then
  SSH_FAILED_24H=$(awk -v cutoff="$(date -d '24 hours ago' +%s)" '
    {
      cmd="date -d \"" $1" "$2" "$3 "\" +%s 2>/dev/null"
      cmd | getline t; close(cmd)
      if (t >= cutoff && /Failed password/) c++
    } END {print c+0}' /var/log/auth.log 2>/dev/null || echo 0)
fi

# Build the snapshot
jq -n \
  --arg now "$NOW" \
  --arg host "$HOST" \
  --arg kernel "$KERNEL" \
  --arg os "$OS_NAME" \
  --argjson uptime "$UPTIME_SECONDS" \
  --argjson cpus "$CPUS" \
  --argjson load1 "$LOAD1" \
  --argjson load5 "$LOAD5" \
  --argjson load15 "$LOAD15" \
  --argjson mem_total "$MEM_TOTAL" \
  --argjson mem_used "$MEM_USED" \
  --argjson mem_avail "$MEM_AVAIL" \
  --argjson swap_total "$SWAP_TOTAL" \
  --argjson swap_used "$SWAP_USED" \
  --argjson disks "$DISKS_JSON" \
  --argjson net "$NET_JSON" \
  --argjson apt_pending "${APT_PENDING:-0}" \
  --argjson apt_security "${APT_SECURITY:-0}" \
  --argjson reboot_required "$REBOOT_REQUIRED" \
  --argjson f2b_bans "${F2B_BANS:-0}" \
  --argjson f2b_total "${F2B_TOTAL:-0}" \
  --argjson ufw_enabled "$UFW_ENABLED" \
  --argjson ufw_rules "${UFW_RULES_COUNT:-0}" \
  --argjson containers "$CONTAINERS_JSON" \
  --argjson images "$IMAGES_JSON" \
  --argjson db_sizes "$DB_SIZES_JSON" \
  --argjson backup_total "${BACKUP_TOTAL_BYTES:-0}" \
  --argjson backup_count "${BACKUP_COUNT:-0}" \
  --argjson backup_age "${LATEST_BACKUP_AGE_HOURS}" \
  --argjson backup_name "${LATEST_BACKUP_NAME}" \
  --argjson backup_size "${LATEST_BACKUP_SIZE:-0}" \
  --argjson ssh_failed_24h "${SSH_FAILED_24H:-0}" \
  '{
    ts: $now,
    host: {name: $host, os: $os, kernel: $kernel, uptime_seconds: $uptime, cpus: $cpus},
    cpu: {load1: $load1, load5: $load5, load15: $load15},
    memory: {total_mib: $mem_total, used_mib: $mem_used, avail_mib: $mem_avail,
             swap_total_mib: $swap_total, swap_used_mib: $swap_used},
    disks: $disks,
    network: $net,
    os_updates: {pending: $apt_pending, security: $apt_security, reboot_required: $reboot_required},
    security: {fail2ban_currently_banned: $f2b_bans, fail2ban_total_bans: $f2b_total,
               ufw_enabled: $ufw_enabled, ufw_rules: $ufw_rules,
               ssh_failed_logins_24h: $ssh_failed_24h},
    containers: $containers,
    images: $images,
    databases: $db_sizes,
    backups: {total_bytes: $backup_total, count: $backup_count,
              latest_age_hours: $backup_age, latest_name: $backup_name, latest_size: $backup_size}
  }'
