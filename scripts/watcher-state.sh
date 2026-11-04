#!/usr/bin/env bash
# Sourced by the watcher scripts: where a watcher's state lives, and how its process is found and ended.
# On Git Bash a state file records Windows PIDs and hashes the path lowercased, as docker-compose.ps1 and
# the hooks do there, so either CLI stops a watcher the other started.

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
    if is_windows_host; then cat "/proc/$1/winpid"; else echo "$1"; fi
}

process_is_alive() {
    if is_windows_host; then
        tasklist /FI "PID eq $1" /FO CSV /NH 2>/dev/null | grep -qF "\"$1\""
    else
        kill -0 "$1" 2>/dev/null
    fi
}

# signal_tree SIGNAL PID: a process that leads its own group (a watcher started through setsid) is
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

# git_bash_tree WINDOWS_PID: the Git Bash pids of that process and its descendants. taskkill /T walks
# Windows parents, which a Git Bash exec breaks, so it misses Git Bash children such as the runner's sleep.
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

# stop_process_tree PID: ends PID and the graphify process it runs; a PID that already exited counts
# as stopped.
stop_process_tree() {
    local pid=$1
    process_is_alive "$pid" || return 0
    if is_windows_host; then
        stop_windows_tree "$pid"
        return 0
    fi
    signal_tree TERM "$pid"
    wait_until_ended "$pid" || signal_tree KILL "$pid"
}

# state_field FILE FIELD: one field of a state file. The ps1 writes them with a byte order mark.
state_field() {
    python3 -c 'import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8-sig")).get(sys.argv[2])
print("" if value is None else value)' "$1" "$2"
}

# write_state FILE PATH PID: the state of a persistent watcher, in the shape the ps1 and the hooks read.
write_state() {
    python3 -c 'import json, sys
with open(sys.argv[1], "w", encoding="utf-8", newline="\n") as handle:
    json.dump({"path": sys.argv[2], "pid": int(sys.argv[3]), "refs": 1, "persistent": True}, handle)' "$1" "$2" "$3"
}
