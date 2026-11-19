#!/usr/bin/env bash
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DEPLOY_DIR"
trap 'docker logout ghcr.io >/dev/null 2>&1 || true' EXIT

if [ -f .env.deploy ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env.deploy
  set +a
  rm -f .env.deploy
fi

for name in APP_NAME NEW_IMAGE GHCR_TOKEN GHCR_USERNAME; do
  if [ -z "${!name:-}" ]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
done

printf '%s' "$GHCR_TOKEN" | docker login --username "$GHCR_USERNAME" --password-stdin ghcr.io
pull_attempts=5
for attempt in $(seq 1 "$pull_attempts"); do
  if docker pull "$NEW_IMAGE"; then
    break
  fi
  if [ "$attempt" = "$pull_attempts" ]; then
    echo "Failed to pull image after ${pull_attempts} attempts" >&2
    exit 1
  fi
  sleep $((attempt * 5))
done
docker logout ghcr.io >/dev/null 2>&1 || true

umask 077
python3 -c '
import os, re
from pathlib import Path

def quote(value):
    escaped = value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n")
    return "\"" + escaped + "\""

keys = [k for k in re.split(r"[\s,]+", os.environ.get("ENV_KEYS", "")) if k]
path = Path(".env")
path.write_text("".join(f"{k}={quote(os.environ.get(k, str()))}\n" for k in keys), encoding="utf-8")
path.chmod(0o600)
'
for key in $(printf '%s' "${ENV_KEYS:-}" | tr ',' ' '); do
  unset "$key"
done
unset GHCR_TOKEN GHCR_USERNAME

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
export HOST_UID HOST_GID NEW_IMAGE

dirs=()
for dir in $(printf '%s' "${WRITABLE_DIRS:-}" | tr ',' ' '); do
  case "/$dir/" in
    //*|*/../*|*/./*)
      echo "WRITABLE_DIRS entry must be a plain relative path: $dir" >&2
      exit 1
      ;;
  esac
  mkdir -p "$dir"
  dirs+=("/w/$dir")
done
if [ "${#dirs[@]}" -gt 0 ]; then
  docker run --rm --user 0 --entrypoint chown -v "$DEPLOY_DIR:/w" \
    "$NEW_IMAGE" -R "${HOST_UID}:${HOST_GID}" "${dirs[@]}"
  for dir in "${dirs[@]}"; do
    chmod 700 "${dir#/w/}"
  done
fi

docker compose -f docker-compose.prod.yml up -d --force-recreate --pull never

print_logs() {
  if [ -n "${LOG_MASK_REGEX:-}" ]; then
    docker logs "$APP_NAME" --tail="$1" 2>&1 | sed -E "s/${LOG_MASK_REGEX}/***/g" || true
  else
    docker logs "$APP_NAME" --tail="$1" 2>&1 || true
  fi
}

is_ready() {
  local logs marker health
  if [ -n "${READY_MARKERS:-}" ]; then
    logs="$(docker logs "$APP_NAME" 2>&1)"
    while IFS= read -r marker; do
      [ -z "$marker" ] && continue
      grep -qF -- "$marker" <<< "$logs" || return 1
    done <<< "$READY_MARKERS"
    return 0
  fi
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$APP_NAME")"
  [ "$health" = "healthy" ] || [ "$health" = "none" ]
}

timeout="${READY_TIMEOUT:-90}"
elapsed=0
while [ "$elapsed" -lt "$timeout" ]; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$APP_NAME" 2>/dev/null)" != "true" ]; then
    echo "Container stopped during startup" >&2
    print_logs 50
    exit 1
  fi
  if is_ready; then
    print_logs 20
    exit 0
  fi
  sleep 3
  elapsed=$((elapsed + 3))
done

echo "App did not report startup in ${timeout}s" >&2
print_logs 50
exit 1
