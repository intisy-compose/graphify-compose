# graphify-compose

A Docker stack that runs a [graphify](https://github.com/Graphify-Labs/graphify) knowledge-graph MCP server plus a static web explorer over every project under a chosen root, so any project with a `graphify-out/graph.json` is queryable and browsable without per-project configuration.

- **graphify** - MCP server on `127.0.0.1:8770`; serves any project via `project_path` and
  hot-reloads `graph.json` when it changes.
- **graphify-web** - static server for the interactive `graph.html` explorers. It serves only the
  `graphify-out` folders, never the project sources around them.
- **tailscale** and **gateway** - Caddy puts the explorers on the tailnet name over HTTPS and on
  `127.0.0.1:8771`; nothing listens on the LAN.

## Quick start

Requires [Docker](https://docs.docker.com/get-docker/) with the compose plugin and one of the two
CLIs: `docker-compose.ps1` on Windows (PowerShell 5.1, built in), or `docker-compose.sh` on Linux
(bash 4.3 or newer, `curl` and `python3`; the watchers read `/proc`, so BusyBox hosts work too). `docker-compose.sh` also runs from Git Bash on
Windows, where `up` needs a `python3` on the PATH to read the tailnet name; the watchers need none.

```powershell
git clone https://github.com/intisy-compose/graphify-compose
cd graphify-compose

cp .env.example .env    # then edit: set GRAPHIFY_API_KEY and PROJECTS_ROOT

.\docker-compose.ps1 up   # `.\docker-compose.ps1 help` lists every command
```

On Linux the last step is `./docker-compose.sh up` (`./docker-compose.sh help` lists every
command). Both CLIs have the same commands and messages and work on the same `.env` and
`.watchers/`, so a stack or a watcher started by one is stopped by the other. The sh spells options
in long form: `-Force` is `--force`, `-All` is `--all`.

- MCP endpoint: `http://localhost:8770/mcp` (this PC only)
- Demo explorer: `http://localhost:8771/demo/graph.html`, or `https://<GRAPHIFY_HOST>/demo/graph.html`
  from any device on the tailnet
- Any project: `/projects/<lang>/<name>/graphify-out/graph.html` under either address

## Configuration

Copy `.env.example` to `.env` (gitignored) and set:

| key | meaning |
| --- | --- |
| `GRAPHIFY_API_KEY` | Auth key the MCP server requires; use the same value in your MCP client. **Required.** |
| `PROJECTS_ROOT` | Absolute path to the folder of projects, mounted read-only at `/projects`. |
| `TS_AUTHKEY` | Tailscale auth key for the explorer node's first join; without it the explorers are on localhost only. |
| `GRAPHIFY_HOST` | The node's ts.net name, written by `up` once it has joined. |

## Auto-graph on session start (optional)

`hooks/session-start.py` and `hooks/session-end.py` are Claude Code session hooks
that graph and watch whichever project you open, ref-counted so multiple sessions
share one watcher. They resolve their own location automatically and only act on projects under
`PROJECTS_ROOT` from `.env` (override with `GRAPHIFY_PROJECTS_ROOT`). They run on Windows and on
Linux, starting `watch-runner.ps1` or `watch-runner.sh` by the OS they run on, and start nothing
while the host venv is missing. Register them in `~/.claude/settings.json` with this OS's venv
python (they use only the standard library, so any `python3` runs them):

```json
"hooks": {
  "SessionStart": [{ "hooks": [{ "type": "command", "timeout": 30,
    "command": "\"<stack>/venv/bin/python\" \"<stack>/hooks/session-start.py\"" }] }],
  "SessionEnd": [{ "hooks": [{ "type": "command", "timeout": 15,
    "command": "\"<stack>/venv/bin/python\" \"<stack>/hooks/session-end.py\"" }] }]
}
```

On Windows the python is `<stack>/venv/Scripts/python.exe`. A session watcher's state file is the
hooks' own (no `persistent`, a `refs` count); they change it only under the watch lock below, write it
whole through a rename, and end its watcher at the last session end only while its pid passes the same
check the CLIs make. A session started where `watch` pinned a persistent watcher uses that one and
never stops it. Drive the watchers through the same CLI:

```powershell
.\docker-compose.ps1 watch <path>        # pin a persistent watcher
.\docker-compose.ps1 watch-list          # list watchers and whether they are alive
.\docker-compose.ps1 watch-stop <path>   # or -All
.\docker-compose.ps1 regraph <path>      # rebuild the default graph once, [-Force]
.\docker-compose.ps1 healthcheck         # restart the stack if the port proxy dropped
```

A watcher's state is `.watchers/<digest>.json`, the digest being the first 12 hex digits of the MD5
of the project's absolute path: lowercased on Windows, as given on Linux, the way the hooks'
`os.path.normcase` does it. `watch` on a project that already has a live watcher keeps that one, and
two `watch` of one project at once, from either CLI, start one watcher: the second waits for the first.
The lock is `.watchers/<digest>.lock/owner`, created exclusively and holding the pid of the `watch`
that holds it; creating the folder decides nothing, since uutils `mkdir` (Ubuntu 26.04's) and
PowerShell's `New-Item` both succeed for a folder another process created a moment before. A lock left
by a `watch` that was killed is broken once its owner file (or a folder with none) is a minute old,
renamed aside before it is removed so that only one waiting `watch` takes it. A persistent watcher ends itself once its state file is gone
or names another runner; a file that names no valid pid, as one being rewritten does, ends nothing.
`down` stops every watcher before the stack, and a watcher ends itself, removing its state file, once
two checks a minute apart find `graphify-server` missing or stopped (one miss is a `restart` or a
`rebuild`; not while Docker itself is down), so none outlives the stack. A `down` that runs while a
`watch` is starting can miss the new runner, whose state file appears a few milliseconds (sh) to about a
second (ps1) after `watch` launches it; that runner ends itself by the same two checks, within about
two minutes.

A pid in a state file is trusted only while its process runs this stack's watcher runner with that
project as its argument and started before the file was written; otherwise the process is left alone
and the stale file removed, because pids are reused. Arguments are compared whole (case-insensitively
on Windows), so a watcher of `app` is never taken for one of `app2` or of a folder inside `app`. A
graphify whose runner was killed outright is found by its arguments (this stack's venv python,
`-m graphify watch` and the project) and stopped with it, and a state file that cannot be read is skipped with a warning without keeping
`down` from stopping the stack. On Linux a watcher runs in its own process group (`setsid`) and
`watch-stop` ends the group; on Windows it ends the process tree.

`healthcheck` exists for Docker Desktop, whose port proxy can stop forwarding while the container
stays up; on a Docker Engine host the endpoint answers and it does nothing. Nothing runs it on a
schedule, because a scheduled task would outlive the stack.

## The host venv

The watchers and `regraph` run graphify on the host, from `venv/` (gitignored): `venv\Scripts` on
Windows, `venv/bin` on Linux. A venv runs only on the OS that made it, so a Linux host creates its own,
at the graphify commit pinned in `docker-compose.yml` and with the image's locked packages:

```sh
python3 -m venv venv
commit=$(grep -oE 'graphify\.git#[0-9a-f]{40}' docker-compose.yml | cut -d'#' -f2)
venv/bin/pip install --no-deps -r image/requirements.lock
venv/bin/pip install --no-deps "graphifyy @ https://github.com/Graphify-Labs/graphify/archive/$commit.tar.gz"
```

Debian and Ubuntu ship `venv` separately, as the `python3-venv` package. Run the same steps again
after a `relock` to a new commit.

## Reproducible image

The image is built from `image/Dockerfile`: graphify's source at the commit pinned in
`docker-compose.yml`, the packages in `image/requirements.lock` installed exactly (no
re-resolution) and a digest-pinned Python base. Rebuilding therefore reproduces the image that last
worked instead of picking up whatever PyPI serves that day.

- `up` and `restart` never rebuild; `up` only builds when no image exists yet.
- `rebuild` builds a candidate, starts it on a spare port and switches only if its MCP endpoint
  answers. Otherwise the previous image is restored and the running stack is left alone.
- To upgrade graphify, run `relock <commit>` with the new upstream commit sha (or plain `relock` to
  re-resolve the current one), then `rebuild`. Move the host venv to the same graphify commit (see
  above), so the graphs it writes and the server that reads them stay in step.

## License

[![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
