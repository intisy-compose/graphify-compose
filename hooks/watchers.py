"""What the session hooks share with the CLIs' watcher libraries, scripts/watcher-state.sh and .ps1: a
state file's name, the watch lock, whether a pid is still the watcher its state file names, and how a
session watcher is started and ended. Every function takes `windows`, so both OSes' rules are tested
on either; it defaults to the OS this runs on.
"""
import base64
import collections
import hashlib
import json
import ntpath
import os
import posixpath
import random
import re
import signal
import subprocess
import sys
import time

IS_WINDOWS = sys.platform == "win32"
STALE_LOCK_SECONDS = 60
CLOCK_ROUNDING_SECONDS = 2
END_WAIT_SECONDS = 5

ProcessRecord = collections.namedtuple("ProcessRecord", ["start_seconds", "arguments"])


def read_session_cwd(stream=None):
    """The session's folder from the hook payload Claude Code sends on stdin, or this process's.
    utf-8-sig, because a PowerShell pipe adds a byte order mark."""
    stream = stream or sys.stdin.buffer
    try:
        return json.loads(stream.read().decode("utf-8-sig")).get("cwd") or os.getcwd()
    except Exception:
        return os.getcwd()


def path_rules(windows=IS_WINDOWS):
    return ntpath if windows else posixpath


def digest_for(path, windows=IS_WINDOWS):
    """The name of PATH's state file. normcase lowercases only on Windows, as watch-project.ps1 and
    watcher-state.sh do there; on Linux the path is hashed as given."""
    rules = path_rules(windows)
    return hashlib.md5(rules.normcase(rules.abspath(path)).encode("utf-8")).hexdigest()[:12]


def venv_python(stack, windows=IS_WINDOWS):
    if windows:
        return ntpath.join(stack, "venv", "Scripts", "python.exe")
    return posixpath.join(stack, "venv", "bin", "python")


def runner_of(stack, windows=IS_WINDOWS):
    return path_rules(windows).join(stack, "scripts", "watch-runner.ps1" if windows else "watch-runner.sh")


def runner_command(stack, project, windows=IS_WINDOWS):
    """The session runner of PROJECT, without the runners' persistent flag: the hook writes and
    ref-counts the state file itself."""
    if windows:
        return ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", runner_of(stack, True), project]
    return ["bash", runner_of(stack, False), project]




def read_state(file):
    """The state in FILE, or None for a file that is not a state file. utf-8-sig, because the ps1
    writes a byte order mark."""
    try:
        with open(file, encoding="utf-8-sig") as handle:
            state = json.load(handle)
    except (OSError, ValueError):
        return None
    if not isinstance(state, dict) or not isinstance(state.get("path"), str) or not state["path"]:
        return None
    if not re.fullmatch(r"[0-9]+", str(state.get("pid", ""))) or int(state["pid"]) < 2:
        return None
    state["pid"] = int(state["pid"])
    return state


def write_state(file, state):
    """Writes FILE whole through a temporary file and a rename, so a runner reading it never sees it
    truncated or half written, which could make a persistent one take itself for superseded. A rename
    onto a file another process has open fails on Windows for a moment, so it is retried."""
    temporary = "{}.{}.tmp".format(file, os.getpid())
    with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(state, handle)
    for _ in range(250):
        try:
            os.replace(temporary, file)
            return
        except PermissionError:
            time.sleep(0.02)
    os.remove(temporary)
    raise PermissionError("could not replace " + file)


def remove_file(file):
    try:
        os.remove(file)
    except FileNotFoundError:
        pass




def owner_file(lock):
    return os.path.join(lock, "owner")


def remove_lock_folder(lock):
    remove_file(owner_file(lock))
    try:
        os.rmdir(lock)
    except OSError:
        pass


def is_stale_lock(lock, now=None):
    held = owner_file(lock) if os.path.exists(owner_file(lock)) else lock
    try:
        written = os.stat(held).st_mtime
    except OSError:
        return False
    return written < (time.time() if now is None else now) - STALE_LOCK_SECONDS


def break_stale_lock(lock):
    """Renames the lock to a name of this process's own before removing it, so of two breaking the
    same stale lock only one takes it; one that took a fresh lock instead puts it back."""
    aside = "{}.broken.{}.{}".format(lock, os.getpid(), random.randrange(1 << 30))
    try:
        os.rename(lock, aside)
    except OSError:
        return
    if is_stale_lock(aside):
        remove_lock_folder(aside)
        return
    try:
        os.rename(aside, lock)
    except OSError:
        remove_lock_folder(aside)


def claim_lock(lock):
    try:
        os.makedirs(lock, exist_ok=True)
        descriptor = os.open(owner_file(lock), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except OSError:
        return False
    with os.fdopen(descriptor, "w", newline="\n") as handle:
        handle.write("{}\n".format(os.getpid()))
    return True


def acquire_lock(lock, wait_seconds):
    deadline = time.monotonic() + wait_seconds
    while time.monotonic() < deadline:
        if claim_lock(lock):
            return True
        if is_stale_lock(lock):
            break_stale_lock(lock)
            continue
        time.sleep(0.1)
    return False


def release_lock(lock):
    try:
        with open(owner_file(lock), encoding="utf-8") as handle:
            owner = handle.read().strip()
    except OSError:
        return
    if owner == str(os.getpid()):
        remove_lock_folder(lock)




def split_windows_command_line(line):
    """The arguments as CommandLineToArgvW splits LINE: whitespace outside quotes separates, quotes
    group, and backslashes are literal unless they precede a quote, where 2n give n and 2n+1 give n
    and a literal quote."""
    arguments, argument = [], []
    quoted = started = False
    index = 0
    while index < len(line):
        character = line[index]
        if character == "\\":
            slashes = 0
            while index < len(line) and line[index] == "\\":
                slashes += 1
                index += 1
            if index < len(line) and line[index] == '"':
                argument.append("\\" * (slashes // 2))
                if slashes % 2:
                    argument.append('"')
                    index += 1
            else:
                argument.append("\\" * slashes)
            started = True
            continue
        if character == '"':
            quoted = not quoted
            started = True
        elif character.isspace() and not quoted:
            if started:
                arguments.append("".join(argument))
            argument, started = [], False
        else:
            argument.append(character)
            started = True
        index += 1
    if started:
        arguments.append("".join(argument))
    return arguments


def comparable_path(path, windows=IS_WINDOWS):
    if not windows:
        return path
    git_bash = re.fullmatch(r"/([A-Za-z])/(.*)", path)
    if git_bash:
        path = "{}:\\{}".format(git_bash.group(1), git_bash.group(2))
    return path.replace("/", "\\").lower()


def same_path(first, second, windows=IS_WINDOWS):
    return comparable_path(first, windows) == comparable_path(second, windows)


def is_runner_of(stack, project, arguments, windows=IS_WINDOWS):
    """One argument is this stack's watch-runner.sh or .ps1 and the argument after it is PROJECT."""
    rules = path_rules(windows)
    runners = [rules.join(stack, "scripts", name) for name in ("watch-runner.sh", "watch-runner.ps1")]
    for index in range(len(arguments) - 1):
        if any(same_path(arguments[index], runner, windows) for runner in runners) and \
                same_path(arguments[index + 1], project, windows):
            return True
    return False


def linux_stat_fields(pid, proc="/proc"):
    """The fields of /proc/PID/stat after the command name, counted from 0 (0 state, 1 parent, 2
    process group, 19 start time in clock ticks since boot)."""
    with open("{}/{}/stat".format(proc, pid), encoding="utf-8", errors="replace") as handle:
        return handle.read().rsplit(") ", 1)[1].split()


def linux_record(pid, proc="/proc"):
    try:
        with open("{}/{}/cmdline".format(proc, pid), "rb") as handle:
            raw = handle.read()
        fields = linux_stat_fields(pid, proc)
        with open("{}/stat".format(proc), encoding="utf-8") as handle:
            boot = next(int(line.split()[1]) for line in handle if line.startswith("btime "))
    except (OSError, IndexError, StopIteration, ValueError):
        return None
    if not raw:
        return None
    arguments = raw.split(b"\0")
    if raw.endswith(b"\0"):
        arguments.pop()
    return ProcessRecord(boot + int(fields[19]) // os.sysconf("SC_CLK_TCK"), [os.fsdecode(argument) for argument in arguments])


WINDOWS_RECORD_SCRIPT = (
    "[Console]::OutputEncoding = [Text.Encoding]::UTF8; "
    "$p = Get-CimInstance Win32_Process -Filter 'ProcessId = {pid}'; "
    "if ($p -and $p.CommandLine) {{ '{{0}}{{1}}{{2}}' -f ([DateTimeOffset]$p.CreationDate).ToUnixTimeSeconds(), [char]9, $p.CommandLine }}"
)


def powershell(script, **options):
    """Runs SCRIPT encoded, so no quote in it meets Windows' command-line quoting on the way."""
    encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
    return subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                           "-EncodedCommand", encoded], stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **options)


def windows_record(pid):
    try:
        result = powershell(WINDOWS_RECORD_SCRIPT.format(pid=int(pid)), stdout=subprocess.PIPE, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    start, separator, command_line = result.stdout.decode("utf-8", "replace").strip().partition("\t")
    if not separator or not start.isdigit():
        return None
    return ProcessRecord(int(start), split_windows_command_line(command_line))


def process_record(pid, windows=IS_WINDOWS):
    return windows_record(pid) if windows else linux_record(pid)


def is_watcher_of(state, file, stack, windows=IS_WINDOWS, record=None):
    """The state's pid is still its watcher: it runs this stack's runner for the state's path and
    started before FILE was last written, since a pid is reused once its process ends."""
    record = record or process_record(state["pid"], windows)
    if record is None:
        return False
    if not is_runner_of(stack, state["path"], record.arguments, windows):
        return False
    try:
        return record.start_seconds <= os.stat(file).st_mtime + CLOCK_ROUNDING_SECONDS
    except OSError:
        return False




def powershell_literal(value):
    return "'" + value.replace("'", "''") + "'"


def spawn_windows(command, log):
    """Start-Process, because python's own creation flags give no detached process that survives on
    this host. The pid goes through a file, because the watcher would inherit a stdout pipe and keep a
    capturing read open. Start-Process joins its arguments with spaces, so each carries its own quotes."""
    pid_file = log + ".pid"
    remove_file(pid_file)
    arguments = ",".join(powershell_literal('"{}"'.format(argument)) for argument in command[1:])
    script = (
        "$p = Start-Process {program} -ArgumentList {arguments} -WindowStyle Hidden -PassThru "
        "-RedirectStandardOutput {out} -RedirectStandardError {err}; [IO.File]::WriteAllText({pid_file}, [string]$p.Id)"
    ).format(program=command[0], arguments=arguments, out=powershell_literal(log),
             err=powershell_literal(log + ".err"), pid_file=powershell_literal(pid_file))
    powershell(script, stdout=subprocess.DEVNULL, timeout=30)
    with open(pid_file, encoding="utf-8") as handle:
        pid = int(handle.read().strip())
    remove_file(pid_file)
    return pid


def spawn_linux(command, log):
    """In a session of its own, as watch-project.sh starts a runner under setsid, so ending the
    watcher's process group ends graphify with it, and a hook's exit or timeout ends neither."""
    with open(log, "wb") as out, open(log + ".err", "wb") as err:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                   start_new_session=True, close_fds=True)
    return process.pid


def spawn_runner(command, log, windows=IS_WINDOWS):
    return spawn_windows(command, log) if windows else spawn_linux(command, log)


def is_running_linux(pid):
    """A zombie counts as ended: a runner whose parent still lives is not reaped at once."""
    try:
        return linux_stat_fields(pid)[0] != "Z"
    except (OSError, IndexError):
        return False


def linux_children(pid):
    children = []
    for entry in os.listdir("/proc"):
        if entry.isdigit():
            try:
                if linux_stat_fields(entry)[1] == str(pid):
                    children.append(int(entry))
            except (OSError, IndexError):
                pass
    return children


def signal_tree(pid, signal_number):
    """A process that leads its own group, as a runner a hook started does, is signalled with its whole
    group; any other with its direct children."""
    try:
        if os.getpgid(pid) == pid:
            os.killpg(pid, signal_number)
            return
    except OSError:
        return
    for process in linux_children(pid) + [pid]:
        try:
            os.kill(process, signal_number)
        except OSError:
            pass


def end_process_tree(pid, windows=IS_WINDOWS):
    if windows:
        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
        return
    signal_tree(pid, signal.SIGTERM)
    deadline = time.monotonic() + END_WAIT_SECONDS
    while time.monotonic() < deadline:
        if not is_running_linux(pid):
            return
        time.sleep(0.1)
    signal_tree(pid, signal.SIGKILL)
