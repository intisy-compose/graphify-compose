#!/usr/bin/env bash
# shellcheck disable=SC2016 # fixtures and patterns hold a literal $
# The Linux CLI's tests: each case copies the CLI into a scratch stack and runs it against a fake
# docker, curl and venv python first on PATH, so nothing on the host is touched. The watcher cases
# start real detached processes, so this runs from a worktree or CI, never the live stack folder.
# Plain bash: an `ok` or `FAIL` line per case, non-zero exit on any failure.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repository=$(cd "$here/../.." && pwd)
fakes="$here/fakes"
scratch=$(mktemp -d)
stack="$scratch/graphify-compose"
state="$scratch/state"
projects="$scratch/Projects"
REAL_SLEEP=$(command -v sleep)
export REAL_SLEEP

failures=0
case_name=""
case_failed=false
output=""
status=0
extra_path=""

# stop_leftovers: ends every runner and fake graphify a case left, so none outlives the suite. Each
# runner wrote its pid to a .log.pid file, which stays when the runner removed its state file.
stop_leftovers() {
    local file pid
    for file in "$stack"/.watchers/*.log.pid; do
        [ -f "$file" ] || continue
        pid=$(cat "$file")
        [ -z "$pid" ] || in_lib stop_process_tree "$pid"
    done
    pid=$(cat "$state/watch-pid" 2>/dev/null) && kill "$pid" 2>/dev/null
    return 0
}
trap 'stop_leftovers; rm -rf "$scratch"' EXIT

# in_lib FUNCTION ARGUMENTS...: runs a function of the watcher library, as the scripts do.
in_lib() { (. "$repository/scripts/watcher-state.sh" && "$@"); }

new_stack() {
    [ ! -d "$stack" ] || stop_leftovers
    rm -rf "$stack" "$state" "$projects"
    mkdir -p "$stack/scripts" "$stack/image" "$stack/hooks" "$state" "$projects/My-Project"
    cp "$repository/docker-compose.sh" "$repository/docker-compose.yml" "$repository/.env.example" "$stack/"
    cp "$repository/image/Dockerfile" "$repository/image/requirements.lock" "$stack/image/"
    cp "$repository"/scripts/*.sh "$stack/scripts/"
    install_venv
    : >"$state/calls"
    write_filled_env
}

# install_venv: the fake venv python where the scripts look for it on this OS.
install_venv() {
    local python
    python=$(in_lib venv_python "$stack")
    if [ -n "${MSYSTEM:-}" ]; then python="$stack/venv/Scripts/python.exe"; fi
    mkdir -p "$(dirname "$python")"
    cp "$fakes/venv-python" "$python"
    chmod +x "$python"
}

write_filled_env() {
    printf '%s\n' GRAPHIFY_API_KEY=real-secret-key PROJECTS_ROOT=/srv/projects TS_AUTHKEY=tskey-test \
        GRAPHIFY_HOST= PUBLIC_ACCESS=false >"$stack/.env"
}

begin() {
    case_name=$1
    case_failed=false
    output=""
    extra_path=""
    check_seconds=60
    new_stack
}

finish() {
    if $case_failed; then
        failures=$((failures + 1))
        printf '     %s\n' "${output//$'\n'/$'\n'     }"
    else
        echo "ok   $case_name"
    fi
}

# run_cli ARGUMENTS...: runs the scratch CLI with the fakes from $projects, keeping its output and exit code.
run_cli() {
    output=$(cd "$projects" && PATH="${extra_path:+$extra_path:}$fakes:$PATH" FAKE_DOCKER_DIR="$state" \
        WATCH_CHECK_SECONDS="$check_seconds" bash "$stack/docker-compose.sh" "$@" 2>&1)
    status=$?
}

# without_sleep: the next run_cli waits no real time, so a retry loop runs through in an instant.
without_sleep() {
    mkdir -p "$scratch/no-sleep"
    printf '%s\n' '#!/bin/bash' 'exit 0' >"$scratch/no-sleep/sleep"
    chmod +x "$scratch/no-sleep/sleep"
    extra_path="$scratch/no-sleep"
}

check() {
    local description=$1
    shift
    if ! "$@"; then
        $case_failed || echo "FAIL $case_name"
        echo "     - $description"
        case_failed=true
    fi
}

status_is() { [ "$status" -eq "$1" ]; }
said() { grep -qF -- "$1" <<<"$output"; }
not_said() { ! said "$1"; }
called() { grep -qE -- "$1" "$state/calls"; }
not_called() { ! called "$1"; }
env_has() { grep -qxF -- "$1" "$stack/.env"; }
no_cr() { [ "$(tr -cd '\r' <"$1" | wc -c)" -eq 0 ]; }

# called_before FIRST SECOND: the first call matching FIRST comes before the first matching SECOND.
called_before() {
    local first second
    first=$(grep -nE -- "$1" "$state/calls" | head -n 1 | cut -d: -f1)
    second=$(grep -nE -- "$2" "$state/calls" | head -n 1 | cut -d: -f1)
    [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]
}

# with_short_checks: a watcher the next run_cli starts checks the stack every 0.2 s, not every 60 s.
with_short_checks() { check_seconds=0.2; }

# text_called_before FIRST SECOND: as called_before, with plain text, which a Windows path needs.
text_called_before() {
    local first second
    first=$(grep -nF -- "$1" "$state/calls" | head -n 1 | cut -d: -f1)
    second=$(grep -nF -- "$2" "$state/calls" | head -n 1 | cut -d: -f1)
    [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]
}

# called_last_after FIRST SECOND: the last call matching SECOND comes after the first matching FIRST.
called_last_after() {
    local first last
    first=$(grep -nE -- "$1" "$state/calls" | head -n 1 | cut -d: -f1)
    last=$(grep -nE -- "$2" "$state/calls" | tail -n 1 | cut -d: -f1)
    [ -n "$first" ] && [ -n "$last" ] && [ "$first" -lt "$last" ]
}

set_state() { printf '%s\n' "${@:2}" >"$state/$1"; }

ps1_commands() {
    tr -d '\r' <"$repository/docker-compose.ps1" | awk '
        /^\$usage[[:space:]]*=[[:space:]]*@\{/ { inside = 1; next }
        inside && /^\}/ { exit }
        inside && /^[[:space:]]*"[^"]+"[[:space:]]*=/ { key = $0; sub(/^[[:space:]]*"/, "", key); sub(/".*/, "", key); print key }'
}

# native_path PATH: PATH as the hooks get it from Claude Code on this OS.
native_path() { if [ -n "${MSYSTEM:-}" ]; then cygpath -w "$1"; else printf '%s\n' "$1"; fi; }

# hook_digest PATH: the state file name hooks/session-end.py gives a session in PATH.
hook_digest() {
    python3 -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("session_end", sys.argv[1])
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)
print(hook.digest_for(sys.argv[2]))' "$(native_path "$repository/hooks/session-end.py")" "$(native_path "$1")"
}

state_files() { find "$stack/.watchers" -name '*.json' 2>/dev/null; }
state_file_count_is() { [ "$(state_files | wc -l)" -eq "$1" ]; }
the_state_file() { native_path "$(state_files | head -n 1)"; }
state_pid() { in_lib state_field "$(the_state_file)" pid; }
alive() { in_lib process_is_alive "$1"; }
dead() { ! alive "$1"; }
local_alive() { kill -0 "$1" 2>/dev/null; }
local_dead() { ! local_alive "$1"; }

# wait_for CHECK...: up to 10 s for CHECK to pass.
wait_for() {
    for _ in $(seq 100); do
        "$@" && return 0
        "$REAL_SLEEP" 0.1
    done
    return 1
}
watch_started() { [ -s "$state/watch-pid" ]; }
watch_pid() { cat "$state/watch-pid"; }

# start_watcher [PATH]: pins a watcher on PATH (the scratch project by default) and waits for graphify.
start_watcher() {
    rm -f "$state/watch-pid"
    run_cli watch "${1:-$projects/My-Project}"
    wait_for watch_started
}

## Skeleton

begin "the usage lists every command of the ps1's usage table"
run_cli help
check "exits 1" status_is 1
while IFS= read -r command; do
    check "usage names $command" grep -qE "^  $command " <<<"$output"
done < <(ps1_commands)
finish

begin "the usage text is the ps1's, with ./docker-compose.sh, / paths and long options"
run_cli help
check "the command list" said "Usage: ./docker-compose.sh [down|healthcheck|logs|rebuild|regraph|relock|restart|up|watch|watch-list|watch-stop]"
check "regraph with --force" said "  regraph      <path> [--force]  rebuild the default graph from a code folder"
check "watch-stop with --all" said "  watch-stop   <path> | --all  stop a watcher, or all of them"
check "relock with a / path" said "  relock       [<commit>]  re-resolve image/requirements.lock (optionally for a new graphify commit)"
check "no PowerShell spelling" not_said "-Force"
check "no -All" not_said "-All"
check "no backslash path" not_said 'image\requirements'
finish

begin "an unknown command shows the usage"
run_cli frobnicate
check "exits 1" status_is 1
check "prints the usage" said "Usage: ./docker-compose.sh ["
check "calls no docker" not_called .
finish

begin "an empty command shows the usage instead of running up"
run_cli ""
check "exits 1" status_is 1
check "prints the usage" said "Usage: ./docker-compose.sh ["
check "calls no docker" not_called .
finish

begin "no command at all runs up"
run_cli
check "exits 0" status_is 0
check "starts the stack" called "^compose up -d$"
finish

begin "a command without options refuses one"
for arguments in "up --bogus" "up -Force" "down --force" "restart x" "rebuild --fresh" "logs graphify" "relock a b" "relock --all"; do
    # shellcheck disable=SC2086 # split on purpose
    run_cli $arguments
    check "$arguments exits 1" status_is 1
    check "$arguments prints the usage" said "Usage: ./docker-compose.sh ["
done
check "calls no docker" not_called .
finish

begin "COMPOSE_PROJECT_NAME is unset"
output=$(cd "$projects" && COMPOSE_PROJECT_NAME=elsewhere PATH="$fakes:$PATH" FAKE_DOCKER_DIR="$state" \
    bash "$stack/docker-compose.sh" logs 2>&1)
check "docker never sees it" grep -qx unset "$state/compose-project-name"
finish

begin "the command is case-insensitive, as in the ps1"
run_cli LOGS
check "follows the logs" called "^compose logs -f$"
finish

## up, restart, down

begin "up and restart refuse without .env"
rm "$stack/.env"
run_cli up
check "exits 1" status_is 1
check "says how" said "No .env found - copy .env.example to .env and fill it in."
run_cli restart
check "restart exits 1" status_is 1
check "calls no docker" not_called .
finish

begin "up joins the tailnet first, writes GRAPHIFY_HOST and prints every URL"
run_cli up
check "exits 0" status_is 0
check "says it joined" said "Joined as graphify.tail-test.ts.net"
check "says it wrote it" said "Wrote GRAPHIFY_HOST to .env."
check "the ts.net name" env_has GRAPHIFY_HOST=graphify.tail-test.ts.net
check "the other lines stay" env_has GRAPHIFY_API_KEY=real-secret-key
check "LF endings" no_cr "$stack/.env"
check "tailscale before the rest" called_before "^compose up -d tailscale$" "^compose up -d$"
check "says it starts" said "Starting graphify..."
check "the MCP endpoint" said "  MCP endpoint   : http://localhost:8770/mcp"
check "the demo explorer" said "  Demo explorer  : http://localhost:8771/demo/graph.html"
check "any project" said "  Any project    : http://localhost:8771/projects/<path>/graphify-out/graph.html"
check "the tailnet" said "  On the tailnet : https://graphify.tail-test.ts.net/demo/graph.html   (from any device on your tailnet)"
finish

begin "up appends GRAPHIFY_HOST when .env has no line for it, and keeps the file's mode"
sed -i '/^GRAPHIFY_HOST=/d' "$stack/.env"
chmod 0600 "$stack/.env"
run_cli up
check "exits 0" status_is 0
check "appended" env_has GRAPHIFY_HOST=graphify.tail-test.ts.net
check "once" [ "$(grep -c '^GRAPHIFY_HOST=' "$stack/.env")" -eq 1 ]
if [ -z "${MSYSTEM:-}" ]; then check "still 0600" [ "$(stat -c %a "$stack/.env")" = 600 ]; fi
finish

begin "up without TS_AUTHKEY or a joined node starts on localhost only"
sed -i 's/^TS_AUTHKEY=.*/TS_AUTHKEY=/' "$stack/.env"
run_cli up
check "exits 0" status_is 0
check "says so" said "TS_AUTHKEY is empty in .env and this node has not joined the tailnet yet; the explorers"
check "and where to get a key" said "are on localhost only. Create a key at https://login.tailscale.com/admin/settings/keys"
check "no tailscale start" not_called "^compose up -d tailscale$"
check "still starts the stack" called "^compose up -d$"
finish

begin "up without a key still joins when the node joined before"
sed -i 's/^TS_AUTHKEY=.*/TS_AUTHKEY=/' "$stack/.env"
mkdir -p "$stack/data/tailscale" && : >"$stack/data/tailscale/tailscaled.state"
run_cli up
check "joins" called "^compose up -d tailscale$"
finish

begin "up goes on without the tailnet when the node does not join"
set_state tailnet stopped
without_sleep
run_cli up
check "exits 0" status_is 0
check "says so" said "The node did not join within 90s (an expired or used-up TS_AUTHKEY is the usual cause);"
check "with the sh's logs" said "the explorers are on localhost only. Check './docker-compose.sh logs'."
check "still starts the stack" called "^compose up -d$"
check "GRAPHIFY_HOST stays empty" env_has GRAPHIFY_HOST=
finish

begin "up goes on when the tailscale container does not start"
set_state tailscale-exit 1
set_state tailnet stopped
without_sleep
run_cli up
check "exits 0" status_is 0
check "says the node did not join" said "The node did not join within 90s"
check "still starts the stack" called "^compose up -d$"
finish

begin "restart recreates the stack after the tailnet"
run_cli restart
check "exits 0" status_is 0
check "says so" said "Recreating..."
check "recreates" called_before "^compose up -d tailscale$" "^compose up -d --force-recreate$"
finish

begin "down with no watchers says so, then stops the stack"
run_cli down
check "exits 0" status_is 0
check "says it stops" said "Stopping everything..."
check "no watchers" said "No watchers."
check "compose down" called "^compose down$"
finish

begin "down stops every watcher before the stack"
start_watcher
check "a watcher runs" alive "$(state_pid)"
runner=$(state_pid)
graphify=$(watch_pid)
run_cli down
check "exits 0" status_is 0
check "says it stopped it" said "Stopped watcher (pid $runner) for $(in_lib resolve_project "$projects/My-Project")"
check "graphify was gone when compose down ran" grep -qx gone "$state/down-saw-watcher"
check "the runner is gone" wait_for dead "$runner"
check "graphify is gone" local_dead "$graphify"
check "no state file left" state_file_count_is 0
finish

## rebuild and relock

begin "rebuild refuses without .env"
rm "$stack/.env"
run_cli rebuild
check "exits 1" status_is 1
check "calls no docker" not_called .
finish

begin "rebuild tags the previous image, builds, tests the candidate and only then switches"
run_cli rebuild
check "exits 0" status_is 0
check "tags previous" called "^tag graphify-server:latest graphify-server:previous$"
check "then builds" called_before "^tag graphify-server:latest" "^compose build graphify$"
check "runs the candidate on 127.0.0.1:18770" called "^run -d --name graphify-candidate -p 127.0.0.1:18770:8080 -e GRAPHIFY_API_KEY=candidate-check -v .*/graphify-out:/data:ro graphify-server:latest /data/graph.json --transport http --host 0.0.0.0 --port 8080$"
check "asks it with curl to /dev/null" called "^curl -s -o /dev/null -m 5 -w %\{http_code\} http://localhost:18770/mcp$"
check "says it serves" said "New image serves."
check "removes the candidate" called_last_after "^curl .*18770" "^rm -f graphify-candidate$"
check "switches" called "^compose up -d --force-recreate$"
check "the real key never reaches a command line" not_called "real-secret-key"
finish

begin "a failed build keeps the current image"
set_state build-exit 1
run_cli rebuild
check "exits 1" status_is 1
check "says so" said "Build failed - the current image is unchanged."
check "tags back" called "^tag graphify-server:previous graphify-server:latest$"
check "does not switch" not_called "^compose up"
finish

begin "a candidate that does not serve keeps the previous image and shows its log"
set_state candidate-status 000
set_state candidate-running false
without_sleep
run_cli rebuild
check "exits 1" status_is 1
check "says so" said "The new image does not serve - kept the previous one, the running stack is untouched."
check "shows the candidate's log" said "    candidate log line"
check "tags back" called "^tag graphify-server:previous graphify-server:latest$"
check "removes the candidate" called "^rm -f graphify-candidate$"
check "does not switch" not_called "^compose up"
finish

begin "a first build that does not serve has nothing to keep"
set_state image-exists no
set_state candidate-status 000
without_sleep
run_cli rebuild
check "exits 1" status_is 1
check "says so" said "The new image does not serve."
check "tags nothing" not_called "^tag "
finish

begin "relock refuses a short commit and changes nothing"
cp "$stack/docker-compose.yml" "$scratch/compose-before"
run_cli relock abc123
check "exits 1" status_is 1
check "says so" said "relock takes a full 40-character commit sha"
check "the compose file is unchanged" cmp -s "$scratch/compose-before" "$stack/docker-compose.yml"
check "calls no docker" not_called .
finish

begin "relock with a commit pins it and writes the lock without graphifyy"
commit=0123456789abcdef0123456789abcdef01234567
run_cli relock "$commit"
check "exits 0" status_is 0
check "pins the commit" grep -qF "graphify.git#$commit" "$stack/docker-compose.yml"
check "the compose file stays LF" no_cr "$stack/docker-compose.yml"
check "resolves in the Dockerfile's base image" called "^run --rm --entrypoint sh python:3\.12-slim@sha256:[0-9a-f]{64} -c "
check "for the archive of that commit" called "archive/$commit\.tar\.gz"
check "says which" said "Resolving dependencies for graphify 0123456..."
check "the lock" [ "$(cat "$stack/image/requirements.lock")" = "$(printf '%s\n' mcp==1.9.0 networkx==3.4.2 tree-sitter==0.24.0)" ]
check "the lock is LF" no_cr "$stack/image/requirements.lock"
check "counts them" said "Wrote 3 pinned packages to image/requirements.lock."
check "points at rebuild" said "  Run './docker-compose.sh rebuild' to build and test it, and move the host venv to the same"
finish

begin "a failed resolution leaves the lock unchanged"
cp "$stack/image/requirements.lock" "$scratch/lock-before"
set_state relock-exit 1
run_cli relock
check "exits 1" status_is 1
check "says so" said "Dependency resolution failed - requirements.lock is unchanged."
check "the lock is unchanged" cmp -s "$scratch/lock-before" "$stack/image/requirements.lock"
finish

## regraph

begin "regraph takes one path and --force, nothing else"
for arguments in "" "a b" "a -Force" "--all"; do
    # shellcheck disable=SC2086 # split on purpose
    run_cli regraph $arguments
    check "'$arguments' exits 1" status_is 1
    check "'$arguments' shows its usage" said "Usage: ./docker-compose.sh regraph <path> [--force]"
done
check "calls nothing" not_called .
finish

begin "regraph without the venv says how to recreate it"
rm -rf "$stack/venv"
run_cli regraph "$projects/My-Project"
check "exits 1" status_is 1
check "says so" said "graphify venv not found at"
if [ -z "${MSYSTEM:-}" ]; then check "points at CONTENT.md" said "'The host venv' in CONTENT.md"; fi
finish

begin "regraph refuses a missing folder"
run_cli regraph "$projects/Nowhere"
check "exits 1" status_is 1
check "says so" said "Target code folder not found: $projects/Nowhere"
finish

begin "regraph updates from the stack folder, then restarts the server"
run_cli regraph My-Project --force
project=$(in_lib resolve_project "$projects/My-Project")
check "exits 0" status_is 0
check "resolves the path against the caller's folder" said "Rebuilding graph from $project ..."
check "runs update with --force" grep -qF "venv-python -m graphify update $project --force | cwd=" "$state/calls"
check "from the stack folder with the node limit raised" grep -qE "update .* \| cwd=.*/graphify-compose \| limit=20000$" "$state/calls"
check "restarts the server" called "^restart graphify-server$"
check "says it reloads" said "Reloading container 'graphify-server' ..."
check "says it is done" said "Done. graphify MCP now serving the graph for 'My-Project'."
finish

begin "regraph stops when update fails or writes no graph"
set_state update-exit 3
run_cli regraph "$projects/My-Project"
check "exits 1" status_is 1
check "names the exit code" said "graphify update exited with code 3"
rm "$state/update-exit"
set_state no-graph yes
run_cli regraph "$projects/My-Project"
check "no graph exits 1" status_is 1
check "says so" said "Expected graph not produced at"
check "restarts nothing" not_called "^restart "
finish

## watchers

begin "the watcher's state file is named as the hooks name it"
mkdir -p "$projects/Mixed-Case Folder"
start_watcher "$projects/Mixed-Case Folder"
check "one state file" state_file_count_is 1
check "named as session-end.py names it" [ "$(basename "$(state_files | head -n 1)" .json)" = "$(hook_digest "$projects/Mixed-Case Folder")" ]
finish

begin "watch pins a detached persistent watcher, building the graph first"
start_watcher
project=$(in_lib resolve_project "$projects/My-Project")
file=$(the_state_file)
check "exits 0" status_is 0
check "graphify watch runs" watch_started
check "says so" said "Pinned persistent watcher (pid $(state_pid)) on $project"
check "and how to stop it" said "Stop it with: ./docker-compose.sh watch-stop \"$project\""
check "the path" [ "$(in_lib state_field "$file" path)" = "$project" ]
check "persistent" [ "$(in_lib state_field "$file" persistent)" = True ]
check "one ref" [ "$(in_lib state_field "$file" refs)" = 1 ]
check "the runner lives" alive "$(state_pid)"
check "built the graph first" text_called_before "venv-python -m graphify update $project |" "venv-python -m graphify watch $project |"
check "outlives the CLI" local_alive "$(watch_pid)"
finish

begin "watch does not rebuild a project that has a graph"
mkdir -p "$projects/My-Project/graphify-out" && : >"$projects/My-Project/graphify-out/graph.json"
start_watcher
check "no update" not_called "graphify update"
check "watches" called "graphify watch"
finish

begin "watch refuses a missing folder and a missing path"
run_cli watch "$projects/Nowhere"
check "exits 1" status_is 1
check "says so" said "Project folder not found: $projects/Nowhere"
run_cli watch
check "no path exits 1" status_is 1
check "says how" said "Usage: ./docker-compose.sh watch <path>"
check "no state" state_file_count_is 0
finish

begin "watch-list says when there is none, and shows each watcher alive or not"
run_cli watch-list
check "none" said "No watchers."
start_watcher
runner=$(state_pid)
run_cli watch-list
check "the header" said "Pid     Alive Persistent Refs Project"
check "alive" grep -qE "^$runner +True +True +1 +.*My-Project$" <<<"$output"
in_lib stop_process_tree "$runner"
run_cli watch-list
check "dead" grep -qE "^$runner +False " <<<"$output"
run_cli watch-list --all
check "takes no argument" status_is 1
finish

begin "watch-stop stops a watcher by a relative path, with graphify"
start_watcher
runner=$(state_pid)
graphify=$(watch_pid)
run_cli watch-stop My-Project
check "exits 0" status_is 0
check "says so" said "Stopped watcher (pid $runner) for $(in_lib resolve_project "$projects/My-Project")"
check "the runner is gone" wait_for dead "$runner"
check "graphify is gone" wait_for local_dead "$graphify"
check "the state file is gone" state_file_count_is 0
finish

begin "watch-stop --all stops every watcher"
mkdir -p "$projects/Other"
start_watcher
first=$(state_pid)
start_watcher "$projects/Other"
run_cli watch-stop --all
check "exits 0" status_is 0
check "two stopped" [ "$(grep -c 'Stopped watcher' <<<"$output")" -eq 2 ]
check "the first is gone" wait_for dead "$first"
check "no state file left" state_file_count_is 0
finish

begin "watch-stop names a folder without a watcher, and takes one path or --all"
mkdir -p "$stack/.watchers"
run_cli watch-stop "$projects/My-Project"
check "exits 0" status_is 0
check "says so" said "No watcher found for $(in_lib resolve_project "$projects/My-Project")"
for arguments in "" "-All" "a b"; do
    # shellcheck disable=SC2086 # split on purpose
    run_cli watch-stop $arguments
    check "'$arguments' exits 1" status_is 1
    check "'$arguments' shows its usage" said "Usage: ./docker-compose.sh watch-stop <path> | --all"
done
finish

begin "watch-stop and watch-list read a state file the ps1 wrote, byte order mark and all"
mkdir -p "$stack/.watchers"
project=$(in_lib resolve_project "$projects/My-Project")
digest=$(in_lib watcher_digest "$project")
python3 -c 'import json, sys
with open(sys.argv[1], "w", encoding="utf-8-sig") as handle:
    json.dump({"path": sys.argv[2], "pid": 999999, "refs": 1, "persistent": True}, handle, indent=4)' \
    "$(native_path "$stack/.watchers/$digest.json")" "$project"
run_cli watch-list
check "lists it as dead" grep -qE "^999999 +False +True +1 " <<<"$output"
run_cli watch-stop "$projects/My-Project"
check "stops it" said "Stopped watcher (pid 999999) for $project"
check "the state file is gone" state_file_count_is 0
finish

begin "a watcher ends itself once graphify-server is stopped"
with_short_checks
start_watcher
runner=$(state_pid)
graphify=$(watch_pid)
check "it runs first" alive "$runner"
set_state server-running false
check "the runner ends" wait_for dead "$runner"
check "graphify ends" wait_for local_dead "$graphify"
check "its state file is gone" wait_for state_file_count_is 0
finish

begin "a watcher ends itself once graphify-server is missing"
with_short_checks
start_watcher
runner=$(state_pid)
graphify=$(watch_pid)
set_state server-running missing
check "the runner ends" wait_for dead "$runner"
check "graphify ends" wait_for local_dead "$graphify"
check "its state file is gone" wait_for state_file_count_is 0
finish

begin "a watcher keeps running while Docker itself is down"
with_short_checks
set_state info-exit 1
set_state server-running missing
start_watcher
runner=$(state_pid)
"$REAL_SLEEP" 2
check "the runner lives" alive "$runner"
check "graphify lives" local_alive "$(watch_pid)"
check "its state file stays" state_file_count_is 1
check "its pause leaves no file" [ -z "$(find "$stack/.watchers" -name 'pause.*')" ]
check "it waits without a sleep process" bash -c '! ps -ef | grep -qE "[s]leep 0\.2$"'
finish

## healthcheck

begin "healthcheck stays quiet while the endpoint answers"
run_cli healthcheck
check "exits 0" status_is 0
check "asks the endpoint" called "^curl -s -o /dev/null -m 8 -w %\{http_code\} http://localhost:8770/mcp$"
check "calls no docker" not_called "^(info|restart)"
check "no log" [ ! -e "$stack/healthcheck.log" ]
finish

begin "healthcheck restarts both containers when the endpoint gives no status"
set_state mcp-status 000
run_cli healthcheck
check "exits 0" status_is 0
check "restarts both" called "^restart graphify-server graphify-web$"
check "logs it" grep -qE "^[0-9-]{10} [0-9:]{8}  unhealthy \(code=000\) -> restarting graphify \+ graphify-web$" "$stack/healthcheck.log"
finish

begin "healthcheck skips the restart while the daemon is down"
set_state mcp-status 000
set_state info-exit 1
run_cli healthcheck
check "exits 0" status_is 0
check "no restart" not_called "^restart "
check "logs it" grep -qF "unhealthy (code=000) but docker daemon down - skipping" "$stack/healthcheck.log"
run_cli healthcheck now
check "takes no argument" status_is 1
finish

echo
if [ "$failures" -eq 0 ]; then echo "all cases pass"; else echo "$failures cases fail"; fi
[ "$failures" -eq 0 ]
