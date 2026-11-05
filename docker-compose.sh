#!/usr/bin/env bash
# The Linux CLI, with the same commands and messages as docker-compose.ps1.
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }; then
    echo "docker-compose.sh needs bash 4.3 or newer; this is bash $BASH_VERSION" >&2
    exit 1
fi
set -euo pipefail
# Empty: every command has a Linux form. healthcheck works around Docker Desktop's port proxy and does
# nothing on a Docker Engine host, but it stays for parity, with no timer, as on Windows.
# shellcheck disable=SC2034 # read by the CLI parity check, not here
windows_only=()

# The compose file has no `name:`, so a set variable would rename the project.
unset COMPOSE_PROJECT_NAME

caller_folder=$PWD
here=$(cd "$(dirname "$0")" && pwd)
# Git Bash on Windows: docker.exe needs a Windows path here, and must get container paths unrewritten.
if [ -n "${MSYSTEM:-}" ]; then here=$(cd "$here" && pwd -W); export MSYS_NO_PATHCONV=1; fi

# shellcheck source=gateway/tailnet-node.sh
. "$here/gateway/tailnet-node.sh"

env_file="$here/.env"
compose=(docker compose --project-directory "$here" --env-file "$env_file")
image=graphify-server:latest
previous_image=graphify-server:previous
candidate_name=graphify-candidate
candidate_port=18770
compose_file="$here/docker-compose.yml"
dockerfile="$here/image/Dockerfile"
lock_file="$here/image/requirements.lock"
source_pattern='graphify\.git#[0-9a-f]{40}'

step() { printf '\033[36m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m%s\033[0m\n' "$*"; }
err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
fail() { err "$*"; exit 1; }

usage() {
    cat <<'EOF'
Usage: ./docker-compose.sh [delete|down|healthcheck|logs|rebuild|regraph|relock|restart|up|watch|watch-list|watch-stop]
  delete       Down, then remove the stack's node from the tailnet (with TS_API_TOKEN) and data/tailscale; for a stack being removed
  down         Stop and remove everything
  healthcheck  Restart the containers if the host port proxy dropped
  logs         Follow logs
  rebuild      Rebuild the pinned image, test it, and only then switch to it
  regraph      <path> [--force]  rebuild the default graph from a code folder
  relock       [<commit>]  re-resolve image/requirements.lock (optionally for a new graphify commit)
  restart      Recreate the stack from the current image
  up           Start the stack, building the image only if it is missing (default)
  watch        <path>  pin a persistent auto-watcher on a project
  watch-list   List auto-watchers and whether they are alive
  watch-stop   <path> | --all  stop a watcher, or all of them
EOF
    exit 1
}

no_options() { [ $# -eq 0 ] || usage; }

assert_setup() {
    [ -f "$env_file" ] || fail "No .env found - copy .env.example to .env and fill it in."
}

# run_helper NAME ARGUMENTS...: a helper resolves a relative path against the caller's folder, as the
# ps1's helpers run before it changes folder.
run_helper() {
    local name=$1
    shift
    cd "$caller_folder"
    exec bash "$here/scripts/$name.sh" "$@"
}

# env_value NAME: the last value .env gives NAME, trimmed and without surrounding quotes.
env_value() {
    [ -f "$env_file" ] || return 0
    tr -d '\r' <"$env_file" | awk -v name="$1" '
        match($0, /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=/) {
            key = substr($0, 1, RLENGTH - 1); gsub(/[ \t]/, "", key)
            if (key != name) next
            value = substr($0, RLENGTH + 1); sub(/^[ \t]+/, "", value); sub(/[ \t]+$/, "", value)
            gsub(/^"+|"+$/, "", value); found = 1
        }
        END { if (found) print value }'
}

# set_env_value NAME VALUE: rewrites the line that sets NAME, or appends one, keeping every other line,
# and writes the file back with LF endings, in place, so it keeps its mode.
set_env_value() {
    local name=$1 value=$2 line output="" found=false
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        if [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]] && [ "${BASH_REMATCH[1]}" = "$name" ]; then
            line="$name=$value"
            found=true
        fi
        output+="$line"$'\n'
    done <"$env_file"
    $found || output+="$name=$value"$'\n'
    printf '%s' "$output" >"$env_file"
}

# get_tailnet_status: the node's ts.net name once it runs on the tailnet, or nothing.
get_tailnet_status() {
    "${compose[@]}" exec -T tailscale tailscale --socket=/var/run/tailscale/tailscaled.sock status --json 2>/dev/null |
        python3 -c 'import json,sys
try: s = json.load(sys.stdin)
except ValueError: sys.exit(0)
name = (s.get("Self") or {}).get("DNSName") or ""
print(name.rstrip(".") if s.get("BackendState") == "Running" else "")' 2>/dev/null || true
}

# The MCP server and the local explorers do not need the tailnet, so a node that cannot join only
# loses the tailnet address; the gateway's certificate is for the ts.net name, written here first.
connect_tailnet() {
    local tailnet_host="" deadline
    if [ -z "$(env_value TS_AUTHKEY)" ] && [ ! -e "$here/data/tailscale/tailscaled.state" ]; then
        err "TS_AUTHKEY is empty in .env and this node has not joined the tailnet yet; the explorers"
        err "are on localhost only. Create a key at https://login.tailscale.com/admin/settings/keys"
        return 0
    fi
    step "Joining the tailnet..."
    "${compose[@]}" up -d tailscale || true
    deadline=$((SECONDS + 90))
    for _ in $(seq 45); do
        [ "$SECONDS" -lt "$deadline" ] || break
        tailnet_host=$(get_tailnet_status)
        [ -z "$tailnet_host" ] || break
        sleep 2
    done
    if [ -z "$tailnet_host" ]; then
        err "The node did not join within 90s (an expired or used-up TS_AUTHKEY is the usual cause);"
        err "the explorers are on localhost only. Check './docker-compose.sh logs'."
        return 0
    fi
    ok "Joined as $tailnet_host"
    if [ "$(env_value GRAPHIFY_HOST)" != "$tailnet_host" ]; then
        set_env_value GRAPHIFY_HOST "$tailnet_host"
        ok "Wrote GRAPHIFY_HOST to .env."
    fi
}

show_urls() {
    local tailnet_host
    tailnet_host=$(env_value GRAPHIFY_HOST)
    echo
    echo "  MCP endpoint   : http://localhost:8770/mcp"
    echo "  Demo explorer  : http://localhost:8771/demo/graph.html"
    echo "  Any project    : http://localhost:8771/projects/<path>/graphify-out/graph.html"
    if [ -n "$tailnet_host" ]; then
        echo "  On the tailnet : https://$tailnet_host/demo/graph.html   (from any device on your tailnet)"
    fi
}

image_exists() { docker image inspect "$1" >/dev/null 2>&1; }

get_pinned_source() {
    local match
    match=$(tr -d '\r' <"$compose_file" | grep -oE "$source_pattern" | head -n 1) ||
        fail "No pinned graphify commit found in docker-compose.yml"
    echo "${match#*#}"
}

get_base_image() {
    local base
    base=$(tr -d '\r' <"$dockerfile" | sed -nE 's/^FROM[[:space:]]+([^[:space:]]+).*/\1/p' | head -n 1)
    [ -n "$base" ] || fail "No FROM line found in image/Dockerfile"
    echo "$base"
}

is_http_status() { [[ $1 =~ ^[0-9]{3}$ ]] && [ "$1" != 000 ]; }

# test_image_serves IMAGE: any HTTP status from /mcp means the server came up; 000 means it never
# answered. The key is a throwaway, so the real one never reaches a command line.
test_image_serves() {
    local name=$1 code serves=false deadline=$((SECONDS + 90))
    docker rm -f "$candidate_name" >/dev/null 2>&1 || true
    docker run -d --name "$candidate_name" -p "127.0.0.1:$candidate_port:8080" -e GRAPHIFY_API_KEY=candidate-check \
        -v "$here/graphify-out:/data:ro" "$name" \
        /data/graph.json --transport http --host 0.0.0.0 --port 8080 >/dev/null 2>&1 || true
    for _ in $(seq 45); do
        [ "$SECONDS" -lt "$deadline" ] || break
        code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://localhost:$candidate_port/mcp" 2>/dev/null || true)
        if is_http_status "$code"; then serves=true; break; fi
        [ "$(docker inspect -f '{{.State.Running}}' "$candidate_name" 2>/dev/null)" = true ] || break
        sleep 2
    done
    if ! $serves; then
        docker logs --tail 15 "$candidate_name" 2>&1 | sed 's/^/    /'
    fi
    docker rm -f "$candidate_name" >/dev/null 2>&1 || true
    $serves
}

invoke_safe_rebuild() {
    local had_image=false
    if image_exists "$image"; then had_image=true; docker tag "$image" "$previous_image"; fi

    step "Building the pinned image..."
    if ! "${compose[@]}" build graphify; then
        if $had_image; then docker tag "$previous_image" "$image"; fi
        fail "Build failed - the current image is unchanged."
    fi

    step "Testing the new image on :$candidate_port before switching..."
    if ! test_image_serves "$image"; then
        if $had_image; then
            docker tag "$previous_image" "$image"
            fail "The new image does not serve - kept the previous one, the running stack is untouched."
        fi
        fail "The new image does not serve."
    fi
    ok "New image serves."
    "${compose[@]}" up -d --force-recreate
    show_urls
}

# write_lf FILE TEXT: TEXT with LF endings, in place.
write_lf() { printf '%s' "$2" >"$1"; }

invoke_relock() {
    local commit=${1:-} source base archive frozen locked count
    if [ -n "$commit" ]; then
        [[ $commit =~ ^[0-9a-f]{40}$ ]] || fail "relock takes a full 40-character commit sha"
        write_lf "$compose_file" "$(tr -d '\r' <"$compose_file" | sed -E "s/$source_pattern/graphify.git#$commit/")"$'\n'
    fi
    source=$(get_pinned_source)
    base=$(get_base_image)
    step "Resolving dependencies for graphify ${source:0:7}..."
    archive="https://github.com/Graphify-Labs/graphify/archive/$source.tar.gz"
    frozen=$(docker run --rm --entrypoint sh "$base" -c "pip install -q --no-cache-dir --root-user-action=ignore --disable-pip-version-check 'graphifyy[mcp] @ $archive' >&2 && pip freeze") ||
        fail "Dependency resolution failed - requirements.lock is unchanged."
    locked=$(tr -d '\r' <<<"$frozen" | grep -vE '^graphifyy\b' | grep -v '^$' || true)
    count=$(grep -c . <<<"$locked" || true)
    write_lf "$lock_file" "$locked"$'\n'
    ok "Wrote $count pinned packages to image/requirements.lock."
    echo "  Run './docker-compose.sh rebuild' to build and test it, and move the host venv to the same"
    echo "  graphify commit so the watchers and the server stay in step."
}

invoke_up() {
    assert_setup
    connect_tailnet
    step "Starting graphify..."
    "${compose[@]}" up -d
    show_urls
}

invoke_recreate() {
    assert_setup
    connect_tailnet
    step "Recreating..."
    "${compose[@]}" up -d --force-recreate
    show_urls
}

invoke_down() {
    step "Stopping everything..."
    bash "$here/scripts/watch-stop.sh" --all ||
        err "Warning: not every watcher could be stopped; check './docker-compose.sh watch-list'."
    "${compose[@]}" down
}

# invoke_delete: how the stack is deleted: down, then its node leaves the tailnet and data/tailscale
# goes, so a later up joins fresh. Removing the folder afterwards is the human's step.
invoke_delete() {
    local node_name
    invoke_down || fail "docker compose down failed, so the node stays in the tailnet."
    node_name=$(env_value GRAPHIFY_HOST)
    [ -n "$node_name" ] || node_name=$(env_value TS_HOSTNAME)
    remove_tailnet_identity "$here/data/tailscale" "${node_name:-graphify}" "$env_file" || exit 1
    ok "Deleted. Remove this folder to finish."
}

cd "$here"
command=$(printf '%s' "${1-up}" | tr '[:upper:]' '[:lower:]')
[ $# -eq 0 ] || shift
case "$command" in
    up)          no_options "$@"; invoke_up ;;
    down)        no_options "$@"; invoke_down ;;
    delete)      no_options "$@"; invoke_delete ;;
    restart)     no_options "$@"; invoke_recreate ;;
    rebuild)     no_options "$@"; assert_setup; invoke_safe_rebuild ;;
    relock)      [ $# -le 1 ] && [[ ${1:-} != -* ]] || usage; invoke_relock "$@" ;;
    logs)        no_options "$@"; "${compose[@]}" logs -f ;;
    regraph)     run_helper regraph "$@" ;;
    watch)       run_helper watch-project "$@" ;;
    watch-list)  run_helper watch-list "$@" ;;
    watch-stop)  run_helper watch-stop "$@" ;;
    healthcheck) run_helper healthcheck "$@" ;;
    *)           usage ;;
esac
