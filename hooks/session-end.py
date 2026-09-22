#!/usr/bin/env python3
"""SessionEnd hook: stop the current project's auto-watcher when its last session closes.

Decrements the reference count started by session-start.py. When it reaches zero the
detached watcher process tree is killed and the state file removed, so watchers never
accumulate. Exits 0 on anything unexpected.
"""
import hashlib
import json
import os
import subprocess
import sys

GRAPHIFY_DIR = os.environ.get("GRAPHIFY_DIR") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE_DIR = os.path.join(GRAPHIFY_DIR, ".watchers")


def read_cwd():
    try:
        return json.load(sys.stdin).get("cwd") or os.getcwd()
    except Exception:
        return os.getcwd()


def digest_for(cwd):
    return hashlib.md5(os.path.normcase(os.path.abspath(cwd)).encode()).hexdigest()[:12]


def kill_tree(pid):
    subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    cwd = read_cwd()
    sp = os.path.join(STATE_DIR, digest_for(cwd) + ".json")
    if not os.path.exists(sp):
        return

    state = json.load(open(sp, encoding="utf-8"))
    if state.get("persistent"):
        return  # manually pinned via watch-project.ps1 - never auto-stopped

    refs = int(state.get("refs", 1)) - 1
    if refs > 0:
        state["refs"] = refs
        json.dump(state, open(sp, "w", encoding="utf-8"))
        return

    kill_tree(int(state["pid"]))
    os.remove(sp)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # never block session end
    sys.exit(0)
