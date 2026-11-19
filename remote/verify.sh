#!/usr/bin/env bash
set -euo pipefail

app="$(basename "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")"

if [ "$(docker inspect -f '{{.State.Running}}' "$app" 2>/dev/null)" = "true" ]; then
  echo "$app is running"
  docker ps --filter "name=^${app}\$" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
else
  echo "$app is not running" >&2
  exit 1
fi
