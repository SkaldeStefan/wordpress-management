#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "${SCRIPT_DIR}/docker-compose.yml" ]; then
  echo "Fehler: install.sh muss aus dem Repo-Verzeichnis ausgeführt werden." >&2
  exit 1
fi
cd "$SCRIPT_DIR"

_pick_project_name() {
  local -a colors=(red green blue yellow orange purple pink cyan magenta lime)
  local -a fruits=(apple mango banana cherry grape lemon peach plum kiwi melon)
  local base="/srv/docker/wordpress"
  local name
  while true; do
    name="${colors[$((RANDOM % ${#colors[@]}))]}-${fruits[$((RANDOM % ${#fruits[@]}))]}"
    [ ! -d "${base}/${name}" ] && echo "$name" && return
  done
}

is_valid_project_name() {
  local value="$1"
  [[ "$value" =~ ^[a-z0-9][a-z0-9-]*$ ]]
}

is_valid_project_domain() {
  local value="$1"
  [[ "$value" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]
}

is_valid_hour() {
  local value="$1"
  [[ "$value" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]
}

if [ -z "${PROJECT_NAME:-}" ]; then
  _default="$(_pick_project_name)"
  while true; do
    read -rp "PROJECT_NAME [${_default}]: " PROJECT_NAME
    PROJECT_NAME="${PROJECT_NAME:-${_default}}"
    if is_valid_project_name "$PROJECT_NAME"; then
      break
    fi
    echo "Fehler: PROJECT_NAME darf nur Kleinbuchstaben, Ziffern und '-' enthalten." >&2
  done
elif ! is_valid_project_name "$PROJECT_NAME"; then
  echo "Fehler: PROJECT_NAME ist ungültig. Erlaubt sind nur Kleinbuchstaben, Ziffern und '-'." >&2
  exit 1
fi

if [ -z "${PROJECT_DOMAIN:-}" ]; then
  while true; do
    read -rp "PROJECT_DOMAIN: " PROJECT_DOMAIN
    PROJECT_DOMAIN="${PROJECT_DOMAIN,,}"
    if [ -z "$PROJECT_DOMAIN" ]; then
      echo "Fehler: PROJECT_DOMAIN darf nicht leer sein." >&2
      continue
    fi
    if is_valid_project_domain "$PROJECT_DOMAIN"; then
      break
    fi
    echo "Fehler: PROJECT_DOMAIN ist ungültig (erwartet z. B. blog.example.com)." >&2
  done
else
  PROJECT_DOMAIN="${PROJECT_DOMAIN,,}"
  if ! is_valid_project_domain "$PROJECT_DOMAIN"; then
    echo "Fehler: PROJECT_DOMAIN ist ungültig (erwartet z. B. blog.example.com)." >&2
    exit 1
  fi
fi

PROJECT_DIR="${PROJECT_DIR:-/srv/docker/wordpress/${PROJECT_NAME}}"
BACKUP_DIR="${BACKUP_DIR:-${PROJECT_DIR}/backups}"
BACKUP_RUN_HOUR="${BACKUP_RUN_HOUR:-2}"
TRAEFIK_NETWORK_NAME="${TRAEFIK_NETWORK_NAME:-traefik-proxy}"
TRAEFIK_MIDDLEWARES="${TRAEFIK_MIDDLEWARES:-}"
NETWORK_NAME="${NETWORK_NAME:-${PROJECT_NAME}_wp}"
DB_DATABASE="${DB_DATABASE:-wordpress}"
DB_USER="${DB_USER:-wordpress}"
DB_PASSWORD="${DB_PASSWORD:-$(openssl rand -base64 24 | tr -d '\n')}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-$(openssl rand -base64 24 | tr -d '\n')}"
WP_TABLE_PREFIX="${WP_TABLE_PREFIX:-wp$(openssl rand -hex 2)_}"

if ! is_valid_hour "$BACKUP_RUN_HOUR"; then
  echo "Fehler: BACKUP_RUN_HOUR muss zwischen 0 und 23 liegen." >&2
  exit 1
fi

ensure_env_key() {
  local env_file="$1"
  local key="$2"
  local value="$3"

  if ! sudo grep -q "^${key}=" "$env_file"; then
    echo "${key}=${value}" | sudo tee -a "$env_file" >/dev/null
  fi
}

sudo install -d -m 755 "$PROJECT_DIR"
sudo install -d -m 755 "$PROJECT_DIR/bin"
sudo install -m 644 docker-compose.yml "$PROJECT_DIR/docker-compose.yml"
sudo install -m 644 uploads.ini        "$PROJECT_DIR/uploads.ini"
sudo install -m 755 bin/backup.sh      "$PROJECT_DIR/bin/backup.sh"
sudo install -m 755 bin/backup-once.sh "$PROJECT_DIR/bin/backup-once.sh"
sudo install -m 755 bin/restore-from-file.sh "$PROJECT_DIR/bin/restore-from-file.sh"
sudo install -m 755 bin/restore-latest.sh    "$PROJECT_DIR/bin/restore-latest.sh"
sudo install -m 755 bin/wp-manage.sh         /usr/local/bin/wp-manage

if [ ! -f /usr/local/bin/wp ]; then
  sudo curl -fsSL \
    https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    -o /usr/local/bin/wp
  sudo chmod +x /usr/local/bin/wp
fi

sudo install -d -m 755 "$BACKUP_DIR"

if [ ! -f "$PROJECT_DIR/.env" ]; then
  cat <<EOF | sudo tee "$PROJECT_DIR/.env" >/dev/null
PROJECT_NAME=$PROJECT_NAME
PROJECT_DOMAIN=$PROJECT_DOMAIN
TRAEFIK_NETWORK_NAME=$TRAEFIK_NETWORK_NAME
TRAEFIK_MIDDLEWARES=$TRAEFIK_MIDDLEWARES
NETWORK_NAME=$NETWORK_NAME
DB_DATABASE=$DB_DATABASE
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_ROOT_PASSWORD=$DB_ROOT_PASSWORD
WP_TABLE_PREFIX=$WP_TABLE_PREFIX
BACKUP_DIR=$BACKUP_DIR
BACKUP_RUN_HOUR=$BACKUP_RUN_HOUR
EOF
else
  ensure_env_key "$PROJECT_DIR/.env" "PROJECT_NAME"        "$PROJECT_NAME"
  ensure_env_key "$PROJECT_DIR/.env" "PROJECT_DOMAIN"      "$PROJECT_DOMAIN"
  ensure_env_key "$PROJECT_DIR/.env" "TRAEFIK_NETWORK_NAME" "$TRAEFIK_NETWORK_NAME"
  ensure_env_key "$PROJECT_DIR/.env" "TRAEFIK_MIDDLEWARES"  "$TRAEFIK_MIDDLEWARES"
  ensure_env_key "$PROJECT_DIR/.env" "NETWORK_NAME"        "$NETWORK_NAME"
  ensure_env_key "$PROJECT_DIR/.env" "DB_DATABASE"         "$DB_DATABASE"
  ensure_env_key "$PROJECT_DIR/.env" "DB_USER"             "$DB_USER"
  ensure_env_key "$PROJECT_DIR/.env" "DB_PASSWORD"         "$DB_PASSWORD"
  ensure_env_key "$PROJECT_DIR/.env" "DB_ROOT_PASSWORD"    "$DB_ROOT_PASSWORD"
  ensure_env_key "$PROJECT_DIR/.env" "WP_TABLE_PREFIX"     "$WP_TABLE_PREFIX"
  ensure_env_key "$PROJECT_DIR/.env" "BACKUP_DIR"          "$BACKUP_DIR"
  ensure_env_key "$PROJECT_DIR/.env" "BACKUP_RUN_HOUR"     "$BACKUP_RUN_HOUR"
fi
sudo chmod 600 "$PROJECT_DIR/.env"

echo "Setup abgeschlossen."
echo "Starte mit: docker compose --project-directory $PROJECT_DIR up -d"
