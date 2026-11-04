- **graphify** - MCP server on `127.0.0.1:8770`; serves any project via `project_path` and
  hot-reloads `graph.json` when it changes.
- **graphify-web** - static server for the interactive `graph.html` explorers. It serves only the
  `graphify-out` folders, never the project sources around them.
- **tailscale** and **gateway** - Caddy puts the explorers on the tailnet name over HTTPS and on
  `127.0.0.1:8771`; nothing listens on the LAN.

## Quick start

Requires [Docker](https://docs.docker.com/get-docker/) with the compose plugin and one of the two
CLIs: `docker-compose.ps1` on Windows (PowerShell 5.1, built in), or `docker-compose.sh` on Linux
(bash 4.3 or newer, `curl` and `python3`).

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
`PROJECTS_ROOT` from `.env` (override with `GRAPHIFY_PROJECTS_ROOT`). The hooks run on Windows
only for now; on Linux, pin watchers by hand. Drive the watchers through the same CLI:

```powershell
.\docker-compose.ps1 watch <path>        # pin a persistent watcher
.\docker-compose.ps1 watch-list          # list watchers and whether they are alive
.\docker-compose.ps1 watch-stop <path>   # or -All
.\docker-compose.ps1 regraph <path>      # rebuild the default graph once, [-Force]
.\docker-compose.ps1 healthcheck         # restart the stack if the port proxy dropped
```

A watcher's state is `.watchers/<digest>.json`, the digest being the first 12 hex digits of the MD5
of the project's absolute path: lowercased on Windows, as given on Linux, the way the hooks'
`os.path.normcase` does it. `down` stops every watcher before the stack, and a watcher ends itself,
removing its state file, within a minute of finding `graphify-server` missing or stopped (not while
Docker itself is down), so none outlives the stack. On Linux a watcher runs in its own process group
(`setsid`) and `watch-stop` ends the group; on Windows it ends the process tree.

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
