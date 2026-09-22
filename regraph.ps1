<#
.SYNOPSIS
  Rebuild the graph for a code folder and reload it into the graphify MCP container.

.DESCRIPTION
  Runs the isolated venv `graphify update` against a target code folder, writing the
  result to graphify-out/graph.json (the exact file the container serves), then
  restarts the container so the MCP tools immediately query the new graph.

.PARAMETER TargetPath
  Path to the code folder to graph. Point at CODE, not data-heavy folders.

.PARAMETER Force
  Overwrite graph.json even if the rebuild has fewer nodes (use after refactors
  that legitimately delete code).

.EXAMPLE
  .\regraph.ps1 F:\Documents\GitHub\javascript\my-project
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$TargetPath,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$graphifyExe = Join-Path $scriptDir 'venv\Scripts\graphify.exe'
$graphFile = Join-Path $scriptDir 'graphify-out\graph.json'
$containerName = 'graphify'

function Assert-Prerequisites {
    if (-not (Test-Path $graphifyExe)) {
        throw "graphify binary not found at $graphifyExe (is the venv intact?)"
    }
    if (-not (Test-Path $TargetPath)) {
        throw "Target code folder not found: $TargetPath"
    }
}

function Invoke-GraphRebuild {
    $resolvedTarget = (Resolve-Path $TargetPath).Path
    Write-Host "Rebuilding graph from $resolvedTarget ..." -ForegroundColor Cyan

    # Run from scriptDir so `update` writes to this folder's graphify-out/graph.json,
    # which is exactly what the container binds to /data.
    Push-Location $scriptDir
    try {
        # Raise the viz node limit so graph.html is generated even for large graphs
        # (default limit is 5000; the web UI container serves the result).
        $env:GRAPHIFY_VIZ_NODE_LIMIT = '20000'
        $updateArgs = @('update', $resolvedTarget)
        if ($Force) { $updateArgs += '--force' }
        & $graphifyExe @updateArgs
        if ($LASTEXITCODE -ne 0) { throw "graphify update exited with code $LASTEXITCODE" }
    }
    finally {
        Pop-Location
    }
}

function Restart-GraphifyContainer {
    if (-not (Test-Path $graphFile)) {
        throw "Expected graph not produced at $graphFile"
    }
    Write-Host "Reloading container '$containerName' ..." -ForegroundColor Cyan
    docker restart $containerName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker restart failed for '$containerName'" }
}

Assert-Prerequisites
Invoke-GraphRebuild
Restart-GraphifyContainer

Write-Host "Done. graphify MCP now serving the graph for '$TargetPath'." -ForegroundColor Green
Write-Host "Run /mcp in Claude Code if tools don't refresh automatically." -ForegroundColor DarkGray
