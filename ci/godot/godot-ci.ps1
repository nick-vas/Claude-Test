#Requires -Version 7.2
<#
.SYNOPSIS
    Build, test and export a Godot 4 project (GDScript or C#). Everything is detected from the project;
    parameters only override what was detected. Runs on Windows (locally) and Linux (GitHub runners).

.EXAMPLE
    ./ci/godot/godot-ci.ps1                        # install Godot if needed, build, run every detected test
.EXAMPLE
    ./ci/godot/godot-ci.ps1 detect                 # show what was found, change nothing
.EXAMPLE
    ./ci/godot/godot-ci.ps1 test -Runners gut -Filter test_combo
.EXAMPLE
    ./ci/godot/godot-ci.ps1 export -Preset Windows
#>
[CmdletBinding()]
param(
    # test (default): build, then run every test runner. build: install, addons, compile, import.
    # export: build, then export presets. setup: install Godot/.NET only. detect: print what was found.
    [Parameter(Position = 0)]
    [ValidateSet('test', 'build', 'export', 'setup', 'detect')]
    [string]$Command = 'test',

    # Folder with project.godot. Default: the shallowest one under the current folder.
    [string]$Project,
    # .sln/.csproj for dotnet. Default: the nearest one at or above the project.
    [string]$Solution,
    # e.g. 4.6.1 or 4.7-rc1. Default: from Godot.NET.Sdk in the csproj, else 4.6.1.
    [string]$GodotVersion,
    # dotnet, gdunit4, godottest, gut, smoke (or none to only build). Default: detected.
    [string[]]$Runners,
    # Passed to each runner's own filter.
    [string]$Filter,
    # Collect coverage (dotnet, gdunit4, godottest) into one report.
    [switch]$Coverage,
    # Presets to export. Default: every preset in export_presets.cfg.
    [string[]]$Preset,
    [string]$Results = 'test-results',
    [string]$Output = 'build',
    # Frames the smoke runner plays.
    [int]$Frames = 120,
    # setup: also install export templates.
    [switch]$Templates,
    # detect: also write the values to $GITHUB_OUTPUT.
    [switch]$GitHubOutput
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
foreach ($lib in 'Common', 'Setup', 'Detect', 'Report', 'Runners') { . (Join-Path $PSScriptRoot "lib/$lib.ps1") }

$info = Get-ProjectInfo -Project $Project -Solution $Solution -GodotVersion $GodotVersion -Runners $Runners
$presets = @(if ($Preset) { $Preset | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } } else { $info.Presets })

if ($Command -eq 'detect') {
    $values = [ordered]@{
        'project'         = $info.ProjectDir
        'name'            = $info.Name
        'solution'        = $info.Solution
        'godot-version'   = $info.GodotVersion
        'runners'         = $info.Runners -join ','
        'godottest-scene' = $info.GoDotTestScene
        'presets'         = ConvertTo-Json -Compress -InputObject @($presets)
    }
    $values.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
    if ($GitHubOutput -and $env:GITHUB_OUTPUT) {
        $values.GetEnumerator() | ForEach-Object { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$($_.Key)=$($_.Value)" }
    }
    exit 0
}

function Invoke-Setup([switch]$WithTemplates) {
    # A Godot you point at yourself (GODOT_BIN) is used as-is.
    if ($env:GODOT_BIN -and -not $env:GODOT_CI_INSTALLED -and -not $WithTemplates) {
        Write-CiLog "Using GODOT_BIN=$env:GODOT_BIN"
        return
    }
    $version, $release = $info.GodotVersion -split '-', 2
    Install-GodotTools -Version $version -Release ($release ? $release : 'stable') -Templates:$WithTemplates
    $env:GODOT_CI_INSTALLED = '1'
}

function Invoke-Build {
    if ($info.Runners -contains 'gut' -and -not (Test-Path -LiteralPath (Join-Path $info.ProjectDir 'addons/gut/gut_cmdln.gd'))) {
        Install-Addon $info.ProjectDir "gut@$(Get-GutTag $info.GodotVersion)"
    }
    if ($info.Solution) {
        Start-LogGroup "dotnet build $($info.Solution)"
        Invoke-Checked dotnet @('build', $info.Solution, '-c', 'Debug')
        Stop-LogGroup
    } else {
        Write-CiLog 'No .sln/.csproj; skipping dotnet build (GDScript-only project)'
    }
    Start-LogGroup 'Godot import'
    $log = [System.IO.Path]::GetTempFileName()
    $code = Invoke-Logged $env:GODOT_BIN @('--headless', '--path', $info.ProjectDir, '--import') $log
    Stop-LogGroup
    if ($code -ne 0) { Stop-GodotCi "Godot import exited with $code" }
    Assert-GodotLogClean $log 'Import'
    Write-CiLog 'Build OK'
}

function Invoke-Tests {
    if ($info.Runners.Count -eq 0) { Write-CiLog 'No test runners detected or selected; build only'; return }
    $resultsDir = [System.IO.Path]::GetFullPath($Results)
    if (Test-Path -LiteralPath $resultsDir) { Remove-Item -Recurse -Force $resultsDir }
    $failed = @()
    foreach ($runner in $info.Runners) {
        $ok = Invoke-TestRunner -Runner $runner -Info $info -ResultsDir (Join-Path $resultsDir $runner) `
            -Filter $Filter -Coverage ($Coverage -and $runner -notin 'gut', 'smoke') -Frames $Frames
        if (-not $ok) { $failed += $runner }
    }
    if ($Coverage) { Merge-Coverage $resultsDir }
    if ($failed.Count -gt 0) { Stop-GodotCi "Failed runners: $($failed -join ', ') (results in $resultsDir)" }
    Write-CiLog "All runners passed: $($info.Runners -join ', ')"
}

function Invoke-Export {
    if ($presets.Count -eq 0) { Stop-GodotCi "No export presets in $(Join-Path $info.ProjectDir 'export_presets.cfg')" }
    $cfg = Get-Content -LiteralPath (Join-Path $info.ProjectDir 'export_presets.cfg')
    foreach ($name in $presets) {
        if ($name -notin $info.Presets) { Stop-GodotCi "Preset '$name' not found; the project has: $($info.Presets -join ', ')" }
        # export_path of the matching [preset.N] section names the output file.
        $exportPath = ''; $inPreset = $false
        foreach ($line in $cfg) {
            if ($line -match '^\[preset\.\d+\]$') { $inPreset = $false }
            elseif ($line -eq "name=""$name""") { $inPreset = $true }
            elseif ($inPreset -and $line -match '^export_path="(.*)"$') { $exportPath = $Matches[1]; break }
        }
        if (-not $exportPath) { Stop-GodotCi "Preset '$name' has no export_path" }
        $dir = Join-Path ([System.IO.Path]::GetFullPath($Output)) (ConvertTo-SafeName $name)
        New-Item -ItemType Directory -Force $dir | Out-Null
        $file = Join-Path $dir (Split-Path $exportPath -Leaf)

        Start-LogGroup "Export '$name' -> $file"
        $log = [System.IO.Path]::GetTempFileName()
        $code = Invoke-Logged $env:GODOT_BIN @('--headless', '--path', $info.ProjectDir, '--export-release', $name, $file) $log
        Stop-LogGroup
        if ($code -ne 0) { Stop-GodotCi "Export '$name' exited with $code" }
        if (-not (Test-Path -LiteralPath $file)) { Stop-GodotCi "Export '$name' finished but $file was not created" }
        Assert-GodotLogClean $log "Export '$name'"
        Write-CiLog ("Exported {0:N0} MB to {1}" -f ((Get-ChildItem -LiteralPath $dir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), $dir)
    }
}

Write-CiLog "Project $($info.ProjectDir) | Godot $($info.GodotVersion) | solution $(if ($info.Solution) { $info.Solution } else { 'none' }) | runners $(if ($info.Runners) { $info.Runners -join ',' } else { 'none' })"
switch ($Command) {
    'setup' { Invoke-Setup -WithTemplates:$Templates }
    'build' { Invoke-Setup; Invoke-Build }
    'test' { Invoke-Setup; Invoke-Build; Invoke-Tests }
    'export' { Invoke-Setup -WithTemplates; Invoke-Build; Invoke-Export }
}
