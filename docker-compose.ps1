#Requires -Version 5.1
param([string]$Command = "up")

# $args, not ValueFromRemainingArguments, so -Switch tokens still bind when splatted to a helper.
$forwarded = $args

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

function Invoke-Helper([string]$Name) {
    Set-StrictMode -Off
    & (Join-Path $PSScriptRoot "scripts\$Name.ps1") @forwarded
    exit $LASTEXITCODE
}

function Show-Urls {
    Write-Host ""
    Write-Host "  MCP endpoint   : http://localhost:8770/mcp"
    Write-Host "  Demo explorer  : http://localhost:8771/demo/graph.html"
    Write-Host "  Any project    : http://localhost:8771/projects/<path>/graphify-out/graph.html"
}

$usage = @{
    "up"          = "Start the stack, building the image only if it is missing (default)"
    "down"        = "Stop and remove everything"
    "restart"     = "Recreate the stack from the current image"
    "rebuild"     = "Rebuild the image from repo/ and recreate the stack"
    "logs"        = "Follow logs"
    "regraph"     = "<path> [-Force]  rebuild the default graph from a code folder"
    "watch"       = "<path>  pin a persistent auto-watcher on a project"
    "watch-list"  = "List auto-watchers and whether they are alive"
    "watch-stop"  = "<path> | -All  stop a watcher, or all of them"
    "healthcheck" = "Restart the containers if the host port proxy dropped"
}

$helpers = @{ "regraph" = "regraph"; "watch" = "watch-project"; "watch-list" = "watch-list"; "watch-stop" = "watch-stop"; "healthcheck" = "healthcheck" }
if ($helpers.ContainsKey($Command.ToLower())) { Invoke-Helper $helpers[$Command.ToLower()] }

Set-Location $PSScriptRoot

switch ($Command.ToLower()) {
    "up"      { Assert-Setup; Write-Step "Starting graphify..."; docker compose up -d; Show-Urls; break }
    "down"    { Write-Step "Stopping everything..."; docker compose down; break }
    "restart" { Assert-Setup; Write-Step "Recreating..."; docker compose up -d --force-recreate; Show-Urls; break }
    "rebuild" { Assert-Setup; Write-Step "Rebuilding..."; docker compose up -d --build --force-recreate; Show-Urls; break }
    "logs"    { docker compose logs -f; break }
    default   { Show-Usage -Commands $usage; exit 1 }
}
