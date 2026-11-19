#!/usr/bin/env bash
# Выкладка на сервере. Запускается push_remote.sh из $HOME/<app_name>.
# Новые файлы лежат в .autodeploy/incoming: .env, .env.deploy, docker-compose.prod.yml.
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DEPLOY_DIR"

INCOMING=.autodeploy/incoming
PREVIOUS=.autodeploy/previous
COMPOSE=docker-compose.prod.yml
HELPER_IMAGE="busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec"

# Отдельный конфиг docker на каждую выкладку: logout одной выкладки
# не ломает логин параллельной, и токен не остаётся в ~/.docker.
DOCKER_CONFIG="$(mktemp -d)"
export DOCKER_CONFIG
trap 'rm -rf "$DOCKER_CONFIG" "$INCOMING"' EXIT

if [ ! -f "$INCOMING/.env.deploy" ]; then
  echo "Deploy bundle not found in $INCOMING" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
. "$INCOMING/.env.deploy"
set +a
rm -f "$INCOMING/.env.deploy"

for name in APP_NAME NEW_IMAGE GHCR_TOKEN GHCR_USERNAME; do
  if [ -z "${!name:-}" ]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
done

printf '%s' "$GHCR_TOKEN" | docker login --username "$GHCR_USERNAME" --password-stdin ghcr.io
unset GHCR_TOKEN GHCR_USERNAME
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

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
export HOST_UID HOST_GID

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
  # Файлы могли быть созданы контейнером от root; chown делает
  # отдельный маленький образ, в образе приложения chown может не быть.
  docker run --rm --user 0 --network none -v "$DEPLOY_DIR:/w" \
    "$HELPER_IMAGE" chown -R "${HOST_UID}:${HOST_GID}" "${dirs[@]}"
  for dir in "${dirs[@]}"; do
    chmod 700 "${dir#/w/}"
  done
fi

print_logs() {
  if [ -n "${LOG_MASK_REGEX:-}" ]; then
    docker logs "$APP_NAME" --tail="$1" 2>&1 | python3 -c '
import os, re, sys
pattern = re.compile(os.environ["LOG_MASK_REGEX"])
for line in sys.stdin:
    sys.stdout.write(pattern.sub("***", line))
' || true
  else
    docker logs "$APP_NAME" --tail="$1" 2>&1 || true
  fi
}

container_state() {
  docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$APP_NAME" 2>/dev/null || echo "missing 0"
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

# 0 — приложение готово, 1 — нет.
wait_ready() {
  local timeout="${READY_TIMEOUT:-90}" state status restarts
  local deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    state="$(container_state)"
    status="${state% *}"
    restarts="${state#* }"
    if [ "$status" != "running" ] || [ "$restarts" != "0" ]; then
      echo "Container is ${status} (restarts: ${restarts}) during startup" >&2
      print_logs 50
      return 1
    fi
    if is_ready; then
      print_logs 20
      return 0
    fi
    sleep 3
  done
  echo "App did not report startup in ${timeout}s" >&2
  print_logs 50
  return 1
}

# Запоминаем то, что работает сейчас, чтобы откатиться при неудаче.
previous_image=""
if [ -f "$COMPOSE" ] && [ -f .env ]; then
  previous_image="$(docker inspect -f '{{.Config.Image}}' "$APP_NAME" 2>/dev/null || true)"
fi
if [ -n "$previous_image" ]; then
  mkdir -p "$PREVIOUS"
  cp -p "$COMPOSE" .env "$PREVIOUS/"
fi

rollback() {
  if [ -z "$previous_image" ]; then
    echo "No previous version to roll back to" >&2
    return
  fi
  echo "Rolling back to ${previous_image}" >&2
  cp -p "$PREVIOUS/$COMPOSE" "$PREVIOUS/.env" .
  if NEW_IMAGE="$previous_image" docker compose -f "$COMPOSE" up -d --force-recreate --pull never \
    && wait_ready; then
    echo "Rollback finished: previous version is running" >&2
  else
    echo "Rollback failed" >&2
  fi
}

install -m 600 "$INCOMING/.env" .env
install -m 644 "$INCOMING/$COMPOSE" "$COMPOSE"

export NEW_IMAGE
if docker compose -f "$COMPOSE" up -d --force-recreate --pull never && wait_ready; then
  # Удаляем неиспользуемые образы только этого приложения.
  docker image prune -af --filter "label=autodeploy.app=${APP_NAME}" >/dev/null || true
  docker ps --filter "name=^${APP_NAME}\$" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
  exit 0
fi

rollback
exit 1
