# graphify-compose

A Docker stack that runs a [graphify](https://github.com/Graphify-Labs/graphify)
knowledge-graph MCP server plus a static web explorer over every project under a
chosen root, so any project with a `graphify-out/graph.json` is queryable and
browsable without per-project configuration.

- **graphify** - MCP server on `:8770`; serves any project via `project_path` and
  hot-reloads `graph.json` when it changes.
- **graphify-web** - static server on `:8771` for the interactive `graph.html`
  explorers.

## Quick start

Requires [Docker](https://docs.docker.com/get-docker/) and a local clone of the
graphify server repo (it holds the `Dockerfile` the image is built from).

```bash
git clone https://github.com/intisy-compose/graphify-compose
cd graphify-compose

# Provide the build context and configuration
git clone https://github.com/Graphify-Labs/graphify repo
cp .env.example .env    # then edit: set GRAPHIFY_API_KEY and PROJECTS_ROOT

docker compose up -d --build
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
share one watcher. They resolve their own location automatically; set
`GRAPHIFY_PROJECTS_ROOT` if your projects live outside the default root. The
`watch-*.ps1` scripts drive the watcher directly on Windows.

## License

MIT - see [LICENSE](LICENSE).
