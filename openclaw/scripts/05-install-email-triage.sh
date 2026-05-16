#!/usr/bin/env bash
# Install the IMAP email triage cron job.
#
# Prompts (silently) for the three IMAP app-passwords and your Anthropic API
# key, appends them to ~/.openclaw-monitor/.env (mode 600), runs a connection
# test on each inbox, then adds a cron line. First cron run is a no-op for
# notifications: it records the current top UID so we don't blast a backlog.

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as the deploy user (no sudo)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$HOME/.openclaw-monitor/.env"
CONF_FILE="$REPO_DIR/openclaw/config/email.conf"

if [ ! -r "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE. Run 03-install-monitoring.sh first." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found — install with: sudo apt install -y python3" >&2
  exit 1
fi

mkdir -p "$HOME/.openclaw-monitor/state"
chmod 600 "$ENV_FILE"

prompt_secret() {
  # $1 = var name, $2 = human label
  local var="$1" label="$2" cur="" entered=""
  cur="$(grep -E "^${var}=" "$ENV_FILE" | tail -n1 | cut -d= -f2- || true)"
  if [ -n "$cur" ]; then
    echo "  ${var} already set (leave blank to keep)."
  fi
  # Read from /dev/tty so this works inside a while-loop that's piped from
  # a process substitution (otherwise read steals from the loop's stdin).
  read -r -s -p "  ${label}: " entered </dev/tty
  echo
  if [ -z "$entered" ]; then
    if [ -n "$cur" ]; then return 0; fi
    echo "  (empty — skipping ${var})"
    return 1
  fi
  # remove any existing line, then append new
  if grep -qE "^${var}=" "$ENV_FILE"; then
    sed -i.bak "/^${var}=/d" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
  fi
  printf '%s=%s\n' "$var" "$entered" >> "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

echo
echo "▶ Anthropic API key (used to classify mail)"
echo "  We'll re-use the same key OpenClaw already uses."
# Try to pull from OpenClaw config first
OC_CONFIG="$HOME/.openclaw/openclaw.json"
EXISTING_KEY=""
if [ -r "$OC_CONFIG" ]; then
  EXISTING_KEY="$(grep -oE 'sk-ant-[A-Za-z0-9_-]{20,}' "$OC_CONFIG" | head -n1 || true)"
fi
if [ -n "$EXISTING_KEY" ] && ! grep -qE '^ANTHROPIC_API_KEY=' "$ENV_FILE"; then
  printf 'ANTHROPIC_API_KEY=%s\n' "$EXISTING_KEY" >> "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "  ✓ copied existing key from OpenClaw config"
else
  prompt_secret ANTHROPIC_API_KEY "Anthropic API key (sk-ant-...)"
fi

echo
echo "▶ IMAP app-passwords for Mailcow"
echo "  Generate one per inbox in Mailcow → Applikationslösenord (IMAP-only)."
echo "  We'll prompt only for inboxes whose password isn't already in .env."
echo "  Press Enter to keep an existing value."
echo

# Parse INBOXES from the conf file: slug | user | env_var
# (Tolerant of extra whitespace around |.)
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -z "$line" ] && continue
  case "$line" in \#*) continue;; esac
  slug="$(printf '%s' "$line" | awk -F'|' '{gsub(/^ +| +$/,"",$1); print $1}')"
  user="$(printf '%s' "$line" | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}')"
  var="$(printf '%s'  "$line" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')"
  [ -z "$slug" ] && continue
  echo "  $user  [$slug]"
  prompt_secret "$var" "  app-password"
done < <(awk '
  /INBOXES[[:space:]]*=[[:space:]]*"/ {inside=1; sub(/^[^"]*"/, ""); }
  inside { if (match($0,/"/)) {print substr($0,1,RSTART-1); exit} else print }
' "$CONF_FILE")

# Test connections (read-only) without classifying anything.
echo
echo "▶ Testing IMAP connections (READ-ONLY, no messages modified)"
REPO_DIR="$REPO_DIR" python3 - <<'PY'
import imaplib, os, ssl, sys, re
from pathlib import Path

env_file = Path.home() / ".openclaw-monitor" / ".env"
env = {}
for line in env_file.read_text().splitlines():
    line = line.strip()
    if "=" in line and not line.startswith("#"):
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip()

conf = (Path(os.environ["REPO_DIR"]) / "openclaw" / "config" / "email.conf").read_text()
host = re.search(r"^IMAP_HOST=(\S+)", conf, re.M).group(1)
port = int(re.search(r"^IMAP_PORT=(\d+)", conf, re.M).group(1))
inbox_block = re.search(r'INBOXES\s*=\s*"([^"]*)"', conf, re.S).group(1)

failed = 0
for line in inbox_block.splitlines():
    line = line.strip()
    if not line or line.startswith("#"): continue
    slug, user, var = [p.strip() for p in line.split("|")]
    pw = env.get(var, "")
    if not pw:
        print(f"  · {slug:25s} no password — SKIPPED")
        continue
    try:
        imap = imaplib.IMAP4_SSL(host, port, ssl_context=ssl.create_default_context())
        imap.login(user, pw)
        imap.examine("INBOX")
        imap.logout()
        print(f"  ✓ {slug:25s} OK")
    except Exception as e:
        failed += 1
        print(f"  ✗ {slug:25s} FAILED: {e}")
sys.exit(1 if failed else 0)
PY

# Install cron line (preserves prior block contents)
BEGIN_MARK="# >>> openclaw-monitor >>>"
END_MARK="# <<< openclaw-monitor <<<"
EXISTING="$(crontab -l 2>/dev/null || true)"
INSIDE="$(printf '%s\n' "$EXISTING" | awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  $0==b {inside=1; next} $0==e {inside=0; next} inside')"
OUTSIDE="$(printf '%s\n' "$EXISTING" | awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  $0==b {skip=1; next} $0==e {skip=0; next} !skip')"

# Drop any prior email-triage line, keep the rest
KEPT="$(printf '%s\n' "$INSIDE" | grep -v 'email-triage.py' || true)"
[ -z "$KEPT" ] && KEPT="# Managed by openclaw/scripts/*-install-*.sh — do not edit by hand."

NEW_BLOCK="$BEGIN_MARK
$KEPT
*/5 * * * * /usr/bin/python3 $SCRIPT_DIR/email-triage.py >/dev/null 2>&1
$END_MARK"

{
  printf '%s\n' "$OUTSIDE"
  printf '%s\n' "$NEW_BLOCK"
} | sed '/^$/N;/^\n$/D' | crontab -

chmod +x "$SCRIPT_DIR/email-triage.py"

# First run: silently records current UIDs (no spam).
echo
echo "▶ Running email-triage once to record current UID per inbox (no alerts on first run)"
REPO_DIR="$REPO_DIR" python3 "$SCRIPT_DIR/email-triage.py" || true
echo "✓ initial run complete"

echo
echo "✓ crontab now contains:"
crontab -l | sed -n "/$BEGIN_MARK/,/$END_MARK/p"
echo
echo "Logs:   tail -f ~/.openclaw-monitor/monitor.log"
echo "State:  ls ~/.openclaw-monitor/state/email-*.uid"
