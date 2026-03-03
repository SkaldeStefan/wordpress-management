#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(cd -- "${SCRIPT_DIR}/.." && pwd)}"
ENV_FILE="${PROJECT_DIR}/.env"

if [ $# -ne 1 ]; then
  echo "Usage: $0 <backup-archive.tar.gz>" >&2
  exit 1
fi

if [ ! -f "${PROJECT_DIR}/docker-compose.yml" ]; then
  echo "Fehler: docker-compose.yml nicht gefunden in ${PROJECT_DIR}" >&2
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

wait_for_db_ready() {
  local retries=30
  while [ "$retries" -gt 0 ]; do
    if docker compose --project-directory "$PROJECT_DIR" exec -T db sh -lc \
      'mariadb-admin --host=127.0.0.1 --port=3306 --user="$MYSQL_USER" --password="$MYSQL_PASSWORD" ping --silent' >/dev/null 2>&1; then
      return 0
    fi
    retries=$((retries - 1))
    sleep 2
  done
  return 1
}

BACKUP_ARG="$1"
if [ -f "$BACKUP_ARG" ]; then
  BACKUP_FILE="$(cd -- "$(dirname -- "$BACKUP_ARG")" && pwd)/$(basename -- "$BACKUP_ARG")"
else
  BACKUP_DIR="$(get_env_value BACKUP_DIR)"
  BACKUP_FILE="${BACKUP_DIR%/}/$BACKUP_ARG"
fi

if [ ! -f "$BACKUP_FILE" ]; then
  echo "Fehler: Backup-Datei nicht gefunden: $BACKUP_FILE" >&2
  exit 1
fi

if ! tar -tzf "$BACKUP_FILE" >/dev/null 2>&1; then
  echo "Fehler: Ungueltiges Backup-Archiv: $BACKUP_FILE" >&2
  exit 1
fi

if ! tar -tzf "$BACKUP_FILE" | grep -Eq '(^|/)(\./)?db\.sql$'; then
  echo "Fehler: db.sql fehlt im Archiv: $BACKUP_FILE" >&2
  exit 1
fi

echo "Restore gestartet aus: $BACKUP_FILE"

echo "Stoppe WordPress fuer konsistenten Restore..."
docker compose --project-directory "$PROJECT_DIR" stop wordpress >/dev/null 2>&1 || true

echo "Stelle sicher, dass Datenbank laeuft..."
docker compose --project-directory "$PROJECT_DIR" up -d db >/dev/null
if ! wait_for_db_ready; then
  echo "Fehler: Datenbank ist nicht bereit." >&2
  exit 1
fi

echo "Restore Datenbank..."
tar -xOzf "$BACKUP_FILE" --wildcards --no-anchored 'db.sql' \
  | docker compose --project-directory "$PROJECT_DIR" exec -T db sh -lc \
    'mariadb --host=127.0.0.1 --port=3306 --user="$MYSQL_USER" --password="$MYSQL_PASSWORD" "$MYSQL_DATABASE"'

if tar -tzf "$BACKUP_FILE" | grep -Eq '(^|/)(\./)?wp-content\.tar$'; then
  echo "Restore wp-content..."
  tar -xOzf "$BACKUP_FILE" --wildcards --no-anchored 'wp-content.tar' \
    | docker compose --project-directory "$PROJECT_DIR" run --rm --no-deps -T wpcli sh -lc \
      'set -e; cd /var/www/html; rm -rf wp-content; tar -xf -'
else
  echo "Hinweis: wp-content.tar nicht im Archiv, nur DB wurde restored."
fi

echo "Starte WordPress wieder..."
docker compose --project-directory "$PROJECT_DIR" up -d wordpress >/dev/null

echo "Restore abgeschlossen."
