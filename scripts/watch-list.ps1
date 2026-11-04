<#
.SYNOPSIS
  List all graphify auto-watchers (session-managed and pinned) and whether they're alive: the pid still
  runs that watcher, not merely some process.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'watcher-state.ps1')
$stateDir = Join-Path (Split-Path $PSScriptRoot) '.watchers'
if (-not (Test-Path $stateDir)) { Write-Host 'No watchers.'; return }

$rows = Get-ChildItem -Path $stateDir -Filter '*.json' | ForEach-Object {
    $state = Read-WatcherState $_.FullName
    if (-not $state) { Write-Host "Skipped $($_.FullName): it is not a watcher state file" -ForegroundColor Yellow; return }
    [PSCustomObject]@{
        Pid        = $state.pid
        Alive      = Test-IsWatcher $state $_.FullName
        Persistent = [bool]$state.persistent
        Refs       = $state.refs
        Project    = $state.path
    }
}

if (-not $rows) { Write-Host 'No watchers.'; return }
$rows | Format-Table -AutoSize
