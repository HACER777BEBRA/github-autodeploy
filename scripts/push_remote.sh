#!/usr/bin/env bash
set -euo pipefail

tools_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Пустые все SSH-секреты разом — почти всегда значит, что секреты вообще
# не дошли до reusable workflow: `secrets: inherit` не работает между
# разными владельцами репозиториев.
if [ -z "${SERVER_IP:-}${SERVER_USER:-}${SSH_PRIVATE_KEY:-}${SSH_HOST_FINGERPRINT:-}" ]; then
  caller_owner="${CALLER_REPOSITORY%%/*}"
  workflow_owner="${AUTODEPLOY_REPOSITORY%%/*}"
  {
    echo "::error title=Secrets were not passed::SERVER_IP, SERVER_USER, SSH_PRIVATE_KEY and SSH_HOST_FINGERPRINT are all empty."
    if [ -n "$caller_owner" ] && [ "${caller_owner,,}" != "${workflow_owner,,}" ]; then
      echo "The app repository (${CALLER_REPOSITORY}) and autodeploy (${AUTODEPLOY_REPOSITORY}) have different owners."
    fi
    echo "GitHub passes 'secrets: inherit' only to a reusable workflow of the same owner (organization or enterprise)."
    echo "If the workflow is called across owners, vendor it into the app repository and call it as"
    echo "'uses: ./.github/workflows/autodeploy.yml' with 'autodeploy_ref' pinned to the same SHA."
    echo "See https://github.com/${AUTODEPLOY_REPOSITORY:-HACER777BEBRA/github-autodeploy}#репозиторий-приложения-у-другого-владельца"
    echo "Otherwise check that the secrets exist in the app repository (or its environment/organization)."
  } >&2
  exit 1
fi

for name in APP_NAME NEW_IMAGE GHCR_TOKEN GHCR_USERNAME COMPOSE_FILE \
  SERVER_IP SERVER_USER SSH_PRIVATE_KEY SSH_HOST_FINGERPRINT; do
  if [ -z "${!name:-}" ]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
done

case "$APP_NAME" in
  *[!A-Za-z0-9._-]*|.*)
    echo "APP_NAME must match [A-Za-z0-9._-] and not start with a dot" >&2
    exit 1
    ;;
esac
case "$NEW_IMAGE" in
  *@sha256:*) ;;
  *)
    echo "NEW_IMAGE must be an image digest, not a tag" >&2
    exit 1
    ;;
esac
server_port="${SERVER_PORT:-22}"
case "$server_port" in
  ''|*[!0-9]*)
    echo "SERVER_PORT must be a number" >&2
    exit 1
    ;;
esac
if [ ! -f "$COMPOSE_FILE" ]; then
  echo "Compose file not found: $COMPOSE_FILE" >&2
  exit 1
fi
if [ -n "${POST_DEPLOY_SCRIPT:-}" ] && [ ! -f "$POST_DEPLOY_SCRIPT" ]; then
  echo "Post-deploy script not found: $POST_DEPLOY_SCRIPT" >&2
  exit 1
fi

ssh_dir="$(mktemp -d)"
bundle="$(mktemp -d)"
trap 'rm -rf "$ssh_dir" "$bundle"' EXIT
umask 077

key_file="$ssh_dir/key"
known_hosts="$ssh_dir/known_hosts"
printf '%s\n' "$SSH_PRIVATE_KEY" > "$key_file"
: > "$known_hosts"

PYTHONPATH="$tools_dir" python3 -m autodeploy.env_bundle "$bundle"
cp "$COMPOSE_FILE" "$bundle/docker-compose.prod.yml"
# Дальше секреты нужны только в файлах; дочерним процессам они не достаются.
unset SECRETS_JSON SSH_PRIVATE_KEY GHCR_TOKEN

expected="$(printf '%s' "$SSH_HOST_FINGERPRINT" | tr -d '[:space:]')"
scan="$(ssh-keyscan -T 10 -p "$server_port" "$SERVER_IP" 2>/dev/null || true)"
found=0
while IFS= read -r line; do
  case "$line" in
    ""|\#*) continue ;;
  esac
  fingerprint="$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')" || continue
  if [ "$fingerprint" = "$expected" ]; then
    printf '%s\n' "$line" >> "$known_hosts"
    found=1
  fi
done <<< "$scan"
if [ "$found" -ne 1 ]; then
  echo "Host key of ${SERVER_IP}:${server_port} does not match SSH_HOST_FINGERPRINT" >&2
  exit 1
fi

ssh_config="$ssh_dir/config"
{
  echo "Host autodeploy-target"
  echo "  HostName ${SERVER_IP}"
  echo "  Port ${server_port}"
  echo "  User ${SERVER_USER}"
  echo "  IdentityFile ${key_file}"
  echo "  IdentitiesOnly yes"
  echo "  BatchMode yes"
  echo "  StrictHostKeyChecking yes"
  echo "  UserKnownHostsFile ${known_hosts}"
  echo "  ServerAliveInterval 30"
  echo "  ServerAliveCountMax 40"
} > "$ssh_config"

remote() {
  ssh -F "$ssh_config" autodeploy-target "$@"
}

incoming="$APP_NAME/.autodeploy/incoming"
remote "set -e; rm -rf \"\$HOME/$incoming\"; mkdir -p \"\$HOME/$incoming\"; chmod 700 \"\$HOME/$incoming\""
scp -q -F "$ssh_config" "$bundle/.env" "$bundle/.env.deploy" "$bundle/docker-compose.prod.yml" \
  "autodeploy-target:$incoming/"
scp -q -F "$ssh_config" "$tools_dir/remote/deploy.sh" "autodeploy-target:$APP_NAME/.autodeploy/"

remote "bash \"\$HOME/$APP_NAME/.autodeploy/deploy.sh\""

if [ -n "${POST_DEPLOY_SCRIPT:-}" ]; then
  # Скрипту приложения — только то, что нужно для SSH, без секретов.
  env -i PATH="$PATH" HOME="$HOME" APP_NAME="$APP_NAME" \
    SSH_CONFIG="$ssh_config" SSH_TARGET=autodeploy-target \
    bash "$POST_DEPLOY_SCRIPT" \
    || echo "Post-deploy script failed; the app is already deployed" >&2
fi
