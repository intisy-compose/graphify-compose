#!/usr/bin/env bash
# watch-list.sh: every graphify auto-watcher, session-managed and pinned, and whether it is alive.
set -euo pipefail
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

alive_word() { if process_is_alive "$1"; then echo True; else echo False; fi; }

row_format='%-7s %-5s %-10s %-4s %s\n'
# shellcheck disable=SC2059 # the format is a fixed variable, shared by the header and every row
printf "$row_format" Pid Alive Persistent Refs Project
# shellcheck disable=SC2059
printf "$row_format" --- ----- ---------- ---- -------
for file in "${state_files[@]}"; do
    pid=$(state_field "$file" pid)
    persistent=$(state_field "$file" persistent)
    # shellcheck disable=SC2059
    printf "$row_format" "$pid" "$(alive_word "$pid")" "${persistent:-False}" "$(state_field "$file" refs)" "$(state_field "$file" path)"
done
