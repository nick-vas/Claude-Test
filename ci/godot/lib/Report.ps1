# Test results: JUnit/TRX parsing, job summaries, failure annotations and JUnit writing.

function New-TestTotals { [pscustomobject]@{ Total = 0; Passed = 0; Failed = 0; Skipped = 0; Failures = [System.Collections.Generic.List[object]]::new() } }

function Add-Failure($Totals, [string]$Name, [string]$Message, [string]$Details) {
    $Totals.Failed++
    $Totals.Failures.Add([pscustomobject]@{ Name = $Name; Message = $Message; Details = $Details })
}

function Read-JUnit([string]$Path, $Totals) {
    [xml]$doc = Get-Content -LiteralPath $Path -Raw
    foreach ($case in $doc.SelectNodes('//testcase')) {
        $Totals.Total++
        $problem = $case.SelectSingleNode('failure|error')
        if ($problem) {
            $name = (@($case.GetAttribute('classname'), $case.GetAttribute('name')) | Where-Object { $_ }) -join '.'
            Add-Failure $Totals $name $problem.GetAttribute('message') $problem.InnerText
        } elseif ($case.SelectSingleNode('skipped') -or $case.GetAttribute('status') -in 'pending', 'skipped') {
            $Totals.Skipped++
        } else {
            $Totals.Passed++
        }
    }
}

function Read-Trx([string]$Path, $Totals) {
    [xml]$doc = Get-Content -LiteralPath $Path -Raw
    $ns = [System.Xml.XmlNamespaceManager]::new($doc.NameTable)
    $ns.AddNamespace('t', 'http://microsoft.com/schemas/VisualStudio/TeamTest/2010')
    foreach ($top in $doc.SelectNodes('/t:TestRun/t:Results/t:UnitTestResult', $ns)) {
        # Data-driven tests (e.g. MSTest [DataRow]) nest one result per row under an aggregate parent.
        $inner = $top.SelectNodes('t:InnerResults/t:UnitTestResult', $ns)
        $results = if ($inner.Count -gt 0) { $inner } else { @($top) }
        foreach ($result in $results) {
            $Totals.Total++
            switch ($result.GetAttribute('outcome')) {
                'Passed' { $Totals.Passed++ }
                { $_ -in 'Failed', 'Error', 'Timeout', 'Aborted' } {
                    $message = $result.SelectSingleNode('t:Output/t:ErrorInfo/t:Message', $ns)
                    $stack = $result.SelectSingleNode('t:Output/t:ErrorInfo/t:StackTrace', $ns)
                    Add-Failure $Totals $result.GetAttribute('testName') ($message ? $message.InnerText : $_) ($stack ? $stack.InnerText : '')
                }
                default { $Totals.Skipped++ }
            }
        }
    }
}

function Write-Annotation([string]$Runner, $Failure) {
    function Escape([string]$Text, [switch]$Property) {
        $Text = $Text -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A'
        if ($Property) { $Text = $Text -replace ':', '%3A' -replace ',', '%2C' }
        return $Text
    }
    $props = @("title=$(Escape "${Runner}: $($Failure.Name)" -Property)")
    $location = [regex]::Match("$($Failure.Details)`n$($Failure.Message)", '(?:in |at )?(?<file>(?:[A-Za-z]:[\\/]|/)[^\s:]+\.(?:cs|gd))(?::line |:)(?<line>\d+)')
    if ($location.Success) {
        $file = $location.Groups['file'].Value
        if ($env:GITHUB_WORKSPACE) {
            $relative = [System.IO.Path]::GetRelativePath($env:GITHUB_WORKSPACE, $file)
            if (-not $relative.StartsWith('..')) { $file = $relative -replace '\\', '/' }
        }
        $props += "file=$(Escape $file -Property)", "line=$($location.Groups['line'].Value)"
    }
    $message = if ($Failure.Message.Trim()) { $Failure.Message.Trim() } else { 'failed' }
    Write-Host "::error $($props -join ',')::$(Escape $message)"
}

# Summarises one runner's results and returns them; .Ok is true when tests ran and none failed. A run
# that reports no tests at all fails, so a misconfigured runner can't pass silently.
function Write-TestSummary([string]$Runner, [string]$ResultsDir, [int]$ExitCode) {
    $totals = New-TestTotals
    $files = Get-ChildItem -LiteralPath $ResultsDir -Recurse -File |
        Where-Object { $_.FullName -notmatch '[\\/]coverage[\\/]' }
    foreach ($file in $files) {
        try {
            if ($file.Name.EndsWith('.junit.xml')) { Read-JUnit $file.FullName $totals }
            elseif ($file.Extension -eq '.trx') { Read-Trx $file.FullName $totals }
        } catch {
            Write-CiLog "Could not parse $($file.FullName): $_"
        }
    }
    $ok = $ExitCode -eq 0 -and $totals.Failed -eq 0 -and $totals.Total -gt 0
    Write-CiLog "${Runner}: $($totals.Passed) passed, $($totals.Failed) failed, $($totals.Skipped) skipped"
    if ($totals.Total -eq 0) { Write-CiLog "$Runner reported no test results (exit code $ExitCode)" }
    elseif ($ExitCode -ne 0) { Write-CiLog "$Runner exited with code $ExitCode" }

    if ($env:GITHUB_ACTIONS) {
        $totals.Failures | Select-Object -First 20 | ForEach-Object { Write-Annotation $Runner $_ }
    }
    if ($env:GITHUB_STEP_SUMMARY) {
        $icon = [char]::ConvertFromUtf32($(if ($ok) { 0x2705 } else { 0x274C }))   # check mark / cross
        $out = [System.Collections.Generic.List[string]]::new()
        $out.AddRange([string[]]@("### $icon Godot tests: ``$Runner``", '',
            '| Total | Passed | Failed | Skipped |', '|---:|---:|---:|---:|',
            "| $($totals.Total) | $($totals.Passed) | $($totals.Failed) | $($totals.Skipped) |", ''))
        if ($totals.Total -eq 0) { $out.Add("No test results were reported (exit code $ExitCode); see the job log."); $out.Add('') }
        foreach ($failure in $totals.Failures | Select-Object -First 50) {
            $detail = if ($failure.Details.Contains($failure.Message.Trim())) { $failure.Details } else { "$($failure.Message)`n$($failure.Details)" }
            $detail = $detail.Trim()
            if ($detail.Length -gt 3000) { $detail = $detail.Substring(0, 3000) }
            $out.AddRange([string[]]@("<details><summary><code>$([System.Net.WebUtility]::HtmlEncode($failure.Name))</code></summary>", '',
                '```', $detail, '```', '</details>', ''))
        }
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $out -Encoding utf8
    }
    return [pscustomobject]@{
        Runner = $Runner; Ok = $ok; Total = $totals.Total; Passed = $totals.Passed
        Failed = $totals.Failed; Skipped = $totals.Skipped
        Failures = @($totals.Failures | Select-Object -First 10 | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Message = ($_.Message.Trim() -split "`n")[0] } })
    }
}

# JUnit for runners without their own report. Each case: @{ Name = ...; Failure = '' or the reason }.
function Write-JUnitCases([string]$Path, [string]$Suite, [object[]]$Cases) {
    $e = { param($t) [System.Security.SecurityElement]::Escape([string]$t) }
    $failed = @($Cases | Where-Object { $_.Failure }).Count
    $xml = [System.Collections.Generic.List[string]]::new()
    $xml.Add('<?xml version="1.0" encoding="UTF-8"?>')
    $xml.Add("<testsuites><testsuite name=""$(& $e $Suite)"" tests=""$($Cases.Count)"" failures=""$failed"">")
    foreach ($case in $Cases) {
        $xml.Add("  <testcase classname=""$(& $e $Suite)"" name=""$(& $e $case.Name)"">")
        if ($case.Failure) {
            $xml.Add("    <failure message=""$(& $e ($case.Failure -split "`n")[0])"">$(& $e $case.Failure)</failure>")
        }
        $xml.Add('  </testcase>')
    }
    $xml.Add('</testsuite></testsuites>')
    Set-Content -LiteralPath $Path -Value $xml -Encoding utf8
}

function Write-SingleCaseJUnit([string]$Path, [string]$Name, [bool]$Passed, [string]$Message) {
    Write-JUnitCases $Path $Name @(@{ Name = $Name; Failure = $(if ($Passed) { '' } else { $Message }) })
}

# Chickensoft GoDotTest prints results to the console only; turn its log into JUnit.
function ConvertFrom-GoDotTestLog([string]$LogFile, [string]$JUnitFile) {
    $lines = @(Get-Content -LiteralPath $LogFile | ForEach-Object { $_ -replace "`e\[[0-9;]*m", '' })
    $cases = [ordered]@{}; $errors = @{}
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '>\s*(OK|!!)\s*>>\s*(?<suite>[\w.`+]+)::(?<test>\w+) \[Test\] > Test (?<outcome>passed|failed)') {
            $cases["$($Matches.suite)::$($Matches.test)"] = $Matches.outcome
        } elseif ($lines[$i] -match '>\s*!!\s*>>\s*(?<suite>[\w.`+]+)::(?<test>\w+) \[Test\] > Error occurred: (?<msg>.*)') {
            $key = "$($Matches.suite)::$($Matches.test)"
            $detail = [System.Collections.Generic.List[string]]::new(); $detail.Add($Matches.msg)
            # The message, then the exception dump with the stack trace, up to the next GoTest status line.
            for ($j = $i + 1; $j -lt [math]::Min($lines.Count, $i + 60); $j++) {
                if ($lines[$j].StartsWith('Info (GoTest)')) { break }
                $detail.Add($lines[$j])
            }
            $errors[$key] = $detail -join "`n"
        }
    }
    $e = { param($t) [System.Security.SecurityElement]::Escape($t) }
    $xml = [System.Collections.Generic.List[string]]::new()
    $xml.Add('<?xml version="1.0" encoding="UTF-8"?>'); $xml.Add('<testsuites>')
    foreach ($group in $cases.Keys | Group-Object { ($_ -split '::')[0] }) {
        $failed = @($group.Group | Where-Object { $cases[$_] -eq 'failed' }).Count
        $xml.Add("  <testsuite name=""$(& $e $group.Name)"" tests=""$($group.Count)"" failures=""$failed"">")
        foreach ($key in $group.Group) {
            $test = ($key -split '::')[1]
            $xml.Add("    <testcase classname=""$(& $e $group.Name)"" name=""$(& $e $test)"">")
            if ($cases[$key] -eq 'failed') {
                $detail = if ($errors.ContainsKey($key)) { $errors[$key] } else { 'Test failed' }
                $xml.Add("      <failure message=""$(& $e ($detail.Split("`n")[0]))"">$(& $e $detail)</failure>")
            }
            $xml.Add('    </testcase>')
        }
        $xml.Add('  </testsuite>')
    }
    $xml.Add('</testsuites>')
    Set-Content -LiteralPath $JUnitFile -Value $xml -Encoding utf8
}

# One coverage report across runners: <results>/coverage/index.html (+ the job summary on GitHub).
function Merge-Coverage([string]$ResultsDir) {
    $reports = @(Get-ChildItem -LiteralPath $ResultsDir -Recurse -File -Filter '*.cobertura.xml' |
        Where-Object { $_.FullName -notmatch '[\\/]In[\\/]' })
    if ($reports.Count -eq 0) { Write-CiLog 'No coverage data was produced'; return $null }
    $target = Join-Path $ResultsDir 'coverage'
    $tool = Get-DotnetTool 'dotnet-reportgenerator-globaltool' 'reportgenerator'
    Invoke-Checked $tool @("-reports:$(($reports.FullName) -join ';')", "-targetdir:$target",
        '-reporttypes:Html;MarkdownSummaryGithub;TextSummary', '-title:Coverage', '-verbosity:Warning')
    $line = Get-Content -LiteralPath (Join-Path $target 'Summary.txt') | Where-Object { $_ -match 'Line coverage' } | Select-Object -First 1
    $percent = if ($line -match '([\d.]+)%') { [double]::Parse($Matches[1], [cultureinfo]::InvariantCulture) } else { $null }
    if ($null -eq $percent) { Write-CiLog 'Coverage: no coverable lines were found'; return $null }
    Write-CiLog "Coverage: $($line.Trim()) -> $(Join-Path $target 'index.html')"
    if ($env:GITHUB_STEP_SUMMARY) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Value (
            @('<details><summary>Coverage</summary>', '') + (Get-Content -LiteralPath (Join-Path $target 'SummaryGithub.md')) + @('</details>', ''))
    }
    return $percent
}

# summary.json (machine-readable, used for coverage baselines) and summary.md (used for PR comments).
function Write-RunSummary([string]$ResultsDir, $Info, [object[]]$Results, $Coverage, [double]$MinCoverage) {
    $ok = @($Results | Where-Object { -not $_.Ok }).Count -eq 0
    $coverageOk = $MinCoverage -le 0 -or ($null -ne $Coverage -and $Coverage -ge $MinCoverage)
    $summary = [ordered]@{
        name = $Info.Name; godotVersion = $Info.GodotVersion; ok = ($ok -and $coverageOk)
        runners = @($Results | ForEach-Object {
            [ordered]@{ runner = $_.Runner; ok = $_.Ok; total = $_.Total; passed = $_.Passed; failed = $_.Failed
                skipped = $_.Skipped; failures = @($_.Failures) } })
        coverage = $Coverage; minCoverage = $MinCoverage
    }
    $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $ResultsDir 'summary.json') -Encoding utf8

    $mark = { param($good) if ($good) { 'pass' } else { 'FAIL' } }
    $md = [System.Collections.Generic.List[string]]::new()
    $md.Add("| Runner | Result | Passed | Failed | Skipped |"); $md.Add('|---|---|---:|---:|---:|')
    foreach ($r in $Results) { $md.Add("| $($r.Runner) | $(& $mark $r.Ok) | $($r.Passed) | $($r.Failed) | $($r.Skipped) |") }
    if ($null -ne $Coverage) {
        $line = "**Line coverage: $Coverage%**"
        if ($MinCoverage -gt 0) { $line += " (minimum $MinCoverage%: $(& $mark $coverageOk))" }
        $md.Add(''); $md.Add($line)
    }
    $failures = @($Results | ForEach-Object { $runner = $_.Runner; $_.Failures | ForEach-Object { "- ``$runner`` **$($_.Name)**: $($_.Message)" } })
    if ($failures) { $md.Add(''); $md.Add('**Failures**'); $failures | Select-Object -First 15 | ForEach-Object { $md.Add($_) } }
    Set-Content -LiteralPath (Join-Path $ResultsDir 'summary.md') -Value $md -Encoding utf8
}

# Installs a .NET global tool into the shared tools folder once; returns its path.
function Get-DotnetTool([string]$Package, [string]$Command) {
    $dir = Join-Path (Get-ToolsDir) 'tools'
    $exe = Join-Path $dir ($IsWindows ? "$Command.exe" : $Command)
    if (-not (Test-Path -LiteralPath $exe)) { Invoke-Checked dotnet @('tool', 'install', $Package, '--tool-path', $dir) }
    return $exe
}
