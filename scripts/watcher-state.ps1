# Dot-sourced by the watcher scripts: a watcher's state file, whether the pid in it is still that watcher,
# and how a watcher is ended. The twin of watcher-state.sh. Every comparison is of whole arguments, never
# of substrings: C:\w\app must not match a watcher of C:\w\app2 or of a folder below C:\w\app, nor this
# venv another checkout's.

function Get-WatcherDigest([string]$Path) {
    $hash = [System.Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Path.ToLower()))
    return ([System.BitConverter]::ToString($hash) -replace '-', '').Substring(0, 12).ToLower()
}

# Read-WatcherState FILE: the state, or $null for a file that is not a state file (unreadable, not JSON,
# no path, or a pid that is not a whole number of 2 or more).
function Read-WatcherState([string]$File) {
    try { $state = Get-Content $File -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if (-not $state -or -not $state.path -or "$($state.pid)" -notmatch '^\d+$' -or [int64]$state.pid -lt 2) { return $null }
    return $state
}

# Split-CommandLine LINE: the arguments as Windows splits them (CommandLineToArgvW): whitespace outside
# quotes separates, quotes group, and backslashes are literal unless they precede a quote, where 2n give
# n and 2n+1 give n and a literal quote.
function Split-CommandLine([string]$Line) {
    $arguments = New-Object System.Collections.Generic.List[string]
    $argument = New-Object System.Text.StringBuilder
    $quoted = $false; $started = $false; $index = 0
    while ($index -lt $Line.Length) {
        $character = $Line[$index]
        if ($character -eq '\') {
            $slashes = 0
            while ($index -lt $Line.Length -and $Line[$index] -eq '\') { $slashes++; $index++ }
            if ($index -lt $Line.Length -and $Line[$index] -eq '"') {
                [void]$argument.Append('\' * [math]::Floor($slashes / 2))
                if ($slashes % 2 -eq 1) { [void]$argument.Append('"'); $index++ }
            } else {
                [void]$argument.Append('\' * $slashes)
            }
            $started = $true
            continue
        }
        if ($character -eq '"') { $quoted = -not $quoted; $started = $true }
        elseif ([char]::IsWhiteSpace($character) -and -not $quoted) {
            if ($started) { $arguments.Add($argument.ToString()) }
            [void]$argument.Clear(); $started = $false
        }
        else { [void]$argument.Append($character); $started = $true }
        $index++
    }
    if ($started) { $arguments.Add($argument.ToString()) }
    return ,$arguments.ToArray()
}

# ConvertTo-ComparablePath PATH: lowercased, \ only, and a Git Bash /c/... path in Windows form.
function ConvertTo-ComparablePath([string]$Path) {
    if ($Path -match '^/([A-Za-z])/(.*)$') { $Path = "$($Matches[1]):\$($Matches[2])" }
    return $Path.Replace('/', '\').ToLower()
}

function Test-SamePath([string]$First, [string]$Second) {
    return (ConvertTo-ComparablePath $First) -eq (ConvertTo-ComparablePath $Second)
}

# Test-IsRunnerOf STACK PATH ARGUMENTS: one argument is this stack's watch-runner.ps1 or .sh and the
# argument after it is PATH.
function Test-IsRunnerOf([string]$StackFolder, [string]$Path, [string[]]$Arguments) {
    $runners = @((Join-Path $StackFolder 'scripts\watch-runner.ps1'), (Join-Path $StackFolder 'scripts\watch-runner.sh'))
    for ($index = 0; $index + 1 -lt $Arguments.Count; $index++) {
        $isRunner = @($runners | Where-Object { Test-SamePath $Arguments[$index] $_ }).Count -gt 0
        if ($isRunner -and (Test-SamePath $Arguments[$index + 1] $Path)) { return $true }
    }
    return $false
}

# Test-IsGraphifyOf STACK PATH ARGUMENTS: the arguments are this stack's venv python, or a shell running
# it as a script, then exactly -m graphify watch PATH.
function Test-IsGraphifyOf([string]$StackFolder, [string]$Path, [string[]]$Arguments) {
    $venvPython = Join-Path $StackFolder 'venv\Scripts\python.exe'
    if ($Arguments.Count -ge 1 -and (Test-SamePath $Arguments[0] $venvPython)) { $first = 1 }
    elseif ($Arguments.Count -ge 2 -and (($Arguments[0] -split '[\\/]')[-1]) -match '^(ba)?sh(\.exe)?$' -and (Test-SamePath $Arguments[1] $venvPython)) { $first = 2 }
    else { return $false }
    return $Arguments.Count -eq ($first + 4) -and $Arguments[$first] -eq '-m' -and $Arguments[$first + 1] -eq 'graphify' -and
        $Arguments[$first + 2] -eq 'watch' -and (Test-SamePath $Arguments[$first + 3] $Path)
}

# Test-IsWatcher STATE FILE STACK: the state's pid is still its watcher. A pid is reused once its process
# ends, so it counts only while it runs this stack's watcher runner for the state's path and started
# before FILE was last written, with 2 s for the clocks' rounding.
function Test-IsWatcher($State, [string]$File, [string]$StackFolder) {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $([int64]$State.pid)" -ErrorAction SilentlyContinue
    if (-not $process -or -not $process.CommandLine) { return $false }
    if (-not (Test-IsRunnerOf $StackFolder ([string]$State.path) (Split-CommandLine $process.CommandLine))) { return $false }
    return $process.CreationDate -le (Get-Item $File).LastWriteTime.AddSeconds(2)
}

# Get-GraphifyProcesses STACK PATH: this stack's venv running `graphify watch` on PATH, found by command
# line, because a runner killed outright leaves its graphify running with no pid on record.
function Get-GraphifyProcesses([string]$StackFolder, [string]$Path) {
    @(Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -and $_.CommandLine -like '*graphify*watch*' -and
        (Test-IsGraphifyOf $StackFolder $Path (Split-CommandLine $_.CommandLine))
    })
}

function Stop-ProcessTree([int64]$ProcessId) {
    if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return }
    $ErrorActionPreference = 'Continue'
    taskkill /PID $ProcessId /T /F 2>$null | Out-Null
}

# Stop-Watcher STATE FILE STACK: ends the watcher the state names and any graphify it left behind.
# Returns 'foreign' when the pid now belongs to another process, which is left alone, else 'stopped'.
function Stop-Watcher($State, [string]$File, [string]$StackFolder) {
    $verdict = 'stopped'
    if (Test-IsWatcher $State $File $StackFolder) { Stop-ProcessTree ([int64]$State.pid) }
    elseif (Get-Process -Id ([int64]$State.pid) -ErrorAction SilentlyContinue) { $verdict = 'foreign' }
    foreach ($orphan in Get-GraphifyProcesses $StackFolder ([string]$State.path)) { Stop-ProcessTree $orphan.ProcessId }
    return $verdict
}

# Write-WatcherState FILE PATH PID: the state of a persistent watcher, written whole through a temporary
# file, in the shape the sh and the hooks read.
function Write-WatcherState([string]$File, [string]$Path, [int64]$ProcessId) {
    $temporary = "$File.tmp"
    @{ path = $Path; pid = $ProcessId; refs = 1; persistent = $true } | ConvertTo-Json | Set-Content -Path $temporary -Encoding utf8
    Move-Item -Path $temporary -Destination $File -Force
}
