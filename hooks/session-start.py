#!/usr/bin/env python3
"""SessionStart hook: auto-graph and auto-watch the project you open.

When a Claude Code session starts in a project under the GitHub root, this ensures
that project has a graph and launches a detached `graphify watch` for it, so the
graph rebuilds on every save and the MCP server hot-reloads it. Idempotent and
refcounted: multiple sessions in the same project share one watcher. Fast - it only
spawns a background process and returns; the build/watch happens detached. Exits 0
on anything unexpected so it never blocks session startup.
"""
import ctypes
import hashlib
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

GRAPHIFY_DIR = os.environ.get("GRAPHIFY_DIR") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read_env_file_value(key):
    try:
        with open(os.path.join(GRAPHIFY_DIR, ".env"), encoding="utf-8") as env_file:
            for line in env_file:
                name, separator, value = line.strip().partition("=")
                if separator and name.strip() == key:
                    return value.strip().strip('"')
    except OSError:
        pass
    return None


GITHUB_ROOT = os.environ.get("GRAPHIFY_PROJECTS_ROOT") or read_env_file_value("PROJECTS_ROOT")
RUNNER = os.path.join(GRAPHIFY_DIR, "watch-runner.ps1")
STATE_DIR = os.path.join(GRAPHIFY_DIR, ".watchers")
MCP_URL = "http://localhost:8770/mcp"
HEAL_LOG = os.path.join(GRAPHIFY_DIR, "healthcheck.log")

# Files that mark a directory as a real project worth graphing (avoids graphing the
# GitHub root or a bare language folder).
PROJECT_MARKERS = [
    ".git", "package.json", "pyproject.toml", "setup.py", "pom.xml",
    "build.gradle", "build.gradle.kts", "Cargo.toml", "go.mod", "composer.json",
]
PROJECT_GLOBS = ["*.csproj", "*.sln"]


def read_cwd():
    try:
        return json.load(sys.stdin).get("cwd") or os.getcwd()
    except Exception:
        return os.getcwd()


def is_project(cwd):
    if not GITHUB_ROOT:
        return False
    norm = os.path.normcase(os.path.abspath(cwd))
    if not norm.startswith(os.path.normcase(GITHUB_ROOT) + os.sep):
        return False
    if norm.startswith(os.path.normcase(GRAPHIFY_DIR)):
        return False  # don't watch the graphify tooling folder itself
    import glob
    for marker in PROJECT_MARKERS:
        if os.path.exists(os.path.join(cwd, marker)):
            return True
    for pattern in PROJECT_GLOBS:
        if glob.glob(os.path.join(cwd, pattern)):
            return True
    return False


def digest_for(cwd):
    return hashlib.md5(os.path.normcase(os.path.abspath(cwd)).encode()).hexdigest()[:12]


def is_alive(pid):
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    STILL_ACTIVE = 259
    handle = ctypes.windll.kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not handle:
        return False
    code = ctypes.c_ulong()
    ok = ctypes.windll.kernel32.GetExitCodeProcess(handle, ctypes.byref(code))
    ctypes.windll.kernel32.CloseHandle(handle)
    return bool(ok) and code.value == STILL_ACTIVE


def _ps_quote(value):
    return "'" + value.replace("'", "''") + "'"


def spawn_watcher(cwd, log_path):
    # Detach via PowerShell Start-Process: python's subprocess creationflags do not
    # produce a surviving detached process on this host, but Start-Process does. The
    # spawned watcher outlives this hook. The PID is written to a file rather than
    # stdout: the detached watcher inherits any stdout pipe and would keep it open,
    # hanging a capturing read until timeout. stdout is discarded so this returns
    # as soon as the launcher process exits.
    pid_file = log_path + ".pid"
    if os.path.exists(pid_file):
        os.remove(pid_file)
    args = ",".join(_ps_quote(a) for a in
                    ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", RUNNER, cwd])
    ps = (
        "$p = Start-Process powershell -ArgumentList {args} -WindowStyle Hidden "
        "-PassThru -RedirectStandardOutput {out} -RedirectStandardError {err}; "
        "[IO.File]::WriteAllText({pidf}, [string]$p.Id)"
    ).format(args=args, out=_ps_quote(log_path), err=_ps_quote(log_path + ".err"),
             pidf=_ps_quote(pid_file))
    subprocess.run(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        stdin=subprocess.DEVNULL, timeout=30)
    with open(pid_file, encoding="utf-8") as handle:
        return int(handle.read().strip())


def _log_heal(message):
    try:
        import time
        stamp = time.strftime("%Y-%m-%d %H:%M:%S")
        with open(HEAL_LOG, "a", encoding="utf-8") as handle:
            handle.write("{}  {}\n".format(stamp, message))
    except Exception:
        pass


def heal_graphify():
    """Restart the graphify containers if Docker's host->container port proxy has
    dropped (the container stays "Up" but the MCP is unreachable on the host). Any
    HTTP response - including the expected 401 (auth required) - means healthy. Runs
    on every session start regardless of cwd. OS-independent: urllib + the docker CLI."""
    try:
        urllib.request.urlopen(MCP_URL, timeout=5)
        return  # 200 -> healthy
    except urllib.error.HTTPError:
        return  # server answered (e.g. 401) -> reachable, healthy
    except Exception:
        pass    # no HTTP response -> proxy likely down; heal below
    try:
        subprocess.run(["docker", "restart", "graphify", "graphify-web"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       stdin=subprocess.DEVNULL, timeout=25)
        _log_heal("session-start: MCP unreachable -> restarted graphify + graphify-web")
    except Exception as exc:
        _log_heal("session-start: MCP unreachable, restart failed: {}".format(exc))


def main():
    heal_graphify()  # keep the MCP reachable before anything else needs it

    cwd = read_cwd()
    if not is_project(cwd):
        return

    os.makedirs(STATE_DIR, exist_ok=True)
    digest = digest_for(cwd)
    sp = os.path.join(STATE_DIR, digest + ".json")

    # Reuse an existing live watcher for this project; just bump the reference count.
    if os.path.exists(sp):
        try:
            state = json.load(open(sp, encoding="utf-8"))
            if is_alive(int(state["pid"])):
                state["refs"] = int(state.get("refs", 1)) + 1
                json.dump(state, open(sp, "w", encoding="utf-8"))
                return
        except Exception:
            pass  # stale/corrupt state file - fall through and start fresh

    pid = spawn_watcher(cwd, os.path.join(STATE_DIR, digest + ".log"))
    json.dump({"path": cwd, "pid": pid, "refs": 1}, open(sp, "w", encoding="utf-8"))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # never block session start
    sys.exit(0)
