<#
.SYNOPSIS
  Self-heal the graphify MCP server if Docker Desktop's host->container port proxy drops.

.DESCRIPTION
  The container can stay "Up" while Docker's WSL2 port proxy silently stops forwarding,
  leaving the MCP unreachable on the host (curl returns 000 / empty reply). This pings
  the endpoint; a real HTTP status (401 expected — auth required) means healthy, while
  no response means the proxy dropped, and it restarts the containers to rebuild it.
  Meant to run unattended from a Scheduled Task every few minutes.
#>
[CmdletBinding()]
param()

$url = 'http://localhost:8770/mcp'
$logFile = Join-Path $PSScriptRoot 'healthcheck.log'

function Write-Log($message) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $message" | Add-Content -Path $logFile -Encoding utf8
}

function Resolve-Docker {
    $cmd = Get-Command docker -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
    if (Test-Path $fallback) { return $fallback }
    return $null
}

# curl.exe ships with Windows 10+. 000 = no HTTP response (proxy down); any 3-digit code = server answered.
$code = (& curl.exe -s -o NUL -m 8 -w '%{http_code}' $url) 2>$null

if ($code -match '^\d{3}$' -and $code -ne '000') {
    exit 0  # healthy - stay quiet to avoid log spam
}

$docker = Resolve-Docker
if (-not $docker) {
    Write-Log "unhealthy (code=$code) but docker CLI not found - skipping"
    exit 0
}

# Is the daemon even up? If not, nothing to do until Docker Desktop returns.
& $docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Log "unhealthy (code=$code) but docker daemon down - skipping"
    exit 0
}

Write-Log "unhealthy (code=$code) -> restarting graphify + graphify-web"
& $docker restart graphify graphify-web *> $null
exit 0
