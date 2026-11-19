#!/usr/bin/env bash
set -euo pipefail

tools_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -z "${NOTIFY_TOKEN:-}" ] || [ -z "${NOTIFY_CHAT_ID:-}" ]; then
  echo "Telegram notification skipped: token or chat id is not set"
  exit 0
fi
: "${COMMIT_SHA:?COMMIT_SHA is required}"

export PYTHONPATH="$tools_dir"
COMMIT_MESSAGE="$(git log -1 --format=%B "$COMMIT_SHA")"
LOC_LINE="$(python3 -m autodeploy.count_loc "$COMMIT_SHA" "${BEFORE_SHA:-}" || true)"
export COMMIT_MESSAGE LOC_LINE

umask 077
notice_file="$(mktemp)"
curl_config="$(mktemp)"
trap 'rm -f "$notice_file" "$curl_config"' EXIT

python3 -m autodeploy.notice "$notice_file"

{
  echo "silent"
  echo "show-error"
  echo "fail"
  echo 'request = "POST"'
  echo "url = \"https://api.telegram.org/bot${NOTIFY_TOKEN}/sendMessage\""
  echo "data-urlencode = \"chat_id=${NOTIFY_CHAT_ID}\""
  echo 'data-urlencode = "parse_mode=HTML"'
  echo "data-urlencode = \"text@${notice_file}\""
} > "$curl_config"
curl --config "$curl_config" > /dev/null
