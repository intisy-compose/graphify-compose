#Requires -Version 5.1
param([string]$Command = "up")

# $args, not ValueFromRemainingArguments, so -Switch tokens still bind when splatted to a helper.
$forwarded = $args

Set-StrictMode -Version Latest

$image          = "graphify-server:latest"
$previousImage  = "graphify-server:previous"
$candidateName  = "graphify-candidate"
$candidatePort  = 18770
$composeFile    = Join-Path $PSScriptRoot "docker-compose.yml"
$dockerfile     = Join-Path $PSScriptRoot "image\Dockerfile"
$lockFile       = Join-Path $PSScriptRoot "image\requirements.lock"
$sourcePattern  = 'graphify\.git#([0-9a-f]{40})'

function Write-Step([string]$msg) { Write-Host $msg -ForegroundColor Cyan }
function Write-OK([string]$msg)   { Write-Host "  $msg" -ForegroundColor Green }
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

function Test-ImageExists([string]$Name) {
    docker image inspect $Name *> $null
    return $LASTEXITCODE -eq 0
}

function Get-PinnedSource {
    $match = [regex]::Match((Get-Content $composeFile -Raw), $sourcePattern)
    if (-not $match.Success) { throw "No pinned graphify commit found in docker-compose.yml" }
    return $match.Groups[1].Value
}

function Get-BaseImage {
    $match = [regex]::Match((Get-Content $dockerfile -Raw), '(?m)^FROM\s+(\S+)')
    if (-not $match.Success) { throw "No FROM line found in image\Dockerfile" }
    return $match.Groups[1].Value
}

# Any HTTP status from /mcp means the server came up; 000 means it never answered.
function Test-ImageServes([string]$Name) {
    docker rm -f $candidateName *> $null
    docker run -d --name $candidateName -p "${candidatePort}:8080" -e "GRAPHIFY_API_KEY=candidate-check" `
        -v "${PSScriptRoot}\graphify-out:/data:ro" $Name `
        /data/graph.json --transport http --host 0.0.0.0 --port 8080 *> $null
    $deadline = (Get-Date).AddSeconds(90)
    $serves = $false
    while ((Get-Date) -lt $deadline) {
        $code = & curl.exe -s -o NUL -m 5 -w '%{http_code}' "http://localhost:$candidatePort/mcp" 2>$null
        if ($code -match '^\d{3}$' -and $code -ne '000') { $serves = $true; break }
        if ((docker inspect -f '{{.State.Running}}' $candidateName 2>$null) -ne 'true') { break }
        Start-Sleep -Seconds 2
    }
    if (-not $serves) { docker logs --tail 15 $candidateName 2>&1 | ForEach-Object { Write-Host "    $_" } }
    docker rm -f $candidateName *> $null
    return $serves
}

function Invoke-SafeRebuild {
    $hadImage = Test-ImageExists $image
    if ($hadImage) { docker tag $image $previousImage }

    Write-Step "Building the pinned image..."
    docker compose build graphify
    if ($LASTEXITCODE -ne 0) {
        if ($hadImage) { docker tag $previousImage $image }
        Write-Err "Build failed - the current image is unchanged."; exit 1
    }

    Write-Step "Testing the new image on :$candidatePort before switching..."
    if (-not (Test-ImageServes $image)) {
        if ($hadImage) {
            docker tag $previousImage $image
            Write-Err "The new image does not serve - kept the previous one, the running stack is untouched."
        } else {
            Write-Err "The new image does not serve."
        }
        exit 1
    }
    Write-OK "New image serves."
    docker compose up -d --force-recreate
    Show-Urls
}

function Invoke-Relock([string]$Commit) {
    if ($Commit) {
        if ($Commit -notmatch '^[0-9a-f]{40}$') { Write-Err "relock takes a full 40-character commit sha"; exit 1 }
        $text = Get-Content $composeFile -Raw
        [System.IO.File]::WriteAllText($composeFile, [regex]::Replace($text, $sourcePattern, "graphify.git#$Commit"))
    }
    $source = Get-PinnedSource
    Write-Step "Resolving dependencies for graphify $($source.Substring(0, 7))..."
    $archive = "https://github.com/Graphify-Labs/graphify/archive/$source.tar.gz"
    $frozen = docker run --rm --entrypoint sh (Get-BaseImage) -c "pip install -q --no-cache-dir --root-user-action=ignore --disable-pip-version-check 'graphifyy[mcp] @ $archive' >&2 && pip freeze"
    if ($LASTEXITCODE -ne 0) { Write-Err "Dependency resolution failed - requirements.lock is unchanged."; exit 1 }
    $locked = @($frozen | Where-Object { $_ -and $_ -notmatch '^graphifyy\b' })
    [System.IO.File]::WriteAllText($lockFile, (($locked -join "`n") + "`n"))
    Write-OK "Wrote $($locked.Count) pinned packages to image\requirements.lock."
    Write-Host "  Run '.\docker-compose.ps1 rebuild' to build and test it, and move the host venv to the same"
    Write-Host "  graphify commit so the watchers and the server stay in step."
}

$usage = @{
    "up"          = "Start the stack, building the image only if it is missing (default)"
    "down"        = "Stop and remove everything"
    "restart"     = "Recreate the stack from the current image"
    "rebuild"     = "Rebuild the pinned image, test it, and only then switch to it"
    "relock"      = "[<commit>]  re-resolve image\requirements.lock (optionally for a new graphify commit)"
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
    "rebuild" { Assert-Setup; Invoke-SafeRebuild; break }
    "relock"  { Invoke-Relock $(if ($forwarded) { "$($forwarded[0])" } else { "" }); break }
    "logs"    { docker compose logs -f; break }
    default   { Show-Usage -Commands $usage; exit 1 }
}
