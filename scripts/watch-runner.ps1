<#
.SYNOPSIS
  Long-running process: build a project's graph if missing, then watch it for changes.

.DESCRIPTION
  Launched detached by the SessionStart hook (and by `docker-compose.ps1 watch`). Ensures the
  target has a graph, then runs `graphify watch`, which rebuilds graph.json + graph.html
  in-place on every code change. The MCP server hot-reloads the file on its next query,
  so no container restart is needed. Meant to run in the background; not called directly.

.PARAMETER TargetPath
  Absolute path to the project folder to watch.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$TargetPath
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path $PSScriptRoot
$graphifyExe = Join-Path $scriptDir 'venv\Scripts\graphify.exe'
$graphFile = Join-Path $TargetPath 'graphify-out\graph.json'

# Generate graph.html even for large graphs (default HTML viz limit is 5000 nodes).
$env:GRAPHIFY_VIZ_NODE_LIMIT = '20000'

# Build once if this project has never been graphed, so the first query has data.
if (-not (Test-Path $graphFile)) {
    & $graphifyExe update $TargetPath
}

# Blocks here, rebuilding on file changes until the process is killed (session end).
& $graphifyExe watch $TargetPath
