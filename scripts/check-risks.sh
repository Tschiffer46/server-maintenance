#!/bin/bash
# Reads a metrics snapshot (docs/data/latest.json) and fails when something is
# operationally broken, so the scheduled workflow turns red and GitHub emails.
#
# Why this exists: collecting metrics never failed the run, so the dashboard
# could show a site returning 502 and a month of empty backups while every
# workflow stayed green. Nothing told anyone. This is the alert.
#
# The split matters:
#   CRITICAL -> exit non-zero. Something that was working has broken and is
#               expected to be fixed (site down, backups missing/stale/stub,
#               container down or unhealthy, disk nearly full, cert expiring).
#   WARNING  -> reported, never fails. Standing posture that needs a
#               maintenance decision rather than an incident response (UFW off,
#               pending updates, reboot required). Failing on these would keep
#               the run permanently red, which is how a real alert gets ignored.
set -uo pipefail

SNAPSHOT="${1:-docs/data/latest.json}"
BACKUP_MAX_AGE_HOURS=${BACKUP_MAX_AGE_HOURS:-48}
CERT_MIN_DAYS=${CERT_MIN_DAYS:-14}
DISK_MAX_PCT=${DISK_MAX_PCT:-90}
MEM_MIN_MIB=${MEM_MIN_MIB:-200}

if [ ! -r "$SNAPSHOT" ]; then
  echo "CRITICAL: cannot read snapshot $SNAPSHOT"
  exit 1
fi

CRITICAL=$(jq -r --argjson maxage "$BACKUP_MAX_AGE_HOURS" \
                 --argjson mincert "$CERT_MIN_DAYS" \
                 --argjson maxdisk "$DISK_MAX_PCT" \
                 --argjson minmem "$MEM_MIN_MIB" '
  [
    (.sites[]? | select(.ok | not)
      | "Site \(.host) returned \(.status)"),
    (.sites[]? | select(.auth_enforced == false)
      | "Site \(.host) is no longer behind its dev-phase gate"),
    (.sites[]? | select(.cert_days_left != null and .cert_days_left < $mincert)
      | "TLS certificate for \(.host) expires in \(.cert_days_left) d"),
    (.server.backups | select(.latest_age_hours == null)
      | "No valid database backup found"),
    (.server.backups | select(.latest_age_hours != null and .latest_age_hours > $maxage)
      | "Newest valid backup is \(.latest_age_hours) h old"),
    (.server.backups | select((.stub_count // 0) > 0)
      | "\(.stub_count) empty backup stub(s) on disk — a pg_dump is failing"),
    (.server.containers[]? | select(.state != "running")
      | "Container \(.name) is \(.state)"),
    (.server.containers[]? | select(.health == "unhealthy")
      | "Container \(.name) is unhealthy"),
    (.server.disks[]? | select(.use_pct >= $maxdisk)
      | "Disk \(.mount) is \(.use_pct)% full"),
    (.server.memory | select(.avail_mib < $minmem)
      | "Only \(.avail_mib) MiB memory available")
  ] | .[]' "$SNAPSHOT")

WARNINGS=$(jq -r '
  [
    (select(.server.security.ufw_enabled == false)
      | "UFW firewall is disabled — re-run scripts/harden-server.sh"),
    (select(.server.os_updates.reboot_required)
      | "Server reboot required"),
    (select(.server.os_updates.security > 0)
      | "\(.server.os_updates.security) pending security update(s)"),
    (select(.server.os_updates.pending > 0)
      | "\(.server.os_updates.pending) pending OS update(s)")
  ] | .[]' "$SNAPSHOT")

report() {
  echo "$1"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$1" >> "$GITHUB_STEP_SUMMARY"
  return 0
}

report "## Snapshot $(jq -r '.ts' "$SNAPSHOT")"
report ""

if [ -n "$WARNINGS" ]; then
  report "### Warnings (not failing the run)"
  while IFS= read -r line; do report "- $line"; done <<<"$WARNINGS"
  report ""
fi

if [ -n "$CRITICAL" ]; then
  report "### Critical"
  while IFS= read -r line; do report "- $line"; done <<<"$CRITICAL"
  report ""
  report "$(printf '%s\n' "$CRITICAL" | wc -l) critical issue(s) — failing the run."
  exit 1
fi

report "No critical issues."
exit 0
