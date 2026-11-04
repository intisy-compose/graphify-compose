#!/usr/bin/env bash
# watch-project.sh PATH: pins a persistent auto-watcher on a project, which survives across sessions.
# Like the per-session watcher the SessionStart hook starts, but flagged persistent so session end never
# stops it. Building and watching happen in a detached runner, which writes the state file itself, so it
# can never remove a state file before it exists; stop it with watch-stop.
set -uo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/watcher-state.sh
. "$scripts/watcher-state.sh"

stack=$(stack_folder "$0")
state_folder="$stack/.watchers"
runner="$scripts/watch-runner.sh"

fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# start_detached LOG PROJECT: starts the runner in its own process group where setsid exists (Linux),
# so watch-stop ends the runner and graphify together; Git Bash has no setsid and stops by taskkill /T.
start_detached() {
    local log=$1 project=$2
    if command -v setsid >/dev/null 2>&1; then
        setsid nohup bash "$runner" "$project" >"$log" 2>"$log.err" </dev/null &
    else
        nohup bash "$runner" "$project" >"$log" 2>"$log.err" </dev/null &
    fi
}

# wait_for_state FILE: the pid the runner recorded in FILE, within 10 s.
wait_for_state() {
    for _ in $(seq 100); do
        state_pid "$1" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}

# end_launched PID: ends the runner this script launched as local PID, whatever state it reached.
end_launched() {
    local windows_pid
    if is_windows_host; then
        windows_pid=$(state_pid_of "$1")
        [ -z "$windows_pid" ] || end_process_tree "$windows_pid"
        kill -KILL "$1" 2>/dev/null || true
    else
        end_process_tree "$1"
    fi
}

[ $# -eq 1 ] && [[ $1 != -* ]] || fail "Usage: ./docker-compose.sh watch <path>"
resolved=$(resolve_project "$1") || fail "Project folder not found: $1"
require_venv "$(venv_python "$stack")" || exit 1
mkdir -p "$state_folder"

digest=$(watcher_digest "$resolved")
state_file="$state_folder/$digest.json"
log_file="$state_folder/$digest.log"
lock="$state_folder/$digest.lock"
acquire_lock "$lock" || fail "Another watch of $resolved is still starting; try again."
trap 'release_lock "$lock"' EXIT
if [ -f "$state_file" ] && is_live_watcher "$state_file" "$stack"; then
    printf '\033[32m%s\033[0m\n' "Already watching $resolved"
    exit 0
fi

rm -f "$state_file" "$log_file.pid"
start_detached "$log_file" "$resolved"
launched=$!
if ! pid=$(wait_for_state "$state_file") || ! is_watcher_of "$pid" "$state_file" "$resolved" "$stack"; then
    end_launched "$launched"
    is_live_watcher "$state_file" "$stack" || rm -f "$state_file"
    fail "The watcher did not start; see $log_file.err"
fi

printf '\033[32m%s\033[0m\n' "Pinned persistent watcher (pid $pid) on $resolved"
printf '\033[90m%s\033[0m\n' "Stop it with: ./docker-compose.sh watch-stop \"$resolved\""
