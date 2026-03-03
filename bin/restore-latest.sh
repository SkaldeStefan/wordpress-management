#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(cd -- "${SCRIPT_DIR}/.." && pwd)}"
ENV_FILE="${PROJECT_DIR}/.env"
RESTORE_SCRIPT="${SCRIPT_DIR}/restore-from-file.sh"

if [ ! -x "$RESTORE_SCRIPT" ]; then
  echo "Fehler: restore-from-file.sh nicht gefunden oder nicht ausfuehrbar: $RESTORE_SCRIPT" >&2
  exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
  echo "Fehler: .env nicht gefunden in ${PROJECT_DIR}" >&2
  exit 1
fi

get_env_value() {
  local key="$1"
  local value
  value="$(grep -E "^${key}=" "$ENV_FILE" | head -n1 | cut -d'=' -f2- || true)"
  if [ -z "$value" ]; then
    echo "Fehler: ${key} fehlt in ${ENV_FILE}" >&2
    exit 1
  fi
  printf '%s' "$value"
}

PROJECT_NAME="$(get_env_value PROJECT_NAME)"
BACKUP_DIR="$(get_env_value BACKUP_DIR)"
PATTERN="${PROJECT_NAME}_backup_*.tar.gz"

if [ ! -d "$BACKUP_DIR" ]; then
  echo "Fehler: Backup-Verzeichnis nicht gefunden: $BACKUP_DIR" >&2
  exit 1
fi

LATEST_BACKUP="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "$PATTERN" -print | sort | tail -n1)"
if [ -z "$LATEST_BACKUP" ]; then
  echo "Fehler: Kein Backup gefunden in ${BACKUP_DIR} mit Pattern ${PATTERN}" >&2
  exit 1
fi

echo "Nutze neuestes Backup: $LATEST_BACKUP"
"$RESTORE_SCRIPT" "$LATEST_BACKUP"
