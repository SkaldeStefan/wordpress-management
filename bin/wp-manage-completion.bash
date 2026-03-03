#!/usr/bin/env bash
# Bash-Completion für wp-manage

_wp_manage_complete() {
  local cur prev words cword
  _init_completion || return

  local all_commands="list status start stop backup restore exec remove"
  local name_commands="status start stop backup restore exec remove"

  # Erstes Argument: Befehl
  if [ "$cword" -eq 1 ]; then
    COMPREPLY=($(compgen -W "$all_commands" -- "$cur"))
    return
  fi

  local cmd="${words[1]}"

  # Zweites Argument: Instanzname (für alle Befehle außer list)
  if [ "$cword" -eq 2 ]; then
    case " $name_commands " in
      *" $cmd "*)
        local wp_base="${WP_BASE:-/srv/docker/wordpress}"
        local instances=()
        local dir
        for dir in "${wp_base}"/*/; do
          [ -f "${dir}.env" ] && instances+=("$(basename "$dir")")
        done
        COMPREPLY=($(compgen -W "${instances[*]}" -- "$cur"))
        ;;
    esac
    return
  fi

  # Drittes Argument für restore: Backup-Datei aus dem Instanz-Backup-Verzeichnis
  if [ "$cword" -eq 3 ] && [ "$cmd" = "restore" ]; then
    local wp_base="${WP_BASE:-/srv/docker/wordpress}"
    local name="${words[2]}"
    local backup_dir
    backup_dir=$(grep -m1 '^BACKUP_DIR=' "${wp_base}/${name}/.env" 2>/dev/null | cut -d= -f2- || true)
    if [ -n "$backup_dir" ] && [ -d "$backup_dir" ]; then
      local files=()
      while IFS= read -r f; do
        files+=("$f")
      done < <(ls "${backup_dir}"/*.tar.gz 2>/dev/null | xargs -r -n1 basename 2>/dev/null || true)
      COMPREPLY=($(compgen -W "${files[*]}" -- "$cur"))
    else
      compopt -o filenames 2>/dev/null
      COMPREPLY=($(compgen -f -- "$cur"))
    fi
    return
  fi
}

complete -F _wp_manage_complete wp-manage
