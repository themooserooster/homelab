#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LOCAL_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -f "$LOCAL_DIR/compose.yml" ]; then
  echo "ERROR: Compose file not found at $LOCAL_DIR/compose.yml." >&2
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker CLI is not installed." >&2
  exit 1
fi

cd "$LOCAL_DIR"

echo "Pulling Compose images, including the manual Certbot profile."
COMPOSE_PROFILES=manual docker compose pull

echo "Applying updated images to default-profile services."
COMPOSE_PROFILES= docker compose up -d --pull never
