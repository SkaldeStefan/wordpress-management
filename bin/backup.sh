#!/usr/bin/env sh
set -eu

PROJECT_NAME="${PROJECT_NAME:-wordpress}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
WP_ROOT="${WP_ROOT:-/var/www/html}"
WP_CONTENT_PATH="${WP_CONTENT_PATH:-${WP_ROOT}/wp-content}"
DB_HOST="${WORDPRESS_DB_HOST:?WORDPRESS_DB_HOST is required}"
DB_USER="${WORDPRESS_DB_USER:?WORDPRESS_DB_USER is required}"
DB_PASSWORD="${WORDPRESS_DB_PASSWORD:?WORDPRESS_DB_PASSWORD is required}"
DB_NAME="${WORDPRESS_DB_NAME:?WORDPRESS_DB_NAME is required}"
DB_PORT="${WORDPRESS_DB_PORT:-3306}"
BACKUP_RUN_HOUR="${BACKUP_RUN_HOUR:-2}"
BACKUP_MODE="${BACKUP_MODE:-schedule}"
STATE_FILE="${BACKUP_DIR}/.last_backup_date"

TMP_DIR=""

log() {
  printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

cleanup_tmp() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
  TMP_DIR=""
}

trap cleanup_tmp EXIT INT TERM

validate_run_hour() {
  case "$BACKUP_RUN_HOUR" in
    ''|*[!0-9]*)
      log "BACKUP_RUN_HOUR must be an integer between 0 and 23."
      exit 1
      ;;
  esac

  if [ "$BACKUP_RUN_HOUR" -lt 0 ] || [ "$BACKUP_RUN_HOUR" -gt 23 ]; then
    log "BACKUP_RUN_HOUR must be an integer between 0 and 23."
    exit 1
  fi
}

validate_mode() {
  case "$BACKUP_MODE" in
    schedule|once)
      ;;
    *)
      log "BACKUP_MODE must be either 'schedule' or 'once'."
      exit 1
      ;;
  esac
}

wait_for_db() {
  probe_bin="mariadb-admin"
  if ! command -v "$probe_bin" >/dev/null 2>&1; then
    probe_bin="mysqladmin"
  fi

  retries=60
  while [ "$retries" -gt 0 ]; do
    if MYSQL_PWD="$DB_PASSWORD" "$probe_bin" --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" ping --silent >/dev/null 2>&1; then
      return 0
    fi
    retries=$((retries - 1))
    sleep 5
  done

  log "Database is not reachable; backup skipped."
  return 1
}

run_db_dump() {
  dump_bin="mariadb-dump"
  if ! command -v "$dump_bin" >/dev/null 2>&1; then
    dump_bin="mysqldump"
  fi

  MYSQL_PWD="$DB_PASSWORD" "$dump_bin" \
    --single-transaction \
    --quick \
    --skip-lock-tables \
    --host="$DB_HOST" \
    --port="$DB_PORT" \
    --user="$DB_USER" \
    "$DB_NAME" > "$1"
}

create_backup() {
  backup_date="$(date -u +%F)"
  archive_path="${BACKUP_DIR}/${PROJECT_NAME}_backup_${backup_date}.tar.gz"
  tmp_archive="${archive_path}.tmp"

  if [ -f "$archive_path" ]; then
    log "Backup for ${backup_date} already exists."
    return 0
  fi

  TMP_DIR="$(mktemp -d "${BACKUP_DIR}/.tmp.${PROJECT_NAME}.${backup_date}.XXXXXX")"
  run_db_dump "${TMP_DIR}/db.sql"

  if [ -d "$WP_CONTENT_PATH" ]; then
    tar -C "$WP_ROOT" -cf "${TMP_DIR}/wp-content.tar" wp-content
  else
    log "wp-content not found at ${WP_CONTENT_PATH}; archive includes only database dump."
  fi

  tar -C "$TMP_DIR" -czf "$tmp_archive" .
  mv "$tmp_archive" "$archive_path"
  chmod 600 "$archive_path"
  cleanup_tmp

  printf '%s\n' "$backup_date" > "$STATE_FILE"
  log "Created backup: ${archive_path}"
}

cleanup_backups() {
  now_epoch="$(date -u +%s)"
  twelve_months_ago_epoch="$(date -u -d '12 months ago' +%s)"
  weekly_keys_file="$(mktemp)"
  monthly_keys_file="$(mktemp)"

  find "$BACKUP_DIR" -maxdepth 1 -type f -name "${PROJECT_NAME}_backup_*.tar.gz" -print | sort -r | while IFS= read -r backup_file; do
    [ -n "$backup_file" ] || continue

    backup_name="$(basename "$backup_file")"
    backup_date="${backup_name#${PROJECT_NAME}_backup_}"
    backup_date="${backup_date%.tar.gz}"

    backup_epoch="$(date -u -d "$backup_date" +%s 2>/dev/null || true)"
    if [ -z "$backup_epoch" ]; then
      log "Skipping backup with unexpected name: ${backup_name}"
      continue
    fi

    age_days=$(( (now_epoch - backup_epoch) / 86400 ))

    if [ "$backup_epoch" -lt "$twelve_months_ago_epoch" ]; then
      rm -f "$backup_file"
      log "Deleted old backup (>12 months): ${backup_name}"
      continue
    fi

    if [ "$age_days" -le 6 ]; then
      continue
    fi

    if [ "$age_days" -le 34 ]; then
      week_key="$((age_days / 7))"
      if grep -qx "$week_key" "$weekly_keys_file"; then
        rm -f "$backup_file"
        log "Deleted weekly duplicate backup: ${backup_name}"
      else
        printf '%s\n' "$week_key" >> "$weekly_keys_file"
      fi
      continue
    fi

    month_key="$(date -u -d "$backup_date" +%Y-%m)"
    if grep -qx "$month_key" "$monthly_keys_file"; then
      rm -f "$backup_file"
      log "Deleted monthly duplicate backup: ${backup_name}"
    else
      printf '%s\n' "$month_key" >> "$monthly_keys_file"
    fi
  done

  rm -f "$weekly_keys_file" "$monthly_keys_file"
}

main() {
  validate_mode
  validate_run_hour
  mkdir -p "$BACKUP_DIR"

  if [ "$BACKUP_MODE" = "once" ]; then
    log "Backup started in one-shot mode."
    if wait_for_db; then
      create_backup
      cleanup_backups
      log "One-shot backup completed."
      exit 0
    fi
    log "One-shot backup failed: database is not reachable."
    exit 1
  fi

  log "Backup scheduler started. Daily run hour (UTC): ${BACKUP_RUN_HOUR}"

  while true; do
    current_date="$(date -u +%F)"
    current_hour="$(date -u +%H)"
    last_run_date=""

    if [ -f "$STATE_FILE" ]; then
      last_run_date="$(cat "$STATE_FILE")"
    fi

    if [ "$last_run_date" != "$current_date" ] && [ "$current_hour" -ge "$BACKUP_RUN_HOUR" ]; then
      if wait_for_db; then
        create_backup
        cleanup_backups
      fi
    fi

    sleep 300
  done
}

main "$@"
