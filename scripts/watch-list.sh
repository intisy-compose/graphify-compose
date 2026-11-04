#!/usr/bin/env bash
# watch-list.sh: every graphify auto-watcher, session-managed and pinned, and whether it is alive: its
# pid still runs that watcher, not merely some process.
set -uo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/watcher-state.sh
. "$scripts/watcher-state.sh"

[ $# -eq 0 ] || { printf '\033[31m%s\033[0m\n' "Usage: ./docker-compose.sh watch-list" >&2; exit 1; }
state_folder="$(stack_folder "$0")/.watchers"

state_files=()
if [ -d "$state_folder" ]; then
    for file in "$state_folder"/*.json; do [ -f "$file" ] && state_files+=("$file"); done
fi
if [ ${#state_files[@]} -eq 0 ]; then echo "No watchers."; exit 0; fi

alive_word() { if is_watcher_of "$1" "$2" "$3"; then echo True; else echo False; fi; }

persistent_word() { if [ "$(state_value "$1" persistent)" = true ]; then echo True; else echo False; fi; }

row_format='%-7s %-5s %-10s %-4s %s\n'
# shellcheck disable=SC2059 # the format is a fixed variable, shared by the header and every row
printf "$row_format" Pid Alive Persistent Refs Project
# shellcheck disable=SC2059
printf "$row_format" --- ----- ---------- ---- -------
for file in "${state_files[@]}"; do
    if ! pid=$(state_pid "$file") || ! path=$(state_path "$file"); then
        printf '\033[33m%s\033[0m\n' "Skipped $file: it is not a watcher state file" >&2
        continue
    fi
    # shellcheck disable=SC2059
    printf "$row_format" "$pid" "$(alive_word "$pid" "$file" "$path")" "$(persistent_word "$file")" "$(state_value "$file" refs)" "$path"
done
