#!/usr/bin/env bash
set -euo pipefail

tools_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
if [ ! -f "$COMPOSE_FILE" ]; then
  echo "Compose file not found: $COMPOSE_FILE" >&2
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

expected="$(printf '%s' "$SSH_HOST_FINGERPRINT" | tr -d '[:space:]')"
scan="$(ssh-keyscan -T 10 "$SERVER_IP")"
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
  echo "Host key does not match SSH_HOST_FINGERPRINT" >&2
  exit 1
fi

ssh_config="$ssh_dir/config"
{
  echo "Host autodeploy-target"
  echo "  HostName ${SERVER_IP}"
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

PYTHONPATH="$tools_dir" python3 -m autodeploy.env_bundle "$bundle/.env.deploy"

remote "mkdir -p \"\$HOME/$APP_NAME/.autodeploy\""
scp -F "$ssh_config" "$COMPOSE_FILE" "autodeploy-target:$APP_NAME/docker-compose.prod.yml"
scp -F "$ssh_config" "$bundle/.env.deploy" "autodeploy-target:$APP_NAME/"
scp -F "$ssh_config" "$tools_dir/remote/deploy.sh" "$tools_dir/remote/verify.sh" \
  "autodeploy-target:$APP_NAME/.autodeploy/"

remote "set -euo pipefail
cd \"\$HOME/$APP_NAME\"
chmod 600 .env.deploy
trap 'rm -f .env.deploy' EXIT
bash .autodeploy/deploy.sh
bash .autodeploy/verify.sh
"

if [ -n "${POST_DEPLOY_SCRIPT:-}" ]; then
  SSH_CONFIG="$ssh_config" SSH_TARGET=autodeploy-target bash "$POST_DEPLOY_SCRIPT" \
    || echo "Post-deploy script failed; the app is already deployed" >&2
fi
