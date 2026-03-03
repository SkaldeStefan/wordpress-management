#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(cd -- "${SCRIPT_DIR}/.." && pwd)}"

if [ ! -f "${PROJECT_DIR}/docker-compose.yml" ]; then
  echo "Fehler: docker-compose.yml nicht gefunden in ${PROJECT_DIR}" >&2
  exit 1
fi

DB_CONTAINER_ID="$(docker compose --project-directory "${PROJECT_DIR}" ps -q db 2>/dev/null || true)"
if [ -z "${DB_CONTAINER_ID}" ]; then
  echo "Fehler: DB-Container ist nicht gestartet." >&2
  exit 1
fi

if [ "$(docker inspect -f '{{.State.Running}}' "${DB_CONTAINER_ID}" 2>/dev/null || echo false)" != "true" ]; then
  echo "Fehler: DB-Container laeuft nicht." >&2
  exit 1
fi

docker compose \
  --project-directory "${PROJECT_DIR}" \
  run --rm --no-deps \
  -e BACKUP_MODE=once \
  backup
