#!/usr/bin/env bash
# watch-project.sh PATH: pins a persistent auto-watcher on a project, which survives across sessions.
# Like the per-session watcher the SessionStart hook starts, but flagged persistent so session end never
# stops it. Building and watching happen in a detached process; stop it with watch-stop.
set -euo pipefail
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

# wait_for_runner_pid PIDFILE: the id the runner wrote for itself. The runner writes it rather than
# watch-project reading $!, because on Git Bash the Windows PID changes when the runner execs.
wait_for_runner_pid() {
    for _ in $(seq 100); do
        if [ -s "$1" ]; then cat "$1"; return 0; fi
        sleep 0.1
    done
    return 1
}

[ $# -eq 1 ] && [[ $1 != -* ]] || fail "Usage: ./docker-compose.sh watch <path>"
resolved=$(resolve_project "$1") || fail "Project folder not found: $1"
mkdir -p "$state_folder"

digest=$(watcher_digest "$resolved")
state_file="$state_folder/$digest.json"
log_file="$state_folder/$digest.log"
rm -f "$log_file.pid"
start_detached "$log_file" "$resolved"
pid=$(wait_for_runner_pid "$log_file.pid") || fail "The watcher did not start; see $log_file.err"

write_state "$state_file" "$resolved" "$pid"

printf '\033[32m%s\033[0m\n' "Pinned persistent watcher (pid $pid) on $resolved"
printf '\033[90m%s\033[0m\n' "Stop it with: ./docker-compose.sh watch-stop \"$resolved\""
