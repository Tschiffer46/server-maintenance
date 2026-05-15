#!/usr/bin/env bash
# Send a message to Telegram via the OpenClaw bot.
# Reads TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID from ~/.openclaw-monitor/.env

set -u

ENV_FILE="${OPENCLAW_MONITOR_ENV:-$HOME/.openclaw-monitor/.env}"

if [ ! -r "$ENV_FILE" ]; then
  echo "notify-telegram: missing env file: $ENV_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$ENV_FILE"

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN not set in $ENV_FILE}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID not set in $ENV_FILE}"

MSG="${1:-}"
if [ -z "$MSG" ]; then
  echo "usage: notify-telegram.sh <message>" >&2
  exit 1
fi

curl -fsS --max-time 15 \
  -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=${MSG}" \
  --data-urlencode "parse_mode=HTML" \
  --data-urlencode "disable_web_page_preview=true" \
  >/dev/null
