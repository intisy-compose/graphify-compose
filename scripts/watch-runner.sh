#!/usr/bin/env bash
# watch-runner.sh PATH: the long-running watcher process, started detached by watch-project.sh. It writes
# its own persistent state file, builds the project's graph if it has none, then runs `graphify watch`,
# which rebuilds graph.json and graph.html in place on every change; the MCP server reloads the file on
# its next query. It ends itself, and removes its state file, once two checks in a row find
# graphify-server missing or stopped (one miss is a restart or a rebuild), but not while Docker itself
# is down. Not a command. WATCH_CHECK_SECONDS, a whole number (default 60), is how often it checks.
set -uo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/watcher-state.sh
. "$scripts/watcher-state.sh"

[ $# -eq 1 ] || { echo "Usage: watch-runner.sh <path>" >&2; exit 1; }
project=$1
stack=$(stack_folder "$0")
state_folder="$stack/.watchers"
state_file="$state_folder/$(watcher_digest "$project").json"
python=$(venv_python "$stack")
own_pid=$(state_pid_of $$)
watcher=""
pause_fifo=""
export GRAPHIFY_VIZ_NODE_LIMIT=20000

check_seconds() {
    local seconds=${WATCH_CHECK_SECONDS:-60}
    if [[ $seconds =~ ^[1-9][0-9]*$ ]]; then echo "$seconds"; return; fi
    echo "WATCH_CHECK_SECONDS=$seconds is not a whole number of seconds above 0; checking every 60 s." >&2
    echo 60
}

stack_is_gone() {
    docker info >/dev/null 2>&1 || return 1
    [ "$(docker inspect -f '{{.State.Running}}' graphify-server 2>/dev/null)" != true ]
}

end_graphify() {
    local pid
    [ -n "$watcher" ] || return 0
    pid=$(state_pid_of "$watcher")
    [ -z "$pid" ] || end_process_tree "$pid"
    watcher=""
}

remove_own_state_file() {
    [ "$(state_pid "$state_file" 2>/dev/null)" != "$own_pid" ] || rm -f "$state_file"
}

end_runner() {
    end_graphify
    [ -z "$pause_fifo" ] || rm -f "$pause_fifo"
}

# open_pause: a FIFO nobody writes to, held open and already unlinked, which `pause` waits on. A sleep
# child would be missed by the ps1's taskkill /T on Git Bash and outlive a stopped watcher.
open_pause() {
    pause_fifo=$(mktemp -u "$state_folder/pause.XXXXXX") || { pause_fifo=""; return 1; }
    if ! mkfifo "$pause_fifo" 2>/dev/null || ! exec {never_written}<>"$pause_fifo"; then
        rm -f "$pause_fifo"
        pause_fifo=""
        return 1
    fi
    rm -f "$pause_fifo"
    pause_fifo=""
}

# pause SECONDS: waits on the FIFO; a timeout is the only status above 128, so anything else means the
# read did not wait, and a sleep does instead, as it does when the FIFO could not be opened.
pause() {
    local status=0
    if [ -n "${never_written:-}" ]; then
        read -r -t "$1" -u "$never_written" || status=$?
        [ "$status" -le 128 ] || return 0
    fi
    sleep "$1"
}

trap end_runner EXIT
trap 'exit 143' TERM HUP INT

mkdir -p "$state_folder"
write_state "$state_file" "$project" "$own_pid" || exit 1

if [ ! -e "$project/graphify-out/graph.json" ]; then
    "$python" -m graphify update "$project"
fi

"$python" -m graphify watch "$project" &
watcher=$!
# After the start, so graphify does not inherit the FIFO: on Git Bash, a killed holder makes `exit` hang.
open_pause || echo "Could not open the pause FIFO; waiting with sleep." >&2
interval=$(check_seconds)
misses=0
while kill -0 "$watcher" 2>/dev/null; do
    if stack_is_gone; then misses=$((misses + 1)); else misses=0; fi
    if [ "$misses" -ge 2 ]; then
        end_graphify
        remove_own_state_file
        exit 0
    fi
    pause "$interval"
done
watcher=""
remove_own_state_file
