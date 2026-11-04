<#
.SYNOPSIS
  Stop a graphify auto-watcher (by project folder) or all of them.

.DESCRIPTION
  A state file whose pid now belongs to another process is removed and that process left alone; a file
  that is not a state file is skipped with a warning, so one bad file never keeps the others running.

.PARAMETER TargetPath
  Project folder whose watcher to stop. Ignored when -All is given.

.PARAMETER All
  Stop every watcher.

.EXAMPLE
  .\docker-compose.ps1 watch-stop C:\projects\my-project
.EXAMPLE
  .\docker-compose.ps1 watch-stop -All
#>
[CmdletBinding(DefaultParameterSetName = 'One')]
param(
    [Parameter(Position = 0, ParameterSetName = 'One', Mandatory = $true)]
    [string]$TargetPath,
    [Parameter(ParameterSetName = 'All', Mandatory = $true)]
    [switch]$All
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'watcher-state.ps1')
$stackFolder = Split-Path $PSScriptRoot
$stateDir = Join-Path $stackFolder '.watchers'
if (-not (Test-Path $stateDir)) { Write-Host 'No watchers.'; return }

function Stop-One([string]$StateFile) {
    $state = Read-WatcherState $StateFile
    if (-not $state) { Write-Host "Skipped ${StateFile}: it is not a watcher state file" -ForegroundColor Yellow; return }
    $verdict = Stop-Watcher $state $StateFile $stackFolder
    Remove-Item $StateFile -Force
    if ($verdict -eq 'foreign') {
        Write-Host "Removed stale watcher state for $($state.path): pid $($state.pid) is not its watcher" -ForegroundColor Yellow
    } else {
        Write-Host "Stopped watcher (pid $($state.pid)) for $($state.path)" -ForegroundColor Yellow
    }
}

if ($All) {
    $failures = 0
    foreach ($file in Get-ChildItem -Path $stateDir -Filter '*.json') {
        try { Stop-One $file.FullName }
        catch { Write-Host "Could not stop the watcher in $($file.FullName)" -ForegroundColor Yellow; $failures++ }
    }
    if ($failures) { exit 1 }
    return
}

$resolved = (Resolve-Path $TargetPath).Path
$stateFile = Join-Path $stateDir "$(Get-WatcherDigest $resolved).json"

if (Test-Path $stateFile) { Stop-One $stateFile }
else { Write-Host "No watcher found for $resolved" }
