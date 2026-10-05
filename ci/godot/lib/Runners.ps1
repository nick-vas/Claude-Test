# The interchangeable test runners. Each writes JUnit or TRX into its own results folder and is then
# summarised the same way (Write-TestSummary).
#
#   dotnet     dotnet test on the solution: xUnit, NUnit, MSTest and any gdUnit4Net suites in it
#   gdunit4    gdUnit4Net only, on the Godot project's csproj; [RequireGodotRuntime] tests run in headless Godot
#   godottest  Chickensoft GoDotTest: the game runs its own suites from a runner scene
#   gut        GUT (GDScript): .gutconfig.json if present, else test_*.gd next to any GutTest script
#   smoke      plays the main scene for N frames and fails on any engine or script error
#   validate   loads every script, scene and resource and instantiates every scene (tools/validate.gd)
#
# -Filter means: dotnet/gdunit4 `dotnet test --filter`; godottest suite name; gut test name.

# gdUnit4Net reads GODOT_BIN and the Godot arguments from here; other frameworks ignore the GdUnit4
# section. No TreatNoTestsAsError: with a filter, projects without a match would fail the run, and
# Write-TestSummary already fails runs that report nothing.
function New-RunSettings([string]$ResultsDir) {
    $path = Join-Path $ResultsDir 'godot.runsettings'
    Set-Content -LiteralPath $path -Encoding utf8 -Value @"
<?xml version="1.0" encoding="utf-8"?>
<RunSettings>
  <RunConfiguration>
    <MaxCpuCount>1</MaxCpuCount>
    <TestSessionTimeout>1800000</TestSessionTimeout>
    <EnvironmentVariables>
      <GODOT_BIN>$([System.Security.SecurityElement]::Escape($env:GODOT_BIN))</GODOT_BIN>
    </EnvironmentVariables>
  </RunConfiguration>
  <GdUnit4>
    <Parameters>--headless</Parameters>
    <DisplayName>FullyQualifiedName</DisplayName>
    <CaptureStdOut>true</CaptureStdOut>
  </GdUnit4>
</RunSettings>
"@
    return $path
}

function Invoke-DotnetTest([string]$Target, [string]$ResultsDir, [string]$Filter, [bool]$Coverage, [string]$Prefix) {
    $arguments = @('test', $Target, '--settings', (New-RunSettings $ResultsDir), '--results-directory', $ResultsDir,
        '--logger', "trx;LogFilePrefix=$Prefix")
    if ($Filter) { $arguments += '--filter', $Filter }
    if ($Coverage) { $arguments += '--collect', 'XPlat Code Coverage' }
    Start-LogGroup "dotnet test $Target"
    $code = Invoke-Logged dotnet $arguments
    Stop-LogGroup
    return $code
}

# One case per file from tools/validate.gd's markers; errors printed between a file's markers fail it.
function ConvertFrom-ValidateLog([string]$LogFile) {
    $cases = @(); $current = $null; $buffer = @(); $outside = @()
    foreach ($raw in Get-Content -LiteralPath $LogFile) {
        $line = $raw -replace "`e\[[0-9;]*m", ''
        if ($line -match '^@@validate begin (?<path>.+)$') {
            $current = $Matches.path; $buffer = @()
        } elseif ($current -and $line.StartsWith("@@validate end $current ")) {
            # Matched by the known path rather than a regex: paths may contain spaces.
            $status = $line.Substring("@@validate end $current ".Length)
            $problems = @(Select-GodotErrors $buffer)
            if ($status -ne 'ok') { $problems = @($status) + $problems }
            $cases += @{ Name = $current; Failure = ($problems -join "`n") }
            $current = $null
        } elseif ($current) {
            $buffer += $line
        } else {
            $outside += $line
        }
    }
    # Errors before the first file (autoloads, project settings) belong to the project as a whole.
    $startup = @(Select-GodotErrors $outside)
    if ($startup.Count -gt 0) { $cases += @{ Name = 'project startup'; Failure = ($startup -join "`n") } }
    return $cases
}

function Invoke-TestRunner {
    param([string]$Runner, $Info, [string]$ResultsDir, [string]$Filter, [bool]$Coverage, [int]$Frames)

    if (Test-Path -LiteralPath $ResultsDir) { Remove-Item -Recurse -Force $ResultsDir }
    New-Item -ItemType Directory -Force $ResultsDir | Out-Null
    $godot = $env:GODOT_BIN
    $project = $Info.ProjectDir
    $code = 0

    switch ($Runner) {
        'dotnet' {
            if (-not $Info.Solution) { Stop-GodotCi "dotnet runner: no .sln/.csproj found (pass -Solution)" }
            $code = Invoke-DotnetTest $Info.Solution $ResultsDir $Filter $Coverage 'dotnet'
        }
        'gdunit4' {
            $csproj = if ($Info.Solution -like '*.csproj') { $Info.Solution } else {
                (Get-ChildItem -LiteralPath $project -File -Filter '*.csproj' | Select-Object -First 1).FullName }
            if (-not $csproj) { Stop-GodotCi "gdunit4 runner: no .csproj in $project" }
            if ((Get-Content -LiteralPath $csproj -Raw) -notmatch 'gdUnit4\.test\.adapter') {
                Stop-GodotCi "gdunit4 runner: $csproj does not reference gdUnit4.test.adapter"
            }
            $code = Invoke-DotnetTest $csproj $ResultsDir $Filter $Coverage 'gdunit4'
        }
        'godottest' {
            $log = Join-Path $ResultsDir 'godottest.log'
            $sceneArgs = if ($Info.GoDotTestScene) { @($Info.GoDotTestScene) } else { @() }
            $testArgs = @('--headless', '--path', $project) + $sceneArgs + @("--run-tests$(if ($Filter) { "=$Filter" })", '--quit-on-finish')
            Start-LogGroup "GoDotTest $($Info.GoDotTestScene)"
            if ($Coverage) {
                # The editor runs the Debug build; an ExportRelease folder left by an export must not be used.
                $bin = Join-Path $project '.godot/mono/temp/bin/Debug'
                if (-not (Test-Path -LiteralPath $bin)) { Stop-GodotCi "godottest: no Debug build in $bin" }
                $coverlet = Get-DotnetTool 'coverlet.console' 'coverlet'
                New-Item -ItemType Directory -Force (Join-Path $ResultsDir 'coverage') | Out-Null
                # coverlet hands --targetargs to Godot as one string, so quote the path.
                $targetArgs = (($testArgs + '--coverage') | ForEach-Object { if ($_ -match '\s') { """$_""" } else { $_ } }) -join ' '
                $code = Invoke-Logged $coverlet @($bin, '--target', $godot, '--targetargs', $targetArgs,
                    '--format', 'cobertura', '--output', (Join-Path $ResultsDir 'coverage/godottest.cobertura.xml'),
                    '--exclude-by-file', '**/test/**/*.cs', '--exclude-assemblies-without-sources', 'MissingAll') $log
            } else {
                $code = Invoke-Logged $godot $testArgs $log
            }
            Stop-LogGroup
            ConvertFrom-GoDotTestLog $log (Join-Path $ResultsDir 'godottest.junit.xml')
        }
        'gut' {
            if (-not (Test-Path -LiteralPath (Join-Path $project 'addons/gut/gut_cmdln.gd'))) {
                Stop-GodotCi "gut runner: addons/gut is missing"
            }
            $gutArgs = @('--headless', '--path', $project, '-s', 'addons/gut/gut_cmdln.gd', '-gexit', '-gdisable_colors',
                "-gjunit_xml_file=$(Join-Path $ResultsDir 'gut.junit.xml')")
            if (-not (Test-Path -LiteralPath (Join-Path $project '.gutconfig.json'))) {
                # Search every folder that holds a script extending GutTest.
                Get-GutTestFiles $project | ForEach-Object { ConvertTo-ResPath $project $_.DirectoryName } |
                    Sort-Object -Unique | ForEach-Object { $gutArgs += "-gdir=$_" }
            }
            if ($Filter) { $gutArgs += "-gunit_test_name=$Filter" }
            Start-LogGroup 'GUT'
            $code = Invoke-Logged $godot $gutArgs (Join-Path $ResultsDir 'gut.log')
            Stop-LogGroup
        }
        'validate' {
            $log = Join-Path $ResultsDir 'validate.log'
            $tool = (Join-Path $PSScriptRoot '../tools/validate.gd' | Resolve-Path).Path -replace '\\', '/'
            Start-LogGroup 'Validate scripts, scenes and resources'
            $code = Invoke-Logged $godot @('--headless', '--path', $project, '-s', $tool) $log
            Stop-LogGroup
            $cases = @(ConvertFrom-ValidateLog $log)
            if ($code -ne 0) { $cases += @{ Name = 'validate'; Failure = "Godot exited with $code" } }
            Write-JUnitCases (Join-Path $ResultsDir 'validate.junit.xml') 'validate' $cases
        }
        'smoke' {
            $log = Join-Path $ResultsDir 'smoke.log'
            Start-LogGroup "Smoke run ($Frames frames)"
            $code = Invoke-Logged $godot @('--headless', '--path', $project, '--quit-after', "$Frames") $log
            Stop-LogGroup
            $errors = @(Get-GodotLogErrors $log)
            $message = if ($code -ne 0) { "Godot exited with $code" }
                elseif ($errors.Count -gt 0) { $errors -join "`n" }
                else { "Main scene ran $Frames frames without errors" }
            if ($errors.Count -gt 0 -and $code -eq 0) { $code = 1 }
            Write-SingleCaseJUnit (Join-Path $ResultsDir 'smoke.junit.xml') 'smoke' ($code -eq 0) $message
        }
    }

    # dotnet's coverage collector writes into per-run GUID folders; gather it in one place.
    if ($Coverage) {
        $coverageDir = Join-Path $ResultsDir 'coverage'
        New-Item -ItemType Directory -Force $coverageDir | Out-Null
        Get-ChildItem -LiteralPath $ResultsDir -Recurse -File -Filter 'coverage.cobertura.xml' |
            Where-Object { $_.FullName -notmatch '[\\/](coverage|In)[\\/]' } |
            ForEach-Object { Move-Item -LiteralPath $_.FullName (Join-Path $coverageDir "$Runner-$($_.Directory.Name).cobertura.xml") }
    }

    return Write-TestSummary $Runner $ResultsDir $code
}
