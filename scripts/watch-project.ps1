<#
.SYNOPSIS
  Pin a persistent auto-watcher on a project (survives across sessions/reboots).

.DESCRIPTION
  Like the per-session watcher the SessionStart hook starts, but flagged persistent so
  session end never stops it. Use for a project you always want kept current. Stop it
  with `docker-compose.ps1 watch-stop`. Building + watching happens in a detached background process.

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
$scriptDir = Split-Path $PSScriptRoot
$stateDir = Join-Path $scriptDir '.watchers'
$runner = Join-Path $PSScriptRoot 'watch-runner.ps1'

if (-not (Test-Path $TargetPath)) { throw "Project folder not found: $TargetPath" }
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

$resolved = (Resolve-Path $TargetPath).Path
$digest = ([System.BitConverter]::ToString(
    [System.Security.Cryptography.MD5]::Create().ComputeHash(
        [Text.Encoding]::UTF8.GetBytes($resolved.ToLower()))) -replace '-', '').Substring(0, 12).ToLower()
$stateFile = Join-Path $stateDir "$digest.json"

$logFile = Join-Path $stateDir "$digest.log"
$proc = Start-Process powershell `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner, $resolved) `
    -WindowStyle Hidden -PassThru -RedirectStandardOutput $logFile -RedirectStandardError "$logFile.err"

@{ path = $resolved; pid = $proc.Id; refs = 1; persistent = $true } |
    ConvertTo-Json | Set-Content -Path $stateFile -Encoding utf8

Write-Host "Pinned persistent watcher (pid $($proc.Id)) on $resolved" -ForegroundColor Green
Write-Host "Stop it with: .\docker-compose.ps1 watch-stop `"$resolved`"" -ForegroundColor DarkGray
