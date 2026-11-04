#!/usr/bin/env bash
# watch-stop.sh PATH | --all: stops the auto-watcher of a project folder, or every watcher. A state file
# whose pid now belongs to another process is removed and that process left alone; a file that is not a
# state file is skipped with a warning, so one bad file never keeps the others running.
set -uo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/watcher-state.sh
. "$scripts/watcher-state.sh"

fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }

if [ $# -ne 1 ] || { [ "$1" != --all ] && [[ $1 == -* ]]; }; then
    fail "Usage: ./docker-compose.sh watch-stop <path> | --all"
fi
stack=$(stack_folder "$0")
state_folder="$stack/.watchers"
if [ ! -d "$state_folder" ]; then echo "No watchers."; exit 0; fi

stop_one() {
    local file=$1 pid path verdict
    if ! pid=$(state_pid "$file") || ! path=$(state_path "$file"); then
        warn "Skipped $file: it is not a watcher state file"
        return 0
    fi
    verdict=$(stop_watcher "$file" "$stack")
    rm -f "$file"
    if [ "$verdict" = foreign ]; then
        printf '\033[33m%s\033[0m\n' "Removed stale watcher state for $path: pid $pid is not its watcher"
    else
        printf '\033[33m%s\033[0m\n' "Stopped watcher (pid $pid) for $path"
    fi
}

if [ "$1" = --all ]; then
    failures=0
    for file in "$state_folder"/*.json; do
        [ -f "$file" ] || continue
        stop_one "$file" || { warn "Could not stop the watcher in $file"; failures=$((failures + 1)); }
    done
    [ "$failures" -eq 0 ]
    exit
fi

resolved=$(resolve_project "$1") || fail "Project folder not found: $1"
state_file="$state_folder/$(watcher_digest "$resolved").json"
if [ -f "$state_file" ]; then stop_one "$state_file"; else echo "No watcher found for $resolved"; fi
