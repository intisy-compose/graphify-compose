#!/usr/bin/env bash
# regraph.sh PATH [--force]: rebuilds the default graph from a code folder with the venv's
# `graphify update`, into graphify-out/graph.json (the file the container serves), then restarts the
# container so the MCP tools query the new graph at once. Point it at code, not data-heavy folders.
# --force overwrites graph.json even when the rebuild has fewer nodes, as after a refactor that
# legitimately deletes code.
set -euo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/watcher-state.sh
. "$scripts/watcher-state.sh"

stack=$(stack_folder "$0")
python=$(venv_python "$stack")
graph_file="$stack/graphify-out/graph.json"
container_name=graphify-server

step() { printf '\033[36m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

target=""
force=false
for argument in "$@"; do
    case "$argument" in
        --force) force=true ;;
        -*) fail "Usage: ./docker-compose.sh regraph <path> [--force]" ;;
        *) [ -z "$target" ] || fail "Usage: ./docker-compose.sh regraph <path> [--force]"; target=$argument ;;
    esac
done
[ -n "$target" ] || fail "Usage: ./docker-compose.sh regraph <path> [--force]"

assert_prerequisites() {
    if [ ! -x "$python" ]; then
        is_windows_host || fail "graphify venv not found at $python (is the venv intact?) - on Linux, create it as 'The host venv' in CONTENT.md says."
        fail "graphify venv not found at $python (is the venv intact?)"
    fi
    [ -d "$target" ] || fail "Target code folder not found: $target"
}

# invoke_graph_rebuild: runs from the stack folder, so `update` writes this folder's
# graphify-out/graph.json, which the container binds to /data. The node limit is raised so graph.html
# is generated even for a large graph (the default is 5000).
invoke_graph_rebuild() {
    local resolved update_exit=0 update_arguments
    resolved=$(resolve_project "$target")
    step "Rebuilding graph from $resolved ..."
    update_arguments=(update "$resolved")
    if $force; then update_arguments+=(--force); fi
    (cd "$stack" && GRAPHIFY_VIZ_NODE_LIMIT=20000 "$python" -m graphify "${update_arguments[@]}") || update_exit=$?
    [ "$update_exit" -eq 0 ] || fail "graphify update exited with code $update_exit"
}

restart_graphify_container() {
    [ -f "$graph_file" ] || fail "Expected graph not produced at $graph_file"
    step "Reloading container '$container_name' ..."
    docker restart "$container_name" >/dev/null || fail "docker restart failed for '$container_name'"
}

assert_prerequisites
invoke_graph_rebuild
restart_graphify_container

printf '\033[32m%s\033[0m\n' "Done. graphify MCP now serving the graph for '$target'."
printf '\033[90m%s\033[0m\n' "Run /mcp in Claude Code if tools don't refresh automatically."
