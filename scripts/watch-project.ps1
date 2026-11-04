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

if (Test-Path $stateFile) {
    $existing = Read-WatcherState $stateFile
    if ($existing -and (Test-IsWatcher $existing $stateFile)) {
        Write-Host "Already watching $resolved" -ForegroundColor Green
        return
    }
}

$logFile = Join-Path $stateDir "$digest.log"
$proc = Start-Process powershell `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner, $resolved) `
    -WindowStyle Hidden -PassThru -RedirectStandardOutput $logFile -RedirectStandardError "$logFile.err"

Start-Sleep -Seconds 1
if ($proc.HasExited) { throw "The watcher did not start; see $logFile.err" }

@{ path = $resolved; pid = $proc.Id; refs = 1; persistent = $true } |
    ConvertTo-Json | Set-Content -Path $stateFile -Encoding utf8

Write-Host "Pinned persistent watcher (pid $($proc.Id)) on $resolved" -ForegroundColor Green
Write-Host "Stop it with: .\docker-compose.ps1 watch-stop `"$resolved`"" -ForegroundColor DarkGray
