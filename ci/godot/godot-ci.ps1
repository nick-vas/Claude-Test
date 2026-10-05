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
    ./ci/godot/godot-ci.ps1 export -Preset Windows -Run    # export, then launch the build to check it starts
#>
[CmdletBinding()]
param(
    # test (default): build, then run every test runner. build: install, addons, compile, import.
    # export: build, then export presets. setup: install Godot/.NET only. detect: print what was found.
    [Parameter(Position = 0)]
    [ValidateSet('test', 'build', 'export', 'setup', 'detect', 'doctor', 'init')]
    [string]$Command = 'test',

    # Folder with project.godot. Default: the shallowest one under the current folder.
    [string]$Project,
    # .sln/.csproj for dotnet. Default: the nearest one at or above the project.
    [string]$Solution,
    # e.g. 4.6.1 or 4.7-rc1. Default: from Godot.NET.Sdk in the csproj, else 4.6.1.
    [string]$GodotVersion,
    # validate, dotnet, gdunit4, godottest, gut, smoke (or none to only build). Default: detected.
    [string[]]$Runners,
    # Passed to each runner's own filter.
    [string]$Filter,
    # Collect coverage (dotnet, gdunit4, godottest) into one report.
    [switch]$Coverage,
    # Fail when line coverage is below this percentage (implies -Coverage).
    [double]$MinCoverage = 0,
    # Presets to export. Default: every preset in export_presets.cfg.
    [string[]]$Preset,
    # export: also launch each build this machine can run (e.g. Windows builds on Windows) and fail on errors.
    [switch]$Run,
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
foreach ($lib in 'Common', 'Setup', 'Detect', 'Report', 'Runners', 'Doctor', 'Init') { . (Join-Path $PSScriptRoot "lib/$lib.ps1") }

$info = Get-ProjectInfo -Project $Project -Solution $Solution -GodotVersion $GodotVersion -Runners $Runners
$presets = @(if ($Preset) { $Preset | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } } else { $info.Presets })

if ($Command -eq 'detect') {
    $platforms = [ordered]@{}
    foreach ($detail in (Get-ExportPresetDetails $info.ProjectDir).Values) { $platforms[$detail.Name] = $detail.Platform }
    $values = [ordered]@{
        'project'         = $info.ProjectDir
        'name'            = $info.Name
        'solution'        = $info.Solution
        'godot-version'   = $info.GodotVersion
        'runners'         = $info.Runners -join ','
        'godottest-scene' = $info.GoDotTestScene
        'presets'         = ConvertTo-Json -Compress -InputObject @($presets)
        'preset-platforms' = ConvertTo-Json -Compress -InputObject $platforms
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
    # GUT whenever GUT tests exist, not only for the gut runner: validate loads those scripts too.
    $needsGut = $info.Runners -contains 'gut' -or @(Get-GutTestFiles $info.ProjectDir).Count -gt 0
    if ($needsGut -and -not (Test-Path -LiteralPath (Join-Path $info.ProjectDir 'addons/gut/gut_cmdln.gd'))) {
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
    $collect = $Coverage -or $MinCoverage -gt 0
    $resultsDir = [System.IO.Path]::GetFullPath($Results)
    if (Test-Path -LiteralPath $resultsDir) { Remove-Item -Recurse -Force $resultsDir }
    $runs = @(foreach ($runner in $info.Runners) {
        Invoke-TestRunner -Runner $runner -Info $info -ResultsDir (Join-Path $resultsDir $runner) `
            -Filter $Filter -Coverage ($collect -and $runner -notin 'gut', 'smoke', 'validate') -Frames $Frames
    })
    $percent = if ($collect) { Merge-Coverage $resultsDir } else { $null }
    Write-RunSummary $resultsDir $info $runs $percent $MinCoverage

    $failed = @($runs | Where-Object { -not $_.Ok } | ForEach-Object Runner)
    if ($failed.Count -gt 0) { Stop-GodotCi "Failed runners: $($failed -join ', ') (results in $resultsDir)" }
    if ($MinCoverage -gt 0) {
        if ($null -eq $percent) { Stop-GodotCi "-MinCoverage $MinCoverage was set, but no coverage was collected" }
        if ($percent -lt $MinCoverage) { Stop-GodotCi "Line coverage $percent% is below the minimum of $MinCoverage%" }
        Write-CiLog "Line coverage $percent% meets the minimum of $MinCoverage%"
    }
    Write-CiLog "All runners passed: $($info.Runners -join ', ')"
}

function Invoke-Export {
    if ($presets.Count -eq 0) { Stop-GodotCi "No export presets in $(Join-Path $info.ProjectDir 'export_presets.cfg')" }
    $details = Get-ExportPresetDetails $info.ProjectDir
    foreach ($name in $presets) {
        if (-not $details.Contains($name)) { Stop-GodotCi "Preset '$name' not found; the project has: $($info.Presets -join ', ')" }
        $preset = $details[$name]
        if (-not $preset.ExportPath) { Stop-GodotCi "Preset '$name' has no export_path" }
        $dir = Join-Path ([System.IO.Path]::GetFullPath($Output)) (ConvertTo-SafeName $name)
        New-Item -ItemType Directory -Force $dir | Out-Null
        $file = Join-Path $dir (Split-Path $preset.ExportPath -Leaf)

        Start-LogGroup "Export '$name' -> $file"
        $log = [System.IO.Path]::GetTempFileName()
        $code = Invoke-Logged $env:GODOT_BIN @('--headless', '--path', $info.ProjectDir, '--export-release', $name, $file) $log
        Stop-LogGroup
        if ($code -ne 0) { Stop-GodotCi "Export '$name' exited with $code" }
        if (-not (Test-Path -LiteralPath $file)) { Stop-GodotCi "Export '$name' finished but $file was not created" }
        Assert-GodotLogClean $log "Export '$name'"
        Write-CiLog ("Exported {0:N0} MB to {1}" -f ((Get-ChildItem -LiteralPath $dir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), $dir)

        if ($Run) { Test-ExportedBuild $name $preset.Platform $file }
    }
}

# Launches the exported game headless, as a player would get it, and fails on any engine error. This catches
# what the editor hides: missing assets, code trimmed from the build, test-only dependencies.
function Test-ExportedBuild([string]$Name, [string]$Platform, [string]$File) {
    if (-not (Test-CanRunPlatform $Platform)) {
        Write-CiLog "Can't launch the '$Name' build ($Platform) on this machine; skipped. Run export -Run on a matching OS."
        return
    }
    if (-not $IsWindows) { Invoke-Checked chmod @('+x', $File) }
    Start-LogGroup "Run exported '$Name' ($Frames frames)"
    $log = [System.IO.Path]::GetTempFileName()
    $code = Invoke-Logged $File @('--headless', '--quit-after', "$Frames") $log
    Stop-LogGroup
    if ($code -ne 0) { Stop-GodotCi "The exported '$Name' build exited with $code" }
    Assert-GodotLogClean $log "The exported '$Name' build"
    Write-CiLog "Exported '$Name' build ran $Frames frames without errors"
}

Write-CiLog "Project $($info.ProjectDir) | Godot $($info.GodotVersion) | solution $(if ($info.Solution) { $info.Solution } else { 'none' }) | runners $(if ($info.Runners) { $info.Runners -join ',' } else { 'none' })"
switch ($Command) {
    'doctor' { Invoke-Doctor $info }
    'init' { Initialize-Project $info }
    'setup' { Invoke-Setup -WithTemplates:$Templates }
    'build' { Invoke-Setup; Invoke-Build }
    'test' { Invoke-Setup; Invoke-Build; Invoke-Tests }
    'export' { Invoke-Setup -WithTemplates; Invoke-Build; Invoke-Export }
}
