#!/usr/bin/env bash
# healthcheck.sh: restarts graphify-server and graphify-web when the MCP endpoint gives no HTTP status.
# It exists for Docker Desktop, whose WSL2 port proxy can stop forwarding while the container stays Up;
# on a Docker Engine host the endpoint answers and this does nothing. Any HTTP status (401 is expected,
# the endpoint wants a key) means healthy. Nothing schedules it: a timer would outlive the stack.
set -uo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/watcher-state.sh
. "$scripts/watcher-state.sh"

[ $# -eq 0 ] || { printf '\033[31m%s\033[0m\n' "Usage: ./docker-compose.sh healthcheck" >&2; exit 1; }
url=http://localhost:8770/mcp
log_file="$(stack_folder "$0")/healthcheck.log"

write_log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$log_file"; }

code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "$url" 2>/dev/null)
if [[ $code =~ ^[0-9]{3}$ ]] && [ "$code" != 000 ]; then exit 0; fi

if ! command -v docker >/dev/null 2>&1; then
    write_log "unhealthy (code=$code) but docker CLI not found - skipping"
    exit 0
fi
if ! docker info >/dev/null 2>&1; then
    write_log "unhealthy (code=$code) but docker daemon down - skipping"
    exit 0
fi

write_log "unhealthy (code=$code) -> restarting graphify + graphify-web"
docker restart graphify-server graphify-web >/dev/null 2>&1
exit 0
