# graphify-compose

A Docker stack that runs a [graphify](https://github.com/Graphify-Labs/graphify) knowledge-graph MCP server plus a static web explorer over every project under a chosen root, so any project with a `graphify-out/graph.json` is queryable and browsable without per-project configuration.

- **graphify** - MCP server on `127.0.0.1:8770`; serves any project via `project_path` and
  hot-reloads `graph.json` when it changes.
- **graphify-web** - static server for the interactive `graph.html` explorers. It serves only the
  `graphify-out` folders, never the project sources around them.
- **tailscale** and **gateway** - Caddy puts the explorers on the tailnet name over HTTPS and on
  `127.0.0.1:8771`; nothing listens on the LAN.

## Quick start

Requires [Docker](https://docs.docker.com/get-docker/).

```powershell
git clone https://github.com/intisy-compose/graphify-compose
cd graphify-compose

cp .env.example .env    # then edit: set GRAPHIFY_API_KEY and PROJECTS_ROOT

.\docker-compose.ps1 up   # the one CLI; `.\docker-compose.ps1 help` lists every command
```

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
`PROJECTS_ROOT` from `.env` (override with `GRAPHIFY_PROJECTS_ROOT`). Drive the watchers by hand
through the same CLI:

```powershell
.\docker-compose.ps1 watch <path>        # pin a persistent watcher
.\docker-compose.ps1 watch-list          # list watchers and whether they are alive
.\docker-compose.ps1 watch-stop <path>   # or -All
.\docker-compose.ps1 regraph <path>      # rebuild the default graph once, [-Force]
.\docker-compose.ps1 healthcheck         # restart the stack if the port proxy dropped
```

## Reproducible image

The image is built from `image/Dockerfile`: graphify's source at the commit pinned in
`docker-compose.yml`, the packages in `image/requirements.lock` installed exactly (no
re-resolution) and a digest-pinned Python base. Rebuilding therefore reproduces the image that last
worked instead of picking up whatever PyPI serves that day.

- `up` and `restart` never rebuild; `up` only builds when no image exists yet.
- `rebuild` builds a candidate, starts it on a spare port and switches only if its MCP endpoint
  answers. Otherwise the previous image is restored and the running stack is left alone.
- To upgrade graphify, run `relock <commit>` with the new upstream commit sha (or plain `relock` to
  re-resolve the current one), then `rebuild`. Move the host venv the watchers use to the same
  graphify version, so the graphs it writes and the server that reads them stay in step.

## License

[![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
