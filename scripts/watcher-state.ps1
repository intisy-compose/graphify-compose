# Dot-sourced by the watcher scripts: a watcher's state file, whether the pid in it is still that watcher,
# and how a watcher is ended. The twin of watcher-state.sh.

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

function Test-TextContains([string]$Haystack, [string]$Needle) {
    return $Haystack.ToLower().Replace('/', '\').Contains($Needle.ToLower().Replace('/', '\'))
}

# Test-IsWatcher STATE FILE: the state's pid is still its watcher. A pid is reused once its process ends,
# so it counts only while it runs a watcher runner for the state's path and started before FILE was last
# written, with 2 s for the clocks' rounding.
function Test-IsWatcher($State, [string]$File) {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $([int64]$State.pid)" -ErrorAction SilentlyContinue
    if (-not $process -or -not $process.CommandLine) { return $false }
    if ($process.CommandLine -notmatch 'watch-runner\.(ps1|sh)') { return $false }
    if (-not (Test-TextContains $process.CommandLine ([string]$State.path))) { return $false }
    return $process.CreationDate -le (Get-Item $File).LastWriteTime.AddSeconds(2)
}

# Get-GraphifyProcesses STACK PATH: this stack's venv running `graphify watch` on PATH, found by command
# line, because a runner killed outright leaves its graphify running with no pid on record.
function Get-GraphifyProcesses([string]$StackFolder, [string]$Path) {
    $venvPython = Join-Path $StackFolder 'venv\Scripts\python.exe'
    @(Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -and $_.CommandLine -like '*-m graphify watch*' -and
        (Test-TextContains $_.CommandLine $venvPython) -and (Test-TextContains $_.CommandLine $Path)
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
    if (Test-IsWatcher $State $File) { Stop-ProcessTree ([int64]$State.pid) }
    elseif (Get-Process -Id ([int64]$State.pid) -ErrorAction SilentlyContinue) { $verdict = 'foreign' }
    foreach ($orphan in Get-GraphifyProcesses $StackFolder ([string]$State.path)) { Stop-ProcessTree $orphan.ProcessId }
    return $verdict
}
