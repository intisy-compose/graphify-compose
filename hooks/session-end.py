#!/usr/bin/env python3
"""SessionEnd hook: stop the current project's auto-watcher when its last session closes.

Decrements, under the CLIs' watch lock, the reference count session-start.py keeps. At zero the
watcher is ended with what it runs, but only while its pid is still that watcher, and the state file
removed, so watchers never accumulate. A persistent watcher pinned by `watch` is never stopped here.
Exits 0 on anything unexpected.
"""
import json
import os
import sys

import watchers

GRAPHIFY_DIR = os.environ.get("GRAPHIFY_DIR") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE_DIR = os.path.join(GRAPHIFY_DIR, ".watchers")
LOCK_WAIT_SECONDS = 8


def read_cwd():
    try:
        return json.load(sys.stdin).get("cwd") or os.getcwd()
    except Exception:
        return os.getcwd()


def leave_session(project, windows=watchers.IS_WINDOWS):
    """Uncounts this session; returns True when it ended the watcher."""
    state_file = os.path.join(STATE_DIR, watchers.digest_for(project, windows) + ".json")
    state = watchers.read_state(state_file)
    if not state or state.get("persistent"):
        return False
    refs = int(state.get("refs", 1)) - 1
    if refs > 0:
        state["refs"] = refs
        watchers.write_state(state_file, state)
        return False
    ended = watchers.is_watcher_of(state, state_file, GRAPHIFY_DIR, windows)
    if ended:
        watchers.end_process_tree(state["pid"], windows)
    watchers.remove_file(state_file)
    return ended


def main():
    project = os.path.abspath(read_cwd())
    digest = watchers.digest_for(project)
    if not os.path.exists(os.path.join(STATE_DIR, digest + ".json")):
        return
    lock = os.path.join(STATE_DIR, digest + ".lock")
    if not watchers.acquire_lock(lock, LOCK_WAIT_SECONDS):
        return
    try:
        leave_session(project)
    finally:
        watchers.release_lock(lock)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # never block session end
    sys.exit(0)
