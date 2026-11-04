<#
.SYNOPSIS
  Pin a persistent auto-watcher on a project (survives across sessions/reboots).

.DESCRIPTION
  Like the per-session watcher the SessionStart hook starts, but flagged persistent so session end never
  stops it. Use for a project you always want kept current. Stop it with `docker-compose.ps1 watch-stop`.
  Building + watching happens in a detached background process. A project that already has a live
  watcher keeps it.

.PARAMETER TargetPath
  Absolute path to the project folder to keep watched.

.EXAMPLE
  .\docker-compose.ps1 watch C:\projects\my-project
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$TargetPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'watcher-state.ps1')
$scriptDir = Split-Path $PSScriptRoot
$stateDir = Join-Path $scriptDir '.watchers'
$runner = Join-Path $PSScriptRoot 'watch-runner.ps1'
$venvPython = Join-Path $scriptDir 'venv\Scripts\python.exe'

if (-not (Test-Path $TargetPath)) { throw "Project folder not found: $TargetPath" }
if (-not (Test-Path $venvPython)) { throw "graphify venv not found at $venvPython (is the venv intact?)" }
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

$resolved = (Resolve-Path $TargetPath).Path
$digest = Get-WatcherDigest $resolved
$stateFile = Join-Path $stateDir "$digest.json"
$lock = Join-Path $stateDir "$digest.lock"


# Wait-RunnerState PROCESS: true once the runner has recorded itself and is still that watcher, within 10 s.
function Wait-RunnerState($Process) {
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        $state = if (Test-Path $stateFile) { Read-WatcherState $stateFile }
        if ($state -and [int64]$state.pid -eq $Process.Id) { return (Test-IsWatcher $state $stateFile $scriptDir) }
        if ($Process.HasExited) { return $false }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Start-Watcher {
    if (Test-Path $stateFile) {
        $existing = Read-WatcherState $stateFile
        if ($existing -and (Test-IsWatcher $existing $stateFile $scriptDir)) {
            Write-Host "Already watching $resolved" -ForegroundColor Green
            return
        }
        Remove-Item $stateFile -Force
    }

    # Start-Process joins the arguments with spaces, so a path with spaces has to carry its own quotes.
    # -Persistent makes the runner write its own state file, so it can never remove one before it exists.
    $logFile = Join-Path $stateDir "$digest.log"
    $process = Start-Process powershell `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$runner`"", "`"$resolved`"", '-Persistent') `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput $logFile -RedirectStandardError "$logFile.err"

    if (-not (Wait-RunnerState $process)) {
        Stop-ProcessTree $process.Id
        Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
        throw "The watcher did not start; see $logFile.err"
    }

    Write-Host "Pinned persistent watcher (pid $($process.Id)) on $resolved" -ForegroundColor Green
    Write-Host "Stop it with: .\docker-compose.ps1 watch-stop `"$resolved`"" -ForegroundColor DarkGray
}

if (-not (Enter-WatchLock $lock)) { throw "Another watch of $resolved is still starting; try again." }
try { Start-Watcher }
finally { Exit-WatchLock $lock }
