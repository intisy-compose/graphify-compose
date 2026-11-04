#!/bin/bash
# shellcheck disable=SC2154 # state is set by the fake docker, which sources this
# The fake docker's answers, keyed on the command. Its state is a folder of small files, each written
# by the test that needs it and read here with a default:
#   tailnet            running | stopped (default running): what `tailscale status --json` reports
#   image-exists       yes | no (default yes): graphify-server:latest exists
#   server-running     true | false | missing (default true): graphify-server's State.Running
#   server-states      lines of the same words, answered one per check before server-running is
#   candidate-running  true | false (default true): graphify-candidate's State.Running
#   info-exit, build-exit, relock-exit, tailscale-exit: exit codes (default 0)
# `compose down` notes in down-saw-watcher whether the fake graphify watch still ran at that moment.

state_value() { cat "$state/$1" 2>/dev/null || echo "${2:-}"; }

answer_tailnet_status() {
    if [ "$(state_value tailnet running)" = running ]; then
        echo '{"BackendState": "Running", "Self": {"DNSName": "graphify.tail-test.ts.net."}}'
    else
        echo '{"BackendState": "NeedsLogin", "Self": {"DNSName": ""}}'
    fi
}

# answer_server_running: the first line of server-states, which it then drops, or server-running.
answer_server_running() {
    local answer
    answer=$(head -n 1 "$state/server-states" 2>/dev/null)
    if [ -n "$answer" ]; then sed -i 1d "$state/server-states"; else answer=$(state_value server-running true); fi
    case "$answer" in
        missing) echo "Error: No such object: graphify-server" >&2; return 1 ;;
        *) echo "$answer" ;;
    esac
}

answer_relock() {
    [ "$(state_value relock-exit 0)" -eq 0 ] || return "$(state_value relock-exit)"
    printf '%s\n' "graphifyy @ https://github.com/Graphify-Labs/graphify/archive/x.tar.gz" "mcp==1.9.0" "networkx==3.4.2" "" "tree-sitter==0.24.0"
}

note_watcher_at_down() {
    local pid
    pid=$(state_value watch-pid)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo alive; else echo gone; fi >"$state/down-saw-watcher"
}

answer() {
    case "$*" in
        "info") return "$(state_value info-exit 0)" ;;
        "image inspect graphify-server:latest") [ "$(state_value image-exists yes)" = yes ] ;;
        "inspect -f {{.State.Running}} graphify-server") answer_server_running ;;
        "inspect -f {{.State.Running}} graphify-candidate") state_value candidate-running true ;;
        "logs --tail 15 graphify-candidate") echo "candidate log line" ;;
        "run --rm --entrypoint sh "*) answer_relock ;;
        "compose exec -T tailscale "*) answer_tailnet_status ;;
        "compose build graphify") return "$(state_value build-exit 0)" ;;
        "compose up -d tailscale") return "$(state_value tailscale-exit 0)" ;;
        "compose down") note_watcher_at_down ;;
        *) return 0 ;;
    esac
}
