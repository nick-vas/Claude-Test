# Works out everything about a project that would otherwise be configuration.

function Find-GodotProject {
    # The shallowest project.godot under the current folder.
    $file = Find-ProjectFiles -Root '.' -Filter 'project.godot' | Select-Object -First 1
    if (-not $file) { Stop-GodotCi "No project.godot found under $PWD; pass -Project" }
    return $file.DirectoryName
}

function Find-Solution([string]$ProjectDir) {
    # Walk up from the project to the repository root (or the filesystem root).
    $stop = (& git -C $ProjectDir rev-parse --show-toplevel 2>$null)
    $dir = Get-Item -LiteralPath $ProjectDir
    while ($dir) {
        $sln = Get-ChildItem -LiteralPath $dir.FullName -File |
            Where-Object { $_.Extension -in '.sln', '.slnx' } | Sort-Object Name | Select-Object -First 1
        if ($sln) { return $sln.FullName }
        if ($stop -and ($dir.FullName -replace '\\', '/') -eq ($stop -replace '\\', '/')) { break }
        $dir = $dir.Parent
    }
    $csproj = Get-ChildItem -LiteralPath $ProjectDir -File -Filter '*.csproj' | Sort-Object Name | Select-Object -First 1
    if ($csproj) { return $csproj.FullName }
    return ''
}

function Get-GodotVersionFromProject([string]$ProjectDir) {
    foreach ($csproj in Get-ChildItem -LiteralPath $ProjectDir -File -Filter '*.csproj') {
        if ((Get-Content -LiteralPath $csproj.FullName -Raw) -match 'Godot\.NET\.Sdk/(?<v>\d+\.\d+(?:\.\d+)?(?:-[a-z]+\.?\d*)?)') {
            # Godot.NET.Sdk writes 4.7.0-rc.1; Godot's release tags are 4.7-rc1.
            return $Matches.v -replace '-(rc|beta|dev)\.', '-$1'
        }
    }
    return ''
}

function Test-ContainsText([System.IO.FileInfo[]]$Files, [string]$Pattern) {
    foreach ($file in $Files) {
        if ((Get-Content -LiteralPath $file.FullName -Raw) -match $Pattern) { return $true }
    }
    return $false
}

# The scene whose script calls GoTest.RunTests, or '' for the main scene.
function Find-GoDotTestScene([string]$ProjectDir) {
    $script = Find-ProjectFiles -Root $ProjectDir -Filter '*.cs' |
        Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'GoTest\.RunTests' } | Select-Object -First 1
    if (-not $script) { return '' }
    $res = ConvertTo-ResPath $ProjectDir $script.FullName
    $scene = Find-ProjectFiles -Root $ProjectDir -Filter '*.tscn' |
        Where-Object { (Get-Content -LiteralPath $_.FullName -Raw).Contains("path=""$res""") } | Select-Object -First 1
    if ($scene) { return ConvertTo-ResPath $ProjectDir $scene.FullName }
    return ''
}

function Get-GutTestFiles([string]$ProjectDir) {
    Find-ProjectFiles -Root $ProjectDir -Filter '*.gd' |
        Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '(?m)^extends\s+GutTest\b' }
}

function Get-ExportPresets([string]$ProjectDir) {
    $file = Join-Path $ProjectDir 'export_presets.cfg'
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    # Get-Content splits CRLF and LF alike, so Windows checkouts parse the same.
    return @(Get-Content -LiteralPath $file | Where-Object { $_ -match '^name="(.*)"$' } | ForEach-Object { $Matches[1] })
}

function Get-ProjectInfo {
    param([string]$Project, [string]$Solution, [string]$GodotVersion, [string[]]$Runners)

    $projectDir = if ($Project) { (Resolve-Path -LiteralPath $Project).Path } else { Find-GodotProject }
    if (-not (Test-Path -LiteralPath (Join-Path $projectDir 'project.godot'))) { Stop-GodotCi "No project.godot in $projectDir" }
    $projectGodot = Get-Content -LiteralPath (Join-Path $projectDir 'project.godot') -Raw

    $sln = if ($Solution) { (Resolve-Path -LiteralPath $Solution).Path } else { Find-Solution $projectDir }

    $version = if ($GodotVersion) { $GodotVersion } else { Get-GodotVersionFromProject $projectDir }
    if (-not $version) { $version = if ($env:GODOT_VERSION) { $env:GODOT_VERSION } else { '4.6.1' } }

    $selected = @($Runners | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($selected.Count -eq 0) {
        # dotnet test on the solution covers xUnit/NUnit/MSTest and gdUnit4Net suites alike.
        if ($sln) {
            $csprojs = @(Find-ProjectFiles -Root (Split-Path $sln) -Filter '*.csproj')
            if (Test-ContainsText $csprojs 'Microsoft\.NET\.Test\.Sdk|gdUnit4\.test\.adapter') { $selected += 'dotnet' }
        }
        $gameCsprojs = @(Get-ChildItem -LiteralPath $projectDir -File -Filter '*.csproj')
        if (Test-ContainsText $gameCsprojs 'Chickensoft\.GoDotTest') { $selected += 'godottest' }
        if (@(Get-GutTestFiles $projectDir).Count -gt 0) { $selected += 'gut' }
        if ($projectGodot -match '(?m)^run/main_scene=') { $selected += 'smoke' }
    } elseif ($selected -contains 'none') {
        $selected = @()
    }
    $valid = 'dotnet', 'gdunit4', 'godottest', 'gut', 'smoke'
    $unknown = @($selected | Where-Object { $_ -notin $valid })
    if ($unknown) { Stop-GodotCi "Unknown runner(s) $($unknown -join ', '); use $($valid -join ', ')" }

    $name = if ($projectGodot -match '(?m)^config/name="(?<n>[^"]*)"') { $Matches.n } else { Split-Path $projectDir -Leaf }

    [pscustomobject]@{
        ProjectDir     = $projectDir
        Name           = ConvertTo-SafeName $name
        Solution       = $sln
        GodotVersion   = $version
        Runners        = $selected
        GoDotTestScene = Find-GoDotTestScene $projectDir
        Presets        = Get-ExportPresets $projectDir
    }
}
