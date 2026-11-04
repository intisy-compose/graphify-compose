#!/usr/bin/env bash
# Sourced by the watcher scripts: a watcher's state file, whether the pid in it is still that watcher,
# and how a watcher is ended. On Git Bash a state file records Windows PIDs and hashes the path
# lowercased, as docker-compose.ps1 and the hooks do there, so either CLI stops a watcher the other started.

is_windows_host() { [ -n "${MSYSTEM:-}" ]; }

# taskkill and tasklist take /-options, which Git Bash would otherwise rewrite into paths.
if is_windows_host; then export MSYS_NO_PATHCONV=1; fi

# stack_folder SCRIPT: the stack folder above SCRIPT's scripts/ folder, in a form docker and python3 read.
stack_folder() {
    if is_windows_host; then (cd "$(dirname "$1")/.." && pwd -W); else (cd "$(dirname "$1")/.." && pwd); fi
}

venv_python() {
    if is_windows_host; then echo "$1/venv/Scripts/python.exe"; else echo "$1/venv/bin/python"; fi
}

# require_venv PYTHON: fails with the way to a venv when PYTHON is missing.
require_venv() {
    [ ! -x "$1" ] || return 0
    if is_windows_host; then
        printf '\033[31m%s\033[0m\n' "graphify venv not found at $1 (is the venv intact?)" >&2
    else
        printf '\033[31m%s\033[0m\n' "graphify venv not found at $1 (is the venv intact?) - on Linux, create it as 'The host venv' in CONTENT.md says." >&2
    fi
    return 1
}

# resolve_project PATH: PATH made absolute, as Resolve-Path gives it on Windows and os.path.abspath on Linux.
resolve_project() {
    local absolute
    absolute=$(cd -- "$1" 2>/dev/null && pwd) || return 1
    if is_windows_host; then cygpath -w "$absolute"; else printf '%s\n' "$absolute"; fi
}

# watcher_digest PATH: the name of PATH's state file. The hooks hash os.path.normcase of the path, which
# lowercases only on Windows, so the path is hashed as given everywhere else.
watcher_digest() {
    local path=$1
    if is_windows_host; then path=${path,,}; fi
    printf '%s' "$path" | md5sum | cut -c1-12
}

# state_pid_of PID: the id a state file records for the local process PID.
state_pid_of() {
    if is_windows_host; then cat "/proc/$1/winpid" 2>/dev/null; else echo "$1"; fi
}

is_valid_pid() { [[ ${1:-} =~ ^[0-9]+$ ]] && [ "$1" -ge 2 ]; }

process_is_alive() {
    is_valid_pid "$1" || return 1
    if is_windows_host; then
        tasklist /FI "PID eq $1" /FO CSV /NH 2>/dev/null | grep -qF "\"$1\""
    else
        kill -0 "$1" 2>/dev/null
    fi
}

## State files: one JSON object, written by this library, by the ps1 (indented, with a byte order mark)
## or by the hooks. Read with sed, so stopping a watcher needs no python.

state_text() { tr -d '\r\n' <"$1" | LC_ALL=C sed 's/^\xEF\xBB\xBF//'; }

# shellcheck disable=SC2059 # a \u escape is decoded by being printf's format
json_unescape() {
    local text=$1 result="" character
    while [ -n "$text" ]; do
        character=${text:0:1}
        if [ "$character" != "\\" ]; then result+=$character; text=${text:1}; continue; fi
        case ${text:1:1} in
            u) printf -v character "\\u${text:2:4}"; text=${text:6} ;;
            n) character=$'\n'; text=${text:2} ;;
            t) character=$'\t'; text=${text:2} ;;
            *) character=${text:1:1}; text=${text:2} ;;
        esac
        result+=$character
    done
    printf '%s\n' "$result"
}

json_string() {
    local text=${1//\\/\\\\}
    printf '"%s"' "${text//\"/\\\"}"
}

# state_pid FILE: the pid a state file records; fails unless it is a whole number of 2 or more.
state_pid() {
    local pid
    pid=$(state_text "$1" | LC_ALL=C sed -nE 's/.*"pid"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p')
    is_valid_pid "$pid" || return 1
    echo "$pid"
}

state_path() {
    local raw
    raw=$(state_text "$1" | LC_ALL=C sed -nE 's/.*"path"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p')
    [ -n "$raw" ] || return 1
    json_unescape "$raw"
}

# state_value FILE NAME: a number or true/false field of a state file, or nothing.
state_value() { state_text "$1" | LC_ALL=C sed -nE "s/.*\"$2\"[[:space:]]*:[[:space:]]*([A-Za-z0-9]+).*/\1/p"; }

# write_state FILE PATH PID: the state of a persistent watcher, written whole through a temporary file,
# in the shape the ps1 and the hooks read.
write_state() {
    printf '{"path": %s, "pid": %s, "refs": 1, "persistent": true}' "$(json_string "$2")" "$3" >"$1.tmp" &&
        mv -f "$1.tmp" "$1"
}

## Which process a pid is

# process_record PID: "START_SECONDS<TAB>COMMAND LINE" of a running process, or nothing.
process_record() {
    local pid=$1 elapsed
    is_valid_pid "$pid" || return 0
    if is_windows_host; then
        # shellcheck disable=SC2016 # PowerShell's own variables
        powershell.exe -NoProfile -NonInteractive -Command '$p = Get-CimInstance Win32_Process -Filter "ProcessId = '"$pid"'"; if ($p) { "{0}`t{1}" -f ([DateTimeOffset]$p.CreationDate).ToUnixTimeSeconds(), $p.CommandLine }' 2>/dev/null | tr -d '\r'
        return 0
    fi
    [ -r "/proc/$pid/cmdline" ] || return 0
    elapsed=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$elapsed" ] || return 0
    printf '%s\t%s\n' "$(($(date +%s) - elapsed))" "$(tr '\0' ' ' <"/proc/$pid/cmdline")"
}

# has_text HAYSTACK NEEDLE: on Windows case-insensitively and with / and \ alike, as paths are written there.
has_text() {
    local haystack=$1 needle=$2
    if is_windows_host; then
        haystack=${haystack,,}; needle=${needle,,}
        haystack=${haystack//\//\\}; needle=${needle//\//\\}
    fi
    [[ $haystack == *"$needle"* ]]
}

# is_watcher_of PID FILE PATH: PID is still the watcher the state FILE names. A pid is reused once its
# process ends, so it counts only while it runs a watcher runner for PATH and started before FILE was
# last written, with 2 s for the clocks' rounding.
is_watcher_of() {
    local pid=$1 file=$2 path=$3 record started command_line
    record=$(process_record "$pid")
    [ -n "$record" ] || return 1
    started=${record%%$'\t'*}
    command_line=${record#*$'\t'}
    [[ $command_line == *watch-runner.sh* || $command_line == *watch-runner.ps1* ]] || return 1
    has_text "$command_line" "$path" || return 1
    [[ $started =~ ^[0-9]+$ ]] && [ "$started" -le $(($(stat -c %Y "$file") + 2)) ]
}

is_live_watcher() {
    local pid path
    pid=$(state_pid "$1") && path=$(state_path "$1") && is_watcher_of "$pid" "$1" "$path"
}

# graphify_processes STACK PATH: the pids of this stack's venv running `graphify watch` on PATH. Found by
# command line, because a runner killed outright leaves its graphify running with no pid on record.
graphify_processes() {
    local python pid command_line entry
    python=$(venv_python "$1")
    if is_windows_host; then
        # shellcheck disable=SC2016 # PowerShell's own variables
        powershell.exe -NoProfile -NonInteractive -Command 'Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*-m graphify watch*" } | ForEach-Object { "{0}`t{1}" -f $_.ProcessId, $_.CommandLine }' 2>/dev/null |
            tr -d '\r' | while IFS=$'\t' read -r pid command_line; do
                has_text "$command_line" "$python" && has_text "$command_line" "$2" && echo "$pid"
            done
        return 0
    fi
    for entry in /proc/[0-9]*/cmdline; do
        command_line=$(tr '\0' ' ' <"$entry" 2>/dev/null) || continue
        if [[ $command_line == *"-m graphify watch"* ]] && has_text "$command_line" "$python" && has_text "$command_line" "$2"; then
            pid=${entry#/proc/}
            echo "${pid%/cmdline}"
        fi
    done
}

## Ending processes

# git_bash_tree WINDOWS_PID: the Git Bash pids of that process and its descendants. taskkill /T walks
# Windows parents, which a Git Bash exec breaks, so it misses Git Bash children.
git_bash_tree() {
    ps | awk -v winpid="$1" '
        NR > 1 {
            if ($1 !~ /^[0-9]+$/) { $1 = ""; $0 = $0 }
            parent[$1] = $2
            if ($4 == winpid) root = $1
        }
        END {
            if (root == "") exit
            tree[root] = 1; print root
            do {
                grown = 0
                for (pid in parent) if (!(pid in tree) && (parent[pid] in tree)) { tree[pid] = 1; print pid; grown = 1 }
            } while (grown)
        }'
}

stop_windows_tree() {
    local pid=$1 tree
    mapfile -t tree < <(git_bash_tree "$pid")
    taskkill /PID "$pid" /T /F >/dev/null 2>&1 || true
    [ ${#tree[@]} -eq 0 ] || kill -KILL "${tree[@]}" 2>/dev/null || true
}

# signal_tree SIGNAL PID: a process that leads its own group (a runner started through setsid) is
# signalled with its whole group; any other only with its direct children.
signal_tree() {
    local signal=$1 pid=$2
    if [ "$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$pid" ]; then
        kill "-$signal" -- "-$pid" 2>/dev/null || true
    else
        pkill "-$signal" -P "$pid" 2>/dev/null || true
        kill "-$signal" "$pid" 2>/dev/null || true
    fi
}

wait_until_ended() {
    for _ in $(seq 50); do
        process_is_alive "$1" || return 0
        sleep 0.1
    done
    ! process_is_alive "$1"
}

# end_process_tree PID: ends PID and what it runs, without asking what PID is; callers that read PID
# from a state file ask is_watcher_of first.
end_process_tree() {
    local pid=$1
    process_is_alive "$pid" || return 0
    if is_windows_host; then
        stop_windows_tree "$pid"
        return 0
    fi
    signal_tree TERM "$pid"
    wait_until_ended "$pid" || signal_tree KILL "$pid"
}

# stop_watcher FILE STACK: ends the watcher the state FILE names and any graphify it left behind. Prints
# "foreign" when the pid now belongs to another process, which is left alone, and "stopped" otherwise;
# fails for a file that is not a state file.
stop_watcher() {
    local file=$1 pid path orphan verdict=stopped
    pid=$(state_pid "$file") && path=$(state_path "$file") || return 1
    if is_watcher_of "$pid" "$file" "$path"; then
        end_process_tree "$pid"
    elif process_is_alive "$pid"; then
        verdict=foreign
    fi
    for orphan in $(graphify_processes "$2" "$path"); do end_process_tree "$orphan"; done
    echo "$verdict"
}
