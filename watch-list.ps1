<#
.SYNOPSIS
  List all graphify auto-watchers (session-managed and pinned) and whether they're alive.
#>
[CmdletBinding()]
param()

$stateDir = Join-Path $PSScriptRoot '.watchers'
if (-not (Test-Path $stateDir)) { Write-Host 'No watchers.'; return }

$rows = Get-ChildItem -Path $stateDir -Filter '*.json' | ForEach-Object {
    $state = Get-Content $_.FullName -Raw | ConvertFrom-Json
    $alive = $null -ne (Get-Process -Id $state.pid -ErrorAction SilentlyContinue)
    [PSCustomObject]@{
        Pid        = $state.pid
        Alive      = $alive
        Persistent = [bool]$state.persistent
        Refs       = $state.refs
        Project    = $state.path
    }
}

if (-not $rows) { Write-Host 'No watchers.'; return }
$rows | Format-Table -AutoSize
