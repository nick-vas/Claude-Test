# `doctor`: checks the tools and the project for the mistakes that make CI fail or builds ship broken,
# and says how to fix each one. Exits 1 when anything is a hard failure.

# .gitignore files that apply to the project: its own and those above it, up to the repository root.
function Get-GitignoreFiles([string]$ProjectDir) {
    $root = (& git -C $ProjectDir rev-parse --show-toplevel 2>$null)
    $dir = Get-Item -LiteralPath $ProjectDir
    while ($dir) {
        $file = Join-Path $dir.FullName '.gitignore'
        if (Test-Path -LiteralPath $file) { $file }
        if (-not $root -or ($dir.FullName -replace '\\', '/') -eq ($root -replace '\\', '/')) { break }
        $dir = $dir.Parent
    }
}

function Invoke-Doctor($Info) {
    $checks = [System.Collections.Generic.List[object]]::new()
    function Add-Check([string]$Status, [string]$Message, [string]$Fix = '') {
        $checks.Add([pscustomobject]@{ Status = $Status; Message = $Message; Fix = $Fix })
    }
    $project = $Info.ProjectDir
    $csprojs = @(Get-ChildItem -LiteralPath $project -File -Filter '*.csproj')
    $isCSharp = $csprojs.Count -gt 0
    $gameCsproj = if ($isCSharp) { Get-Content -LiteralPath $csprojs[0].FullName -Raw } else { '' }
    $projectGodot = Get-Content -LiteralPath (Join-Path $project 'project.godot') -Raw

    # --- Tools ------------------------------------------------------------------------------------
    Add-Check OK "PowerShell $($PSVersionTable.PSVersion)"
    if (Get-Command git -ErrorAction SilentlyContinue) { Add-Check OK "Git $((& git --version) -replace '^git version ', '')" }
    else { Add-Check FAIL 'Git not found' 'winget install Git.Git' }
    if ($isCSharp) {
        if (Test-DotnetSdk '8.0') { Add-Check OK ".NET SDK $(& dotnet --version)" }
        else { Add-Check FAIL '.NET 8 SDK not found (needed for C# projects)' 'winget install Microsoft.DotNet.SDK.8' }
    }
    $version, $release = $Info.GodotVersion -split '-', 2
    $paths = Get-GodotPaths $version ($release ? $release : 'stable')
    if (Test-Path -LiteralPath $paths.Bin) { Add-Check OK "Godot $($Info.GodotVersion) installed in $(Get-ToolsDir)" }
    else { Add-Check INFO "Godot $($Info.GodotVersion) will be downloaded on the first run (about 100 MB)" }
    if ($Info.Presets.Count -gt 0 -and -not (Test-Path -LiteralPath (Join-Path $paths.TemplatesDir 'version.txt'))) {
        Add-Check INFO 'Export templates will be downloaded on the first export (about 1 GB)'
    }

    # --- Project ----------------------------------------------------------------------------------
    Add-Check OK "Project $project (Godot $($Info.GodotVersion))"
    if ($projectGodot -notmatch '(?m)^run/main_scene=') {
        Add-Check WARN 'No main scene set, so the smoke run is skipped' 'Project Settings > Application > Run > Main Scene'
    }
    if ($isCSharp) {
        if ($gameCsproj -notmatch 'Godot\.NET\.Sdk/') {
            Add-Check FAIL "$($csprojs[0].Name) does not use Godot.NET.Sdk" 'Recreate it from Godot: Project > Tools > C# > Create C# solution'
        }
        if (-not $Info.Solution -or $Info.Solution -like '*.csproj') {
            Add-Check WARN 'No .sln found; Godot needs one to export C# projects' 'Project > Tools > C# > Create C# solution'
        } elseif ((Split-Path $Info.Solution) -ne $project -and $projectGodot -notmatch '(?m)^project/solution_directory=') {
            Add-Check FAIL "The .sln is outside the project folder, but project.godot doesn't say where" `
                "Add solution_directory under [dotnet] in project.godot (or run: godot-ci.ps1 init). Without it, exports ship without your C# code"
        }
    }

    # --- Tests ------------------------------------------------------------------------------------
    $testRunners = @($Info.Runners | Where-Object { $_ -notin 'validate', 'smoke' })
    if ($testRunners.Count -eq 0) {
        Add-Check WARN 'No tests found; only the load check and smoke run will happen' 'Run: godot-ci.ps1 init (adds a starter test)'
    } else {
        Add-Check OK "Test runners: $($Info.Runners -join ', ')"
    }
    $gutFiles = @(Get-GutTestFiles $project)
    $unprefixed = @($gutFiles | Where-Object { $_.Name -notlike 'test_*' })
    if ($unprefixed.Count -gt 0 -and -not (Test-Path -LiteralPath (Join-Path $project '.gutconfig.json'))) {
        Add-Check WARN "GUT only runs files named test_*.gd; these won't run: $($unprefixed.Name -join ', ')" 'Rename them, or set "prefix" in .gutconfig.json'
    }
    $ignored = (Get-GitignoreFiles $project | ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "`n"
    if ($gameCsproj -match 'gdUnit4\.test\.adapter' -and $ignored -notmatch 'gdunit4_testadapter') {
        Add-Check WARN 'gdUnit4Net generates gdunit4_testadapter_v5/ in the project, and .gitignore does not exclude it' 'Add gdunit4_testadapter*/ to .gitignore (or run init)'
    }
    $testsWithoutCoverage = @(Find-ProjectFiles -Root (Split-Path ($Info.Solution ? $Info.Solution : $project)) -Filter '*.csproj' |
        Where-Object { $c = Get-Content -LiteralPath $_.FullName -Raw; $c -match 'Microsoft\.NET\.Test\.Sdk' -and $c -notmatch 'coverlet\.collector' })
    if ($testsWithoutCoverage.Count -gt 0) {
        Add-Check INFO "No coverage for $($testsWithoutCoverage.Name -join ', ') (-Coverage needs coverlet.collector)" 'dotnet add package coverlet.collector'
    }

    # --- Release builds ---------------------------------------------------------------------------
    if ($isCSharp -and $gameCsproj -match 'Microsoft\.NET\.Test\.Sdk|gdUnit4|Chickensoft\.GoDotTest' -and $gameCsproj -notmatch 'ExportRelease') {
        Add-Check WARN 'Test packages are referenced unconditionally, so they ship in release builds' `
            "Put them in an ItemGroup with Condition=""'`$(Configuration)' != 'ExportRelease'"" (or run init)"
    }
    $testDirs = @($gutFiles | ForEach-Object { (ConvertTo-ResPath $project $_.DirectoryName) -replace '^res://', '' } |
        ForEach-Object { ($_ -split '/')[0] } | Where-Object { $_ })
    if (Test-Path -LiteralPath (Join-Path $project 'test')) { $testDirs += 'test' }
    $testDirs = @($testDirs | Sort-Object -Unique)
    $details = Get-ExportPresetDetails $project
    if ($details.Count -eq 0) {
        Add-Check INFO 'No export presets yet' 'Project > Export > Add...'
    }
    foreach ($preset in $details.Values) {
        $filter = (Get-Content -LiteralPath (Join-Path $project 'export_presets.cfg') -Raw) -match "(?ms)name=""$([regex]::Escape($preset.Name))"".*?^exclude_filter=""(?<f>[^""]*)""" ? $Matches.f : ''
        $missing = @($testDirs | Where-Object { $filter -notmatch [regex]::Escape("$_/") })
        if ($missing.Count -gt 0) {
            Add-Check WARN "Export preset '$($preset.Name)' ships test folders: $($missing -join ', ')" `
                "Add $(($missing | ForEach-Object { "$_/*" }) -join ', ') to its exclude filter (or run init)"
        } else {
            Add-Check OK "Export preset '$($preset.Name)' ($($preset.Platform))"
        }
    }

    # --- Report -----------------------------------------------------------------------------------
    $colors = @{ OK = 'Green'; INFO = 'Cyan'; WARN = 'Yellow'; FAIL = 'Red' }
    foreach ($check in $checks) {
        Write-Host ('[{0,-4}] ' -f $check.Status) -ForegroundColor $colors[$check.Status] -NoNewline
        Write-Host $check.Message
        if ($check.Fix -and $check.Status -ne 'OK') { Write-Host "       fix: $($check.Fix)" -ForegroundColor DarkGray }
    }
    $counts = $checks | Group-Object Status -AsHashTable
    $fails = if ($counts -and $counts.ContainsKey('FAIL')) { $counts['FAIL'].Count } else { 0 }
    $warns = if ($counts -and $counts.ContainsKey('WARN')) { $counts['WARN'].Count } else { 0 }
    Write-Host ''
    Write-CiLog "$fails problem(s), $warns warning(s)"
    if ($fails -gt 0) { exit 1 }
}
