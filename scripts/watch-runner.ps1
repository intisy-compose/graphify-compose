<#
.SYNOPSIS
  Long-running process: build a project's graph if missing, then watch it for changes.

.DESCRIPTION
  Launched detached by the SessionStart hook (and by `docker-compose.ps1 watch`). Ensures the
  target has a graph, then runs `graphify watch`, which rebuilds graph.json + graph.html
  in-place on every code change. The MCP server hot-reloads the file on its next query,
  so no container restart is needed. Meant to run in the background; not called directly.
  It ends itself, and removes its state file, once two checks in a row find graphify-server missing
  or stopped (one miss is a restart or a rebuild), but not while Docker itself is down.

.PARAMETER TargetPath
  Absolute path to the project folder to watch.

.PARAMETER Persistent
  Write this watcher's persistent state file, as `docker-compose.ps1 watch` asks; the hooks write their
  own. A persistent runner also ends itself once its state file names another runner.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$TargetPath,
    [switch]$Persistent
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'watcher-state.ps1')
$scriptDir = Split-Path $PSScriptRoot
$stateFile = Join-Path (Join-Path $scriptDir '.watchers') "$(Get-WatcherDigest $TargetPath).json"
if ($Persistent) {
    New-Item -ItemType Directory -Force -Path (Split-Path $stateFile) | Out-Null
    Write-WatcherState $stateFile $TargetPath $PID
}
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
        Where-Object { try { (Get-Content $_.FullName -Raw | ConvertFrom-Json).pid -eq $PID } catch { $false } } |
        Remove-Item -Force
}

$watcher = Start-Process -FilePath $venvPython -ArgumentList @('-m', 'graphify', 'watch', "`"$TargetPath`"") -NoNewWindow -PassThru
<#
.NOTES
    A state file that is there but names no valid pid is taken as being rewritten in place, as a hook
    may, and ends nothing; only a missing file or another valid pid does.
#>
function Test-IsSuperseded {
    if (-not $Persistent) { return $false }
    if (-not (Test-Path $stateFile)) { return $true }
    $state = Read-WatcherState $stateFile
    return [bool]$state -and [int64]$state.pid -ne $PID
}

$misses = 0
while (-not $watcher.HasExited) {
    if (Test-IsSuperseded) { taskkill /PID $watcher.Id /T /F 2>$null | Out-Null; exit 0 }
    if (Test-StackIsGone) { $misses++ } else { $misses = 0 }
    if ($misses -ge 2) {
        taskkill /PID $watcher.Id /T /F 2>$null | Out-Null
        Remove-OwnStateFile
        exit 0
    }
    Start-Sleep -Seconds 60
}
Remove-OwnStateFile
