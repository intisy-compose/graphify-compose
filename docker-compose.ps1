#Requires -Version 5.1
param([string]$Command = "up")

Set-StrictMode -Version Latest

function Write-Step([string]$msg) { Write-Host $msg -ForegroundColor Cyan }
function Write-Err([string]$msg)  { Write-Host $msg -ForegroundColor Red }

function Show-Usage([hashtable]$Commands) {
    $width = ($Commands.Keys | Measure-Object -Property Length -Maximum).Maximum
    Write-Host "Usage: .\docker-compose.ps1 [$(($Commands.Keys | Sort-Object) -join '|')]"
    foreach ($cmd in $Commands.Keys | Sort-Object) {
        Write-Host ("  {0}  {1}" -f $cmd.PadRight($width), $Commands[$cmd])
    }
}

function Assert-Setup {
    if (-not (Test-Path "$PSScriptRoot\.env")) {
        Write-Err "No .env found - copy .env.example to .env and fill it in."; exit 1
    }
    if (-not (Test-Path "$PSScriptRoot\repo\Dockerfile")) {
        Write-Err "No build context - run: git clone https://github.com/Graphify-Labs/graphify repo"; exit 1
    }
}

function Show-Urls {
    Write-Host ""
    Write-Host "  MCP endpoint   : http://localhost:8770/mcp"
    Write-Host "  Demo explorer  : http://localhost:8771/demo/graph.html"
    Write-Host "  Any project    : http://localhost:8771/projects/<path>/graphify-out/graph.html"
}

Set-Location $PSScriptRoot

$usage = @{
    "up"      = "Build and start the stack (default)"
    "down"    = "Stop and remove everything"
    "restart" = "Rebuild and recreate the stack"
    "logs"    = "Follow logs"
}

switch ($Command.ToLower()) {
    "up"      { Assert-Setup; Write-Step "Starting graphify..."; docker compose up -d --build; Show-Urls; break }
    "down"    { Write-Step "Stopping everything..."; docker compose down; break }
    "restart" { Assert-Setup; Write-Step "Recreating..."; docker compose up -d --build --force-recreate; Show-Urls; break }
    "logs"    { docker compose logs -f; break }
    default   { Show-Usage -Commands $usage; exit 1 }
}
