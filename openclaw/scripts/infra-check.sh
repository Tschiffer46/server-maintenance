#!/usr/bin/env bash
# Infrastructure health check: disk, memory, swap, load, Docker, systemd services.
# State file tracks last status per metric. Alerts only on transitions.
# Intended to run from cron every 15 minutes.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONF_FILE="${INFRA_CONF:-$REPO_DIR/openclaw/config/infra.conf}"
STATE_DIR="${STATE_DIR:-$HOME/.openclaw-monitor/state}"
LOG_FILE="${LOG_FILE:-$HOME/.openclaw-monitor/monitor.log}"
NOTIFY="$SCRIPT_DIR/lib/notify-telegram.sh"
LOG_EVENT="$SCRIPT_DIR/lib/log-event.py"

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE"; }

# defaults (overridden by conf file)
DISK_WARN_PCT=85
DISK_CRIT_PCT=95
MEM_WARN_PCT=90
SWAP_WARN_PCT=50
LOAD_WARN_RATIO=4
EXPECTED_CONTAINERS=""
EXPECTED_SERVICES=""

if [ -r "$CONF_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONF_FILE"
fi

# transition-based alerter: emits notify on prev != now
# args: metric_key now_state message_on_alert
transition() {
  local key="$1" now="$2" msg="$3"
  local state_file="$STATE_DIR/infra-$key.state"
  local prev="ok"
  [ -r "$state_file" ] && prev="$(cat "$state_file")"
  printf '%s' "$now" > "$state_file"
  if [ "$prev" != "$now" ]; then
    log "transition $key $prev -> $now"
    case "$now" in
      ok)
        if [ "$prev" != "ok" ] && [ "$prev" != "unknown" ]; then
          "$NOTIFY" "✅ <b>OK</b>: $msg" || log "notify failed: $key"
          python3 "$LOG_EVENT" infra recovered "$key" "$msg" 2>/dev/null || true
        fi
        ;;
      *)
        "$NOTIFY" "🚨 <b>ALERT</b> ($key): $msg" || log "notify failed: $key"
        python3 "$LOG_EVENT" infra "$now" "$key" "$msg" 2>/dev/null || true
        ;;
    esac
  fi
}

# --- disk -------------------------------------------------------------
disk_pct="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')"
if [ -n "$disk_pct" ]; then
  if   [ "$disk_pct" -ge "$DISK_CRIT_PCT" ]; then
    transition disk-root crit "disk / is ${disk_pct}% full (crit >=${DISK_CRIT_PCT}%)"
  elif [ "$disk_pct" -ge "$DISK_WARN_PCT" ]; then
    transition disk-root warn "disk / is ${disk_pct}% full (warn >=${DISK_WARN_PCT}%)"
  else
    transition disk-root ok "disk / back to ${disk_pct}% used"
  fi
fi

# --- memory -----------------------------------------------------------
# Use "available" (kB) vs total; % used = 100 - 100*avail/total
read -r mem_total mem_avail <<<"$(awk '
  /^MemTotal:/    {tot=$2}
  /^MemAvailable:/{avail=$2}
  END {print tot, avail}
' /proc/meminfo)"
if [ "${mem_total:-0}" -gt 0 ]; then
  mem_used_pct=$(( 100 - (100 * mem_avail / mem_total) ))
  if [ "$mem_used_pct" -ge "$MEM_WARN_PCT" ]; then
    transition memory warn "memory ${mem_used_pct}% used (warn >=${MEM_WARN_PCT}%)"
  else
    transition memory ok "memory back to ${mem_used_pct}% used"
  fi
fi

# --- swap -------------------------------------------------------------
read -r sw_total sw_free <<<"$(awk '
  /^SwapTotal:/{tot=$2}
  /^SwapFree:/ {free=$2}
  END {print tot, free}
' /proc/meminfo)"
if [ "${sw_total:-0}" -gt 0 ] && [ "$SWAP_WARN_PCT" -gt 0 ]; then
  sw_used_pct=$(( 100 - (100 * sw_free / sw_total) ))
  if [ "$sw_used_pct" -ge "$SWAP_WARN_PCT" ]; then
    transition swap warn "swap ${sw_used_pct}% used (warn >=${SWAP_WARN_PCT}%)"
  else
    transition swap ok "swap back to ${sw_used_pct}% used"
  fi
fi

# --- load -------------------------------------------------------------
load1="$(awk '{print $1}' /proc/loadavg)"
cpus="$(nproc 2>/dev/null || echo 1)"
# integer ratio: load*100 / cpus, threshold *100
load_x100="$(awk -v l="$load1" 'BEGIN{printf "%d", l*100}')"
thresh_x100=$(( LOAD_WARN_RATIO * 100 ))
if [ "$load_x100" -ge "$thresh_x100" ]; then
  transition load warn "load $load1 over $cpus CPUs (warn ratio >=${LOAD_WARN_RATIO})"
else
  transition load ok "load $load1 over $cpus CPUs"
fi

# --- docker containers -----------------------------------------------
if command -v docker >/dev/null 2>&1; then
  for c in $EXPECTED_CONTAINERS; do
    state="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
    if [ "$state" = "running" ]; then
      transition "container-$c" ok "container $c is running again"
    else
      transition "container-$c" "bad-$state" "container $c is $state"
    fi
  done
fi

# --- systemd services ------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
  for s in $EXPECTED_SERVICES; do
    if systemctl is-active --quiet "$s"; then
      transition "service-$s" ok "service $s is active again"
    else
      st="$(systemctl is-active "$s" 2>/dev/null || echo unknown)"
      transition "service-$s" "bad-$st" "service $s is $st"
    fi
  done
fi
