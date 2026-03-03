#!/usr/bin/env bash
set -euo pipefail

WP_BASE="${WP_BASE:-/srv/docker/wordpress}"

_usage() {
  cat >&2 <<EOF
Verwendung: wp-manage <Befehl> [Argumente]

Befehle:
  list                    Alle WordPress-Instanzen auflisten
  status  <name>          Container-Status einer Instanz anzeigen
  start   <name>          Instanz starten
  stop    <name>          Instanz stoppen
  backup  <name>          Einmal-Backup auslösen
  restore <name> [datei]  Wiederherstellen (neuestes Backup oder aus Datei)
  exec    <name> <befehl> WP-CLI-Befehl in einer Instanz ausführen
  remove  <name>          Instanz vollständig entfernen (inkl. Volumes und Backups)
EOF
  exit 1
}

_require_name() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "Fehler: Name der Instanz fehlt." >&2
    exit 1
  fi
  if [ ! -d "${WP_BASE}/${name}" ]; then
    echo "Fehler: Instanz '${name}' nicht gefunden in ${WP_BASE}." >&2
    exit 1
  fi
}

cmd_list() {
  local found=0
  printf "%-20s %-35s %s\n" "NAME" "DOMAIN" "STATUS"
  printf "%-20s %-35s %s\n" "--------------------" "-----------------------------------" "--------"

  for dir in "${WP_BASE}"/*/; do
    [ -f "${dir}.env" ] || continue
    found=1

    local name domain status
    name="$(basename "$dir")"
    domain="$(grep -m1 '^PROJECT_DOMAIN=' "${dir}.env" | cut -d= -f2-)"

    local wp_id
    wp_id="$(docker compose --project-directory "$dir" ps -q wordpress 2>/dev/null || true)"
    if [ -n "$wp_id" ] && [ "$(docker inspect -f '{{.State.Running}}' "$wp_id" 2>/dev/null || echo false)" = "true" ]; then
      status="running"
    else
      status="stopped"
    fi

    printf "%-20s %-35s %s\n" "$name" "$domain" "$status"
  done

  if [ "$found" -eq 0 ]; then
    echo "(Keine Instanzen gefunden in ${WP_BASE})"
  fi
}

cmd_status() {
  local name="$1"
  _require_name "$name"
  docker compose --project-directory "${WP_BASE}/${name}" ps
}

cmd_start() {
  local name="$1"
  _require_name "$name"
  docker compose --project-directory "${WP_BASE}/${name}" up -d
}

cmd_stop() {
  local name="$1"
  _require_name "$name"
  docker compose --project-directory "${WP_BASE}/${name}" stop
}

cmd_backup() {
  local name="$1"
  _require_name "$name"
  local script="${WP_BASE}/${name}/bin/backup-once.sh"
  if [ ! -x "$script" ]; then
    echo "Fehler: ${script} nicht gefunden oder nicht ausführbar." >&2
    exit 1
  fi
  "$script"
}

cmd_restore() {
  local name="$1"
  local file="${2:-}"
  _require_name "$name"

  if [ -n "$file" ]; then
    local script="${WP_BASE}/${name}/bin/restore-from-file.sh"
    if [ ! -x "$script" ]; then
      echo "Fehler: ${script} nicht gefunden oder nicht ausführbar." >&2
      exit 1
    fi
    "$script" "$file"
  else
    local script="${WP_BASE}/${name}/bin/restore-latest.sh"
    if [ ! -x "$script" ]; then
      echo "Fehler: ${script} nicht gefunden oder nicht ausführbar." >&2
      exit 1
    fi
    "$script"
  fi
}

cmd_remove() {
  local name="$1"
  _require_name "$name"
  local domain
  domain="$(grep -m1 '^PROJECT_DOMAIN=' "${WP_BASE}/${name}/.env" | cut -d= -f2-)"
  echo "WARNUNG: Instanz '${name}' (${domain}) wird unwiderruflich gelöscht."
  echo "  - Alle Container und Volumes werden entfernt"
  echo "  - Das Verzeichnis ${WP_BASE}/${name} wird gelöscht (inkl. Backups)"
  printf "Zur Bestätigung 'ja' eingeben: "
  read -r confirm
  if [ "$confirm" != "ja" ]; then
    echo "Abgebrochen." >&2
    exit 1
  fi
  docker compose --project-directory "${WP_BASE}/${name}" down --volumes || true
  sudo rm -rf "${WP_BASE:?}/${name}"
  echo "Instanz '${name}' wurde gelöscht."
}

cmd_exec() {
  local name="${1:-}"
  shift || true
  _require_name "$name"
  docker exec "${name}_wordpress" wp "$@"
}

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
  list)    cmd_list ;;
  status)  cmd_status "${1:-}" ;;
  start)   cmd_start  "${1:-}" ;;
  stop)    cmd_stop   "${1:-}" ;;
  backup)  cmd_backup "${1:-}" ;;
  restore) cmd_restore "${1:-}" "${2:-}" ;;
  exec)    cmd_exec "${1:-}" "${@:2}" ;;
  remove)  cmd_remove "${1:-}" ;;
  *)       _usage ;;
esac
