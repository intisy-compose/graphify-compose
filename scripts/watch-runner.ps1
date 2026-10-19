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
$venvPython = Join-Path $scriptDir 'venv\Scripts\python.exe'
$graphFile = Join-Path $TargetPath 'graphify-out\graph.json'

# Generate graph.html even for large graphs (default HTML viz limit is 5000 nodes).
$env:GRAPHIFY_VIZ_NODE_LIMIT = '20000'

# Build once if this project has never been graphed, so the first query has data.
if (-not (Test-Path $graphFile)) {
    & $venvPython -m graphify update $TargetPath
}

function Test-StackIsGone {
    $ErrorActionPreference = 'Continue'
    docker info *> $null
    if ($LASTEXITCODE -ne 0) { return $false }
    $running = docker inspect -f '{{.State.Running}}' graphify-server 2>$null
    return $running -ne 'true'
}

function Remove-OwnStateFile {
    $stateDir = Join-Path $scriptDir '.watchers'
    Get-ChildItem -Path $stateDir -Filter '*.json' -ErrorAction SilentlyContinue |
        Where-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).pid -eq $PID } |
        Remove-Item -Force
}

$watcher = Start-Process -FilePath $venvPython -ArgumentList @('-m', 'graphify', 'watch', "`"$TargetPath`"") -NoNewWindow -PassThru
while (-not $watcher.HasExited) {
    if (Test-StackIsGone) {
        taskkill /PID $watcher.Id /T /F 2>$null | Out-Null
        Remove-OwnStateFile
        exit 0
    }
    Start-Sleep -Seconds 60
}
