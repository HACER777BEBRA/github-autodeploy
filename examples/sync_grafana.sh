#!/usr/bin/env bash
# Пример post_deploy_script: SSH_CONFIG и SSH_TARGET приходят из push_remote.sh.
set -euo pipefail

remote() {
  ssh -F "$SSH_CONFIG" "$SSH_TARGET" "$@"
}

remote "test -d /opt/grafana" || exit 0
before="$(remote "cd /opt/grafana && md5sum dashboards.yml datasource.yml docker-compose.yml")"
(cd grafana && scp -F "$SSH_CONFIG" dashboard.json user_dashboard.json dashboards.yml \
  datasource.yml docker-compose.yml "$SSH_TARGET:/opt/grafana/")
remote "set -euo pipefail
cd /opt/grafana
if [ \"\$(md5sum dashboards.yml datasource.yml docker-compose.yml)\" != \"$before\" ]; then
  docker compose up -d --force-recreate
else
  docker compose up -d
fi
"
