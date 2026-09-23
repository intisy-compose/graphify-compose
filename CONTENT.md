- **graphify** - MCP server on `:8770`; serves any project via `project_path` and
  hot-reloads `graph.json` when it changes.
- **graphify-web** - static server on `:8771` for the interactive `graph.html`
  explorers.

## Quick start

Requires [Docker](https://docs.docker.com/get-docker/) and a local clone of the
graphify server repo (it holds the `Dockerfile` the image is built from).

```powershell
git clone https://github.com/intisy-compose/graphify-compose
cd graphify-compose

# Provide the build context and configuration
git clone https://github.com/Graphify-Labs/graphify repo
cp .env.example .env    # then edit: set GRAPHIFY_API_KEY and PROJECTS_ROOT

.\docker-compose.ps1 up   # the one CLI; `.\docker-compose.ps1 help` lists every command
```

- MCP endpoint: `http://localhost:8770/mcp`
- Demo explorer: `http://localhost:8771/demo/graph.html`
- Any project: `http://localhost:8771/projects/<lang>/<name>/graphify-out/graph.html`

## Configuration

Copy `.env.example` to `.env` (gitignored) and set:

| key | meaning |
| --- | --- |
| `GRAPHIFY_API_KEY` | Auth key the MCP server requires; use the same value in your MCP client. **Required.** |
| `PROJECTS_ROOT` | Absolute path to the folder of projects, mounted read-only at `/projects`. |

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
