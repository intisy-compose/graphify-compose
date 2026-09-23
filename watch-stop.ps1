<#
.SYNOPSIS
  Stop a graphify auto-watcher (by project folder) or all of them.

.PARAMETER TargetPath
  Project folder whose watcher to stop. Ignored when -All is given.

.PARAMETER All
  Stop every watcher.

.EXAMPLE
  .\watch-stop.ps1 C:\projects\my-project
.EXAMPLE
  .\watch-stop.ps1 -All
#>
[CmdletBinding(DefaultParameterSetName = 'One')]
param(
    [Parameter(Position = 0, ParameterSetName = 'One', Mandatory = $true)]
    [string]$TargetPath,
    [Parameter(ParameterSetName = 'All', Mandatory = $true)]
    [switch]$All
)

$ErrorActionPreference = 'Stop'
$stateDir = Join-Path $PSScriptRoot '.watchers'
if (-not (Test-Path $stateDir)) { Write-Host 'No watchers.'; return }

function Stop-One($stateFile) {
    $state = Get-Content $stateFile -Raw | ConvertFrom-Json
    # /T kills the graphify child process the watcher runner spawned, not just the shell.
    taskkill /PID $state.pid /T /F 2>$null | Out-Null
    Remove-Item $stateFile -Force
    Write-Host "Stopped watcher (pid $($state.pid)) for $($state.path)" -ForegroundColor Yellow
}

if ($All) {
    Get-ChildItem -Path $stateDir -Filter '*.json' | ForEach-Object { Stop-One $_.FullName }
    return
}

$resolved = (Resolve-Path $TargetPath).Path
$digest = ([System.BitConverter]::ToString(
    [System.Security.Cryptography.MD5]::Create().ComputeHash(
        [Text.Encoding]::UTF8.GetBytes($resolved.ToLower()))) -replace '-', '').Substring(0, 12).ToLower()
$stateFile = Join-Path $stateDir "$digest.json"

if (Test-Path $stateFile) { Stop-One $stateFile }
else { Write-Host "No watcher found for $resolved" }
