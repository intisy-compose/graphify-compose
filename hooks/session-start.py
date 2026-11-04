#!/usr/bin/env python3
"""SessionStart hook: auto-graph and auto-watch the project you open, on Windows and on Linux.

When a Claude Code session starts in a project under the projects root, this ensures that project
has a graph and launches a detached session watcher for it (watch-runner.ps1 on Windows,
watch-runner.sh on Linux), so the graph rebuilds on every save and the MCP server hot-reloads it.
Ref-counted under the CLIs' watch lock: sessions in one project share one watcher, and a persistent
watcher pinned by `watch` is reused as it is. Only spawns and returns; exits 0 on anything
unexpected so it never blocks session startup.
"""
import glob
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

import watchers

GRAPHIFY_DIR = os.environ.get("GRAPHIFY_DIR") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE_DIR = os.path.join(GRAPHIFY_DIR, ".watchers")
MCP_URL = "http://localhost:8770/mcp"
HEAL_LOG = os.path.join(GRAPHIFY_DIR, "healthcheck.log")
LOCK_WAIT_SECONDS = 15

# Files that mark a directory as a real project worth graphing (avoids graphing the
# projects root or a bare language folder).
PROJECT_MARKERS = [
    ".git", "package.json", "pyproject.toml", "setup.py", "pom.xml",
    "build.gradle", "build.gradle.kts", "Cargo.toml", "go.mod", "composer.json",
]
PROJECT_GLOBS = ["*.csproj", "*.sln"]


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


def projects_root():
    return os.environ.get("GRAPHIFY_PROJECTS_ROOT") or read_env_file_value("PROJECTS_ROOT")


def is_project(cwd):
    root = projects_root()
    if not root:
        return False
    norm = os.path.normcase(os.path.abspath(cwd))
    if not norm.startswith(os.path.normcase(os.path.abspath(root)) + os.sep):
        return False
    if norm.startswith(os.path.normcase(GRAPHIFY_DIR)):
        return False  # don't watch the graphify tooling folder itself
    if any(os.path.exists(os.path.join(cwd, marker)) for marker in PROJECT_MARKERS):
        return True
    return any(glob.glob(os.path.join(cwd, pattern)) for pattern in PROJECT_GLOBS)


def _log_heal(message):
    try:
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
        subprocess.run(["docker", "restart", "graphify-server", "graphify-web"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       stdin=subprocess.DEVNULL, timeout=25)
        _log_heal("session-start: MCP unreachable -> restarted graphify-server + graphify-web")
    except Exception as exc:
        _log_heal("session-start: MCP unreachable, restart failed: {}".format(exc))


def join_session(project, windows=watchers.IS_WINDOWS):
    """Counts this session on PROJECT's live watcher, or starts one. Returns the watcher's pid, or
    None when there is no venv to run graphify from."""
    digest = watchers.digest_for(project, windows)
    state_file = os.path.join(STATE_DIR, digest + ".json")
    state = watchers.read_state(state_file)
    if state and watchers.is_watcher_of(state, state_file, GRAPHIFY_DIR, windows):
        if not state.get("persistent"):
            state["refs"] = int(state.get("refs", 1)) + 1
            watchers.write_state(state_file, state)
        return state["pid"]
    if not os.path.exists(watchers.venv_python(GRAPHIFY_DIR, windows)):
        return None
    command = watchers.runner_command(GRAPHIFY_DIR, project, windows)
    pid = watchers.spawn_runner(command, os.path.join(STATE_DIR, digest + ".log"), windows)
    watchers.write_state(state_file, {"path": project, "pid": pid, "refs": 1})
    return pid


def main():
    heal_graphify()  # keep the MCP reachable before anything else needs it

    cwd = watchers.read_session_cwd()
    if not is_project(cwd):
        return
    project = os.path.abspath(cwd)
    os.makedirs(STATE_DIR, exist_ok=True)
    lock = os.path.join(STATE_DIR, watchers.digest_for(project) + ".lock")
    if not watchers.acquire_lock(lock, LOCK_WAIT_SECONDS):
        return
    try:
        join_session(project)
    finally:
        watchers.release_lock(lock)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # never block session start
    sys.exit(0)
