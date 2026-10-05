# Shared helpers: logging, running native programs, scanning Godot logs.

function Write-CiLog([string]$Message) { Write-Host "[godot-ci] $Message" }

function Stop-GodotCi([string]$Message) {
    Write-Host "[godot-ci] ERROR: $Message" -ForegroundColor Red
    exit 1
}

# Collapsible log groups on GitHub Actions, plain headers elsewhere.
function Start-LogGroup([string]$Title) {
    if ($env:GITHUB_ACTIONS) { Write-Host "::group::$Title" } else { Write-Host "== $Title ==" }
}
function Stop-LogGroup { if ($env:GITHUB_ACTIONS) { Write-Host '::endgroup::' } }

# Runs a program, streaming its output (stdout and stderr) to the console and, if given, a log file.
# Returns the exit code instead of throwing, so callers decide what a failure means.
function Invoke-Logged {
    param([string]$FilePath, [string[]]$ArgumentList = @(), [string]$LogFile)
    if ($LogFile) {
        & $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $LogFile | Out-Host
    } else {
        & $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" } | Out-Host
    }
    return $LASTEXITCODE
}

# Runs a program and stops the whole run if it fails.
function Invoke-Checked {
    param([string]$FilePath, [string[]]$ArgumentList = @())
    $code = Invoke-Logged -FilePath $FilePath -ArgumentList $ArgumentList
    if ($code -ne 0) { Stop-GodotCi "$FilePath $($ArgumentList -join ' ') exited with $code" }
}

function Get-ToolsDir {
    if ($env:GODOT_TOOLS_DIR) { return $env:GODOT_TOOLS_DIR }
    return Join-Path $HOME '.godot-ci'
}

# Engine-internal messages that say nothing about the project. Extend per project with the
# GODOT_CI_IGNORE_ERRORS environment variable (a regex).
$script:KnownNoise = @(
    # The Android export plugin can read editor settings during headless shutdown (timing-dependent).
    'EditorSettings not instantiated yet when getting setting'
)

# Godot often exits 0 after printing errors, so builds, exports and smoke runs also scan the log.
# Returns the offending lines (empty when the log is clean).
function Get-GodotLogErrors([string]$LogFile) {
    $pattern = '^\s*(SCRIPT ERROR|ERROR|USER ERROR):|Unhandled [Ee]xception|Failed to load script'
    $ignore = @($script:KnownNoise)
    if ($env:GODOT_CI_IGNORE_ERRORS) {
        try { [void][regex]::new($env:GODOT_CI_IGNORE_ERRORS) }
        catch { Stop-GodotCi "GODOT_CI_IGNORE_ERRORS is not a valid regex: $env:GODOT_CI_IGNORE_ERRORS" }
        $ignore += $env:GODOT_CI_IGNORE_ERRORS
    }
    $ignoreRegex = ($ignore | ForEach-Object { "(?:$_)" }) -join '|'
    $errors = @()
    foreach ($raw in Get-Content -LiteralPath $LogFile) {
        $line = $raw -replace "`e\[[0-9;]*m", ''
        if ($line -match $pattern) {
            if ($line -match $ignoreRegex) { Write-CiLog "Ignored known engine noise: $line" }
            else { $errors += $line }
        }
    }
    return , $errors
}

function Assert-GodotLogClean([string]$LogFile, [string]$What) {
    $errors = Get-GodotLogErrors $LogFile
    if ($errors.Count -gt 0) {
        Write-Host '[godot-ci] Godot reported errors:' -ForegroundColor Red
        $errors | Select-Object -First 30 | ForEach-Object { Write-Host "  $_" }
        Stop-GodotCi "$What produced errors (set GODOT_CI_IGNORE_ERRORS to ignore a known message)"
    }
}

# File search that skips folders which never hold the user's own files (and are often huge).
$script:PrunedDirs = @('.git', '.godot', 'addons', 'bin', 'obj', 'node_modules', '.godot-pipelines',
    'test-results', 'TestResults')

function Find-ProjectFiles {
    param([string]$Root, [string]$Filter)
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue((Resolve-Path -LiteralPath $Root).Path)
    while ($queue.Count -gt 0) {
        $dir = $queue.Dequeue()
        Get-ChildItem -LiteralPath $dir -File -Filter $Filter -ErrorAction SilentlyContinue | Sort-Object Name
        Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Sort-Object Name |
            Where-Object { $_.Name -notin $script:PrunedDirs -and $_.Name -notlike 'gdunit4_testadapter*' } |
            ForEach-Object { $queue.Enqueue($_.FullName) }
    }
}

# res:// path of a file inside the project.
function ConvertTo-ResPath([string]$ProjectDir, [string]$File) {
    $relative = [System.IO.Path]::GetRelativePath($ProjectDir, $File) -replace '\\', '/'
    return "res://$relative"
}

function ConvertTo-SafeName([string]$Text) { return ($Text -replace '[^A-Za-z0-9._-]+', '-').Trim('-') }
