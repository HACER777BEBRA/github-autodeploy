#!/usr/bin/env bash
# Уведомление в Telegram — необязательное: без токена или чата шаг
# пропускается, а ошибка отправки не валит workflow.
set -euo pipefail

tools_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -z "${NOTIFY_TOKEN:-}" ] || [ -z "${NOTIFY_CHAT_ID:-}" ]; then
  echo "Telegram notification skipped: token or chat id is not set"
  exit 0
fi
: "${COMMIT_SHA:?COMMIT_SHA is required}"

export PYTHONPATH="$tools_dir"
COMMIT_MESSAGE="$(git log -1 --format=%B "$COMMIT_SHA")"

# Для дельты строк нужен только предыдущий коммит, а не вся история.
previous="${BEFORE_SHA:-}"
if [ -n "$previous" ] && ! git cat-file -e "${previous}^{commit}" 2>/dev/null; then
  git fetch --quiet --no-tags --depth=1 origin "$previous" 2>/dev/null || previous=""
fi
LOC_LINE="$(python3 -m autodeploy.count_loc "$COMMIT_SHA" "$previous" || true)"
export COMMIT_MESSAGE LOC_LINE

umask 077
notice_file="$(mktemp)"
curl_config="$(mktemp)"
trap 'rm -f "$notice_file" "$curl_config"' EXIT

python3 -m autodeploy.notice "$notice_file"

{
  echo "silent"
  echo "show-error"
  echo "fail-with-body"
  echo "retry = 3"
  echo 'request = "POST"'
  echo "url = \"https://api.telegram.org/bot${NOTIFY_TOKEN}/sendMessage\""
  echo "data-urlencode = \"chat_id=${NOTIFY_CHAT_ID}\""
  echo 'data-urlencode = "parse_mode=HTML"'
  echo 'data-urlencode = "disable_web_page_preview=true"'
  echo "data-urlencode = \"text@${notice_file}\""
} > "$curl_config"
if ! response="$(curl --config "$curl_config")"; then
  echo "::warning::Telegram notification was not sent"
  printf '%s\n' "$response" >&2
fi
