#!/usr/bin/env bash
# watch-stop.sh PATH | --all: stops the auto-watcher of a project folder, or every watcher.
set -euo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/watcher-state.sh
. "$scripts/watcher-state.sh"

fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

if [ $# -ne 1 ] || { [ "$1" != --all ] && [[ $1 == -* ]]; }; then
    fail "Usage: ./docker-compose.sh watch-stop <path> | --all"
fi
state_folder="$(stack_folder "$0")/.watchers"
if [ ! -d "$state_folder" ]; then echo "No watchers."; exit 0; fi

stop_one() {
    local file=$1 pid path
    pid=$(state_field "$file" pid)
    path=$(state_field "$file" path)
    stop_process_tree "$pid"
    rm -f "$file"
    printf '\033[33m%s\033[0m\n' "Stopped watcher (pid $pid) for $path"
}

if [ "$1" = --all ]; then
    for file in "$state_folder"/*.json; do
        [ -f "$file" ] && stop_one "$file"
    done
    exit 0
fi

resolved=$(resolve_project "$1") || fail "Project folder not found: $1"
state_file="$state_folder/$(watcher_digest "$resolved").json"
if [ -f "$state_file" ]; then stop_one "$state_file"; else echo "No watcher found for $resolved"; fi
