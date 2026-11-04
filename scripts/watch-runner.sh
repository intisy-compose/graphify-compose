#!/usr/bin/env bash
# watch-runner.sh PATH: the long-running watcher process, started detached by watch-project.sh. It
# builds the project's graph if it has none, then runs `graphify watch`, which rebuilds graph.json and
# graph.html in place on every change; the MCP server reloads the file on its next query. It ends
# itself, and removes its state file, once graphify-server is missing or stopped, but not while Docker
# itself is down. Not a command. WATCH_CHECK_SECONDS (default 60) is how often it checks.
set -uo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/watcher-state.sh
. "$scripts/watcher-state.sh"

[ $# -eq 1 ] || { echo "Usage: watch-runner.sh <path>" >&2; exit 1; }
project=$1
stack=$(stack_folder "$0")
state_folder="$stack/.watchers"
python=$(venv_python "$stack")
own_pid=$(state_pid_of $$)
export GRAPHIFY_VIZ_NODE_LIMIT=20000

stack_is_gone() {
    docker info >/dev/null 2>&1 || return 1
    [ "$(docker inspect -f '{{.State.Running}}' graphify-server 2>/dev/null)" != true ]
}

# open_pause: a FIFO nobody writes to, held open and already unlinked, which `pause` waits on. A sleep
# child would be missed by the ps1's taskkill /T on Git Bash and outlive a stopped watcher.
open_pause() {
    local fifo
    fifo=$(mktemp -u "$state_folder/pause.XXXXXX")
    mkfifo "$fifo"
    exec {never_written}<>"$fifo"
    rm -f "$fifo"
}

pause() { read -r -t "$1" -u "$never_written" || true; }

remove_own_state_file() {
    local file
    for file in "$state_folder"/*.json; do
        [ -f "$file" ] || continue
        [ "$(state_field "$file" pid 2>/dev/null)" != "$own_pid" ] || rm -f "$file"
    done
}

mkdir -p "$state_folder"
printf '%s' "$own_pid" >"$state_folder/$(watcher_digest "$project").log.pid"

if [ ! -e "$project/graphify-out/graph.json" ]; then
    "$python" -m graphify update "$project"
fi

"$python" -m graphify watch "$project" &
watcher=$!
# After the start, so graphify does not inherit the FIFO: on Git Bash, a killed holder makes `exit` hang.
open_pause
while kill -0 "$watcher" 2>/dev/null; do
    if stack_is_gone; then
        stop_process_tree "$(state_pid_of "$watcher")"
        remove_own_state_file
        exit 0
    fi
    pause "${WATCH_CHECK_SECONDS:-60}"
done
