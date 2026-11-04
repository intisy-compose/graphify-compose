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

## The watch lock: one watch of a project at a time, in either CLI, since two would each start a runner.

remove_lock_folder() {
    rm -f "$1/owner"
    rmdir "$1" 2>/dev/null
}

# is_stale_lock FOLDER: the owner file, or a folder with none, is older than a minute, so a watch that
# was killed left it.
is_stale_lock() {
    local held="$1/owner"
    [ -e "$held" ] || held=$1
    [ -n "$(find "$held" -maxdepth 0 -mmin +1 2>/dev/null)" ]
}

# break_stale_lock FOLDER: renames the lock to a name of this process's own before removing it, so of
# two watches breaking the same stale lock only one takes it. One that took a fresh lock instead, made
# by the other in between, puts it back.
break_stale_lock() {
    local aside="$1.broken.$$.$RANDOM"
    mv -T "$1" "$aside" 2>/dev/null || return 0
    if is_stale_lock "$aside"; then
        remove_lock_folder "$aside"
    else
        mv -T "$aside" "$1" 2>/dev/null || remove_lock_folder "$aside"
    fi
    return 0
}

# claim_lock FOLDER: creates the owner file with noclobber, which opens it O_EXCL, so of any number of
# watches only one succeeds. Creating the folder decides nothing: uutils mkdir (Ubuntu 26.04's) and
# PowerShell's New-Item both succeed for a folder another process created a moment before.
claim_lock() { (set -C && printf '%s\n' "$$" >"$1/owner") 2>/dev/null; }

# acquire_lock FOLDER: takes the lock within 15 s, or 150 tries if they come sooner. The clock bounds it
# on Git Bash, where a try can take half a second and a held lock would turn stale while it waits.
acquire_lock() {
    local deadline=$((SECONDS + 15))
    for _ in $(seq 150); do
        [ "$SECONDS" -lt "$deadline" ] || return 1
        mkdir -p "$1" 2>/dev/null && claim_lock "$1" && return 0
        if is_stale_lock "$1"; then break_stale_lock "$1"; continue; fi
        sleep 0.1
    done
    return 1
}

# release_lock FOLDER: gives up the lock if this process still holds it.
release_lock() {
    [ "$(cat "$1/owner" 2>/dev/null)" = "$$" ] || return 0
    remove_lock_folder "$1"
}

## Which process a pid is. Every comparison is of whole arguments, never of substrings: /w/app must not
## match a watcher of /w/app2 or of a folder below /w/app, nor this venv another checkout's.

# proc_stat_field PID INDEX: a field of /proc/PID/stat after the command name, counted from 0 (0 state,
# 1 parent, 2 process group, 19 start time in clock ticks since boot).
proc_stat_field() {
    local stat fields
    stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    read -ra fields <<<"${stat##*) }"
    echo "${fields[$2]}"
}

linux_start_seconds() {
    local ticks boot hertz
    ticks=$(proc_stat_field "$1" 19) || return 1
    boot=$(sed -n 's/^btime //p' /proc/stat)
    hertz=$(getconf CLK_TCK 2>/dev/null || echo 100)
    echo $((boot + ticks / hertz))
}

backslashes() {
    local text
    printf -v text '%*s' "$1" ''
    printf '%s' "${text// /\\}"
}

# windows_argv COMMAND_LINE: the arguments, one per line, split as Windows splits them
# (CommandLineToArgvW): whitespace outside quotes separates, quotes group, and backslashes are literal
# unless they precede a quote, where 2n give n and 2n+1 give n and a literal quote.
windows_argv() {
    local line=$1 index=0 length=${#1} character argument="" quoted=false started=false slashes
    while [ "$index" -lt "$length" ]; do
        character=${line:index:1}
        if [ "$character" = "\\" ]; then
            slashes=0
            while [ "${line:index:1}" = "\\" ]; do slashes=$((slashes + 1)); index=$((index + 1)); done
            if [ "${line:index:1}" = '"' ]; then
                argument+=$(backslashes $((slashes / 2)))
                if [ $((slashes % 2)) -eq 1 ]; then argument+='"'; index=$((index + 1)); fi
            else
                argument+=$(backslashes "$slashes")
            fi
            started=true
            continue
        fi
        if [ "$character" = '"' ]; then
            if $quoted; then quoted=false; else quoted=true; fi
            started=true
        elif [[ $character == [[:space:]] ]] && ! $quoted; then
            if $started; then printf '%s\n' "$argument"; fi
            argument=""
            started=false
        else
            argument+=$character
            started=true
        fi
        index=$((index + 1))
    done
    if $started; then printf '%s\n' "$argument"; fi
}

# process_record PID: the start in seconds since the epoch, then each argument, one per line, of a
# running process; nothing when there is none.
process_record() {
    local pid=$1 record
    is_valid_pid "$pid" || return 0
    if is_windows_host; then
        # shellcheck disable=SC2016 # PowerShell's own variables
        record=$(powershell.exe -NoProfile -NonInteractive -Command '$p = Get-CimInstance Win32_Process -Filter "ProcessId = '"$pid"'"; if ($p -and $p.CommandLine) { "{0}`t{1}" -f ([DateTimeOffset]$p.CreationDate).ToUnixTimeSeconds(), $p.CommandLine }' 2>/dev/null | tr -d '\r')
        [ -n "$record" ] || return 0
        echo "${record%%$'\t'*}"
        windows_argv "${record#*$'\t'}"
        return 0
    fi
    [ -r "/proc/$pid/cmdline" ] || return 0
    linux_start_seconds "$pid" || return 0
    tr '\0' '\n' <"/proc/$pid/cmdline"
}

# comparable_path PATH: on Windows a Git Bash path in Windows form, lowercased, with \ only, as Windows
# compares paths; elsewhere PATH itself.
comparable_path() {
    local path=$1
    if is_windows_host; then
        if [[ $path == /* ]]; then path=$(cygpath -w "$path"); fi
        path=${path//\//\\}
        path=${path,,}
    fi
    printf '%s' "$path"
}

same_path() { [ "$(comparable_path "$1")" = "$(comparable_path "$2")" ]; }

# is_runner_of STACK PATH ARGUMENT...: one argument is this stack's watch-runner.sh or .ps1 and the
# argument after it is PATH.
is_runner_of() {
    local stack_root=$1 path=$2 index
    shift 2
    local arguments=("$@")
    for ((index = 0; index + 1 < ${#arguments[@]}; index++)); do
        if { same_path "${arguments[index]}" "$stack_root/scripts/watch-runner.sh" ||
            same_path "${arguments[index]}" "$stack_root/scripts/watch-runner.ps1"; } &&
            same_path "${arguments[index + 1]}" "$path"; then
            return 0
        fi
    done
    return 1
}

is_shell() {
    local name=${1##*[/\\]}
    [[ ${name,,} =~ ^(ba)?sh(\.exe)?$ ]]
}

# is_graphify_of STACK PATH ARGUMENT...: the arguments are this stack's venv python, or a shell running
# it as a script, then exactly -m graphify watch PATH.
is_graphify_of() {
    local python path=$2 first
    python=$(venv_python "$1")
    shift 2
    local arguments=("$@")
    if same_path "${arguments[0]:-}" "$python"; then first=1
    elif is_shell "${arguments[0]:-}" && same_path "${arguments[1]:-}" "$python"; then first=2
    else return 1
    fi
    [ "${#arguments[@]}" -eq $((first + 4)) ] && [ "${arguments[first]}" = -m ] &&
        [ "${arguments[first + 1]}" = graphify ] && [ "${arguments[first + 2]}" = watch ] &&
        same_path "${arguments[first + 3]}" "$path"
}

# is_watcher_of PID FILE PATH STACK: PID is still the watcher the state FILE names. A pid is reused once
# its process ends, so it counts only while it runs this stack's watcher runner for PATH and started
# before FILE was last written, with 2 s for the clocks' rounding.
is_watcher_of() {
    local pid=$1 file=$2 path=$3 stack_root=$4 record
    mapfile -t record < <(process_record "$pid")
    [ ${#record[@]} -ge 2 ] && [[ ${record[0]} =~ ^[0-9]+$ ]] || return 1
    is_runner_of "$stack_root" "$path" "${record[@]:1}" || return 1
    [ "${record[0]}" -le $(($(stat -c %Y "$file") + 2)) ]
}

# is_live_watcher FILE STACK
is_live_watcher() {
    local pid path
    pid=$(state_pid "$1") && path=$(state_path "$1") && is_watcher_of "$pid" "$1" "$path" "$2"
}

# graphify_processes STACK PATH: the pids of this stack's venv running `graphify watch` on PATH. Found by
# command line, because a runner killed outright leaves its graphify running with no pid on record.
graphify_processes() {
    local pid command_line entry arguments
    if is_windows_host; then
        # shellcheck disable=SC2016 # PowerShell's own variables
        powershell.exe -NoProfile -NonInteractive -Command 'Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*graphify*watch*" } | ForEach-Object { "{0}`t{1}" -f $_.ProcessId, $_.CommandLine }' 2>/dev/null |
            tr -d '\r' | while IFS=$'\t' read -r pid command_line; do
                mapfile -t arguments < <(windows_argv "$command_line")
                if is_graphify_of "$1" "$2" "${arguments[@]}"; then echo "$pid"; fi
            done
        return 0
    fi
    for entry in /proc/[0-9]*/cmdline; do
        mapfile -t arguments < <(tr '\0' '\n' <"$entry" 2>/dev/null)
        [ ${#arguments[@]} -gt 0 ] || continue
        if is_graphify_of "$1" "$2" "${arguments[@]}"; then
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

linux_children() {
    local entry child
    for entry in /proc/[0-9]*/stat; do
        child=${entry#/proc/}
        child=${child%/stat}
        [ "$(proc_stat_field "$child" 1 2>/dev/null)" != "$1" ] || echo "$child"
    done
}

# signal_tree SIGNAL PID: a process that leads its own group (a runner started through setsid) is
# signalled with its whole group; any other only with its direct children.
signal_tree() {
    local signal=$1 pid=$2 child
    if [ "$(proc_stat_field "$pid" 2 2>/dev/null)" = "$pid" ]; then
        kill "-$signal" -- "-$pid" 2>/dev/null || true
        return 0
    fi
    for child in $(linux_children "$pid"); do kill "-$signal" "$child" 2>/dev/null || true; done
    kill "-$signal" "$pid" 2>/dev/null || true
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
    if is_watcher_of "$pid" "$file" "$path" "$2"; then
        end_process_tree "$pid"
    elif process_is_alive "$pid"; then
        verdict=foreign
    fi
    for orphan in $(graphify_processes "$2" "$path"); do end_process_tree "$orphan"; done
    echo "$verdict"
}
