"""Unit tests of the session hooks and hooks/watchers.py, on whichever OS runs them: both OSes' naming
and commands everywhere, and real watcher processes of the OS this runs on, started and ended as the
hooks do. Run with `python3 -m unittest discover -s tests/hooks` from the repository."""
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

REPOSITORY = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOOKS = os.path.join(REPOSITORY, "hooks")
sys.path.insert(0, HOOKS)
import watchers  # noqa: E402

WINDOWS = watchers.IS_WINDOWS


def load_hook(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(HOOKS, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def md5_prefix(text):
    return hashlib.md5(text.encode("utf-8")).hexdigest()[:12]


def wait_until(check, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if check():
            return True
        time.sleep(0.1)
    return check()


def is_running(pid):
    if WINDOWS:
        result = subprocess.run(["tasklist", "/FI", "PID eq {}".format(pid), "/FO", "CSV", "/NH"],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return '"{}"'.format(pid) in result.stdout.decode("ascii", "replace")
    return watchers.is_running_linux(pid)


class ScratchStack(unittest.TestCase):
    """A scratch stack folder with a project, and the hooks pointed at it."""

    def setUp(self):
        self.stack = tempfile.mkdtemp(prefix="graphify-hooks-")
        self.addCleanup(shutil.rmtree, self.stack, True)
        self.project = os.path.join(self.stack, "Projects", "My Project")
        os.makedirs(self.project)
        self.state_dir = os.path.join(self.stack, ".watchers")
        os.makedirs(self.state_dir)
        self.start_hook = load_hook("session-start")
        self.end_hook = load_hook("session-end")
        for hook in (self.start_hook, self.end_hook):
            hook.GRAPHIFY_DIR = self.stack
            hook.STATE_DIR = self.state_dir

    def state_file(self):
        return os.path.join(self.state_dir, watchers.digest_for(self.project) + ".json")

    def write_raw_state(self, state):
        with open(self.state_file(), "w", encoding="utf-8") as handle:
            json.dump(state, handle)

    def read_raw_state(self):
        with open(self.state_file(), encoding="utf-8") as handle:
            return json.load(handle)


class Naming(unittest.TestCase):
    def test_windows_lowercases_the_path(self):
        path = "F:\\Documents\\GitHub\\Mixed-Case Folder"
        self.assertEqual(watchers.digest_for(path, windows=True), md5_prefix(path.lower()))

    def test_windows_takes_forward_slashes_as_backslashes(self):
        self.assertEqual(watchers.digest_for("F:/Documents/App", windows=True),
                         watchers.digest_for("f:\\documents\\app", windows=True))

    def test_linux_hashes_the_path_as_given(self):
        path = "/srv/projects/Mixed-Case Folder"
        self.assertEqual(watchers.digest_for(path, windows=False), md5_prefix(path))
        self.assertNotEqual(watchers.digest_for(path, windows=False),
                            watchers.digest_for(path.lower(), windows=False))

    @unittest.skipIf(WINDOWS or not shutil.which("bash"), "the Linux sh names it on Linux")
    def test_linux_agrees_with_the_sh(self):
        path = "/srv/projects/Mixed-Case Folder"
        named = subprocess.run(["bash", "-c", '. "$1" && watcher_digest "$2"', "_",
                                os.path.join(REPOSITORY, "scripts", "watcher-state.sh"), path],
                               stdout=subprocess.PIPE, check=True, env=dict(os.environ, MSYSTEM=""))
        self.assertEqual(named.stdout.decode().strip(), watchers.digest_for(path, windows=False))

    @unittest.skipUnless(WINDOWS, "the ps1 names it on Windows")
    def test_windows_agrees_with_the_ps1(self):
        path = "F:\\Documents\\GitHub\\Mixed-Case Folder"
        script = ". '{}'; Get-WatcherDigest '{}'".format(os.path.join(REPOSITORY, "scripts", "watcher-state.ps1"), path)
        named = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
                               stdout=subprocess.PIPE, check=True)
        self.assertEqual(named.stdout.decode().strip(), watchers.digest_for(path, windows=True))


class RunnerAndVenv(unittest.TestCase):
    def test_windows_runs_the_ps1_runner_without_persistent(self):
        self.assertEqual(watchers.runner_command("F:\\graphify", "F:\\p\\app", windows=True),
                         ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                          "F:\\graphify\\scripts\\watch-runner.ps1", "F:\\p\\app"])

    def test_linux_runs_the_sh_runner_without_persistent(self):
        self.assertEqual(watchers.runner_command("/srv/graphify", "/srv/p/app", windows=False),
                         ["bash", "/srv/graphify/scripts/watch-runner.sh", "/srv/p/app"])

    def test_the_venv_of_each_os(self):
        self.assertEqual(watchers.venv_python("F:\\graphify", windows=True), "F:\\graphify\\venv\\Scripts\\python.exe")
        self.assertEqual(watchers.venv_python("/srv/graphify", windows=False), "/srv/graphify/venv/bin/python")

    def test_the_spawn_of_each_os(self):
        with mock.patch.object(watchers, "spawn_windows", return_value=1) as on_windows, \
                mock.patch.object(watchers, "spawn_linux", return_value=2) as on_linux:
            self.assertEqual(watchers.spawn_runner(["x"], "log", windows=True), 1)
            self.assertEqual(watchers.spawn_runner(["x"], "log", windows=False), 2)
        on_windows.assert_called_once_with(["x"], "log")
        on_linux.assert_called_once_with(["x"], "log")


class Identity(unittest.TestCase):
    def setUp(self):
        handle, self.file = tempfile.mkstemp()
        os.close(handle)
        self.addCleanup(os.remove, self.file)
        self.now = int(os.stat(self.file).st_mtime)

    def test_linux_runner_of_the_project(self):
        state = {"pid": 5, "path": "/w/app"}
        record = watchers.ProcessRecord(self.now, ["bash", "/s/scripts/watch-runner.sh", "/w/app"])
        self.assertTrue(watchers.is_watcher_of(state, self.file, "/s", windows=False, record=record))

    def test_arguments_are_compared_whole(self):
        for path in ("/w/app2", "/w/app/sub", "/w"):
            record = watchers.ProcessRecord(self.now, ["bash", "/s/scripts/watch-runner.sh", path])
            self.assertFalse(watchers.is_watcher_of({"pid": 5, "path": "/w/app"}, self.file, "/s",
                                                    windows=False, record=record), path)

    def test_linux_is_case_sensitive_and_windows_is_not(self):
        record = watchers.ProcessRecord(self.now, ["bash", "/s/scripts/watch-runner.sh", "/w/App"])
        self.assertFalse(watchers.is_watcher_of({"pid": 5, "path": "/w/app"}, self.file, "/s", windows=False, record=record))
        record = watchers.ProcessRecord(self.now, ["powershell", "-File", "F:/S/scripts/watch-runner.ps1", "f:\\w\\App"])
        self.assertTrue(watchers.is_watcher_of({"pid": 5, "path": "F:\\w\\app"}, self.file, "F:\\s", windows=True, record=record))

    def test_another_stacks_runner_is_not_this_ones(self):
        record = watchers.ProcessRecord(self.now, ["bash", "/other/scripts/watch-runner.sh", "/w/app"])
        self.assertFalse(watchers.is_watcher_of({"pid": 5, "path": "/w/app"}, self.file, "/s", windows=False, record=record))

    def test_a_process_started_after_the_state_was_written_is_not_its_watcher(self):
        record = watchers.ProcessRecord(self.now + 3600, ["bash", "/s/scripts/watch-runner.sh", "/w/app"])
        self.assertFalse(watchers.is_watcher_of({"pid": 5, "path": "/w/app"}, self.file, "/s", windows=False, record=record))

    def test_no_process(self):
        with mock.patch.object(watchers, "process_record", return_value=None):
            self.assertFalse(watchers.is_watcher_of({"pid": 5, "path": "/w/app"}, self.file, "/s", windows=False))

    def test_the_windows_tokenizer(self):
        cases = [
            ("bash  run.sh\tapp", ["bash", "run.sh", "app"]),
            ('"C:\\Program Files\\Git\\bin\\bash.exe" "C:\\My Projects\\app"',
             ["C:\\Program Files\\Git\\bin\\bash.exe", "C:\\My Projects\\app"]),
            ('C:\\My" "Projects\\app', ["C:\\My Projects\\app"]),
            ('say \\"hi\\"', ["say", '"hi"']),
            ('a\\\\"b c"', ["a\\b c"]),
            ('a\\\\\\"b', ['a\\"b']),
            ("C:\\\\share\\\\x y", ["C:\\\\share\\\\x", "y"]),
            ("C:\\app\\ next", ["C:\\app\\", "next"]),
            ('"C:\\My Projects\\\\" next', ["C:\\My Projects\\", "next"]),
            ('a "" b', ["a", "", "b"]),
            ('""', [""]),
            ("   ", []),
        ]
        for line, arguments in cases:
            self.assertEqual(watchers.split_windows_command_line(line), arguments, line)


class AtomicState(ScratchStack):
    def test_a_rewrite_is_never_seen_missing_or_half_written(self):
        self.write_raw_state({"path": self.project, "pid": 4242, "refs": 1, "padding": "x" * 20000})
        seen_broken = []
        stop = threading.Event()

        def read_continuously():
            while not stop.is_set():
                try:
                    with open(self.state_file(), encoding="utf-8") as handle:
                        text = handle.read()
                except FileNotFoundError:
                    seen_broken.append("missing")
                    continue
                except PermissionError:
                    continue  # Windows refuses an open while a rename replaces the file; the runners read that as no news
                try:
                    json.loads(text)
                except ValueError:
                    seen_broken.append(text[:40])

        reader = threading.Thread(target=read_continuously)
        reader.start()
        try:
            for refs in range(2, 202):
                watchers.write_state(self.state_file(), {"path": self.project, "pid": 4242, "refs": refs,
                                                         "padding": "x" * 20000})
        finally:
            stop.set()
            reader.join()
        self.assertEqual(seen_broken, [])
        self.assertEqual(self.read_raw_state()["refs"], 201)
        self.assertEqual([name for name in os.listdir(self.state_dir) if name.endswith(".tmp")], [])

    def test_the_rewrite_is_a_rename_of_a_whole_file(self):
        self.write_raw_state({"path": self.project, "pid": 4242, "refs": 1})
        renames = []
        real_replace = os.replace

        def replace(source, target):
            with open(source, encoding="utf-8") as handle:
                renames.append(json.load(handle)["refs"])
            with open(target, encoding="utf-8") as handle:
                renames.append(json.load(handle)["refs"])
            real_replace(source, target)

        with mock.patch.object(watchers.os, "replace", side_effect=replace):
            watchers.write_state(self.state_file(), {"path": self.project, "pid": 4242, "refs": 2})
        self.assertEqual(renames, [2, 1])

    def test_a_ps1_state_with_a_byte_order_mark_is_read(self):
        with open(self.state_file(), "w", encoding="utf-8-sig") as handle:
            handle.write('{\r\n    "path":  "x",\r\n    "pid":  77,\r\n    "persistent":  true\r\n}\r\n')
        self.assertEqual(watchers.read_state(self.state_file())["pid"], 77)

    def test_a_file_that_is_not_a_state_file(self):
        for text in ("", "{", '{"path": "x", "pid": 1}', '{"path": "", "pid": 9}', '{"pid": 9}', "[]"):
            with open(self.state_file(), "w", encoding="utf-8") as handle:
                handle.write(text)
            self.assertIsNone(watchers.read_state(self.state_file()), text)


class RefCount(ScratchStack):
    def test_a_second_session_counts_on_the_live_watcher(self):
        self.write_raw_state({"path": self.project, "pid": 4242, "refs": 1})
        with mock.patch.object(watchers, "is_watcher_of", return_value=True), \
                mock.patch.object(watchers, "spawn_runner") as spawn:
            self.assertEqual(self.start_hook.join_session(self.project), 4242)
        spawn.assert_not_called()
        self.assertEqual(self.read_raw_state()["refs"], 2)

    def test_a_persistent_watcher_is_reused_and_left_as_it_is(self):
        self.write_raw_state({"path": self.project, "pid": 4242, "refs": 1, "persistent": True})
        before = os.stat(self.state_file()).st_mtime_ns
        with mock.patch.object(watchers, "is_watcher_of", return_value=True), \
                mock.patch.object(watchers, "write_state") as write:
            self.start_hook.join_session(self.project)
        write.assert_not_called()
        self.assertEqual(os.stat(self.state_file()).st_mtime_ns, before)

    def test_a_dead_watcher_is_replaced(self):
        self.write_raw_state({"path": self.project, "pid": 4242, "refs": 3})
        os.makedirs(os.path.dirname(watchers.venv_python(self.stack)))
        open(watchers.venv_python(self.stack), "w").close()
        with mock.patch.object(watchers, "is_watcher_of", return_value=False), \
                mock.patch.object(watchers, "spawn_runner", return_value=5151) as spawn:
            self.start_hook.join_session(self.project)
        spawn.assert_called_once()
        self.assertEqual(spawn.call_args[0][0], watchers.runner_command(self.stack, self.project))
        self.assertEqual(self.read_raw_state(), {"path": self.project, "pid": 5151, "refs": 1})

    def test_no_venv_starts_nothing(self):
        with mock.patch.object(watchers, "spawn_runner") as spawn:
            self.assertIsNone(self.start_hook.join_session(self.project))
        spawn.assert_not_called()
        self.assertFalse(os.path.exists(self.state_file()))

    def test_a_session_end_with_others_left_only_counts_down(self):
        self.write_raw_state({"path": self.project, "pid": 4242, "refs": 2})
        with mock.patch.object(watchers, "end_process_tree") as end:
            self.assertFalse(self.end_hook.leave_session(self.project))
        end.assert_not_called()
        self.assertEqual(self.read_raw_state()["refs"], 1)

    def test_session_end_never_stops_a_persistent_watcher(self):
        self.write_raw_state({"path": self.project, "pid": 4242, "refs": 1, "persistent": True})
        with mock.patch.object(watchers, "end_process_tree") as end:
            self.end_hook.leave_session(self.project)
        end.assert_not_called()
        self.assertTrue(os.path.exists(self.state_file()))

    def test_at_zero_a_pid_that_is_not_the_watcher_is_left_alone(self):
        self.write_raw_state({"path": self.project, "pid": os.getpid(), "refs": 1})
        with mock.patch.object(watchers, "end_process_tree") as end:
            self.assertFalse(self.end_hook.leave_session(self.project))
        end.assert_not_called()
        self.assertFalse(os.path.exists(self.state_file()))


class StopAtZero(ScratchStack):
    """A real session watcher of this OS, started and ended as the hooks do, with a stand-in runner
    that runs a child as graphify would."""

    def install_stand_in_runner(self):
        scripts = os.path.join(self.stack, "scripts")
        os.makedirs(scripts)
        if WINDOWS:
            body = ("$child = Start-Process powershell -ArgumentList '-NoProfile','-Command','Start-Sleep 300' "
                    "-PassThru -WindowStyle Hidden\n[IO.File]::WriteAllText($args[0] + '.child', [string]$child.Id)\n"
                    "while ($true) { Start-Sleep 1 }\n")
            name = "watch-runner.ps1"
        else:
            body = 'sleep 300 &\nprintf %s "$!" >"$1.child"\nwhile :; do sleep 1; done\n'
            name = "watch-runner.sh"
        with open(os.path.join(scripts, name), "w", encoding="utf-8", newline="\n") as handle:
            handle.write(body)

    def child_pid(self):
        with open(self.project + ".child", encoding="utf-8") as handle:
            return int(handle.read().strip())

    def test_the_last_session_end_stops_the_watcher_and_its_child(self):
        self.install_stand_in_runner()
        log = os.path.join(self.state_dir, "runner.log")
        pid = watchers.spawn_runner(watchers.runner_command(self.stack, self.project), log)
        self.addCleanup(watchers.end_process_tree, pid)
        watchers.write_state(self.state_file(), {"path": self.project, "pid": pid, "refs": 2})
        self.assertTrue(wait_until(lambda: os.path.exists(self.project + ".child")), "the runner never started its child")
        child = self.child_pid()

        self.assertTrue(watchers.is_watcher_of(watchers.read_state(self.state_file()), self.state_file(), self.stack))
        self.assertFalse(self.end_hook.leave_session(self.project))
        self.assertTrue(is_running(pid))

        self.assertTrue(self.end_hook.leave_session(self.project))
        self.assertTrue(wait_until(lambda: not is_running(pid)), "the runner still runs")
        self.assertTrue(wait_until(lambda: not is_running(child)), "its child still runs")
        self.assertFalse(os.path.exists(self.state_file()))

    def test_the_lock_is_the_clis_owner_file(self):
        lock = os.path.join(self.state_dir, "x.lock")
        self.assertTrue(watchers.acquire_lock(lock, 1))
        with open(os.path.join(lock, "owner"), encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "{}\n".format(os.getpid()))
        self.assertFalse(watchers.claim_lock(lock))
        self.assertFalse(watchers.acquire_lock(lock, 0.3))
        watchers.release_lock(lock)
        self.assertFalse(os.path.exists(lock))

    def test_a_stale_lock_is_broken_and_anothers_fresh_one_kept(self):
        lock = os.path.join(self.state_dir, "x.lock")
        os.makedirs(lock)
        with open(os.path.join(lock, "owner"), "w") as handle:
            handle.write("4242\n")
        watchers.release_lock(lock)
        self.assertTrue(os.path.exists(os.path.join(lock, "owner")), "released another's lock")
        self.assertFalse(watchers.acquire_lock(lock, 0.3))
        old = time.time() - 120
        os.utime(os.path.join(lock, "owner"), (old, old))
        self.assertTrue(watchers.acquire_lock(lock, 1))
        watchers.release_lock(lock)
        self.assertEqual(os.listdir(self.state_dir), [])


if __name__ == "__main__":
    unittest.main()
