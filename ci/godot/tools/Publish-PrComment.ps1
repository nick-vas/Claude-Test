#Requires -Version 7.2
<#
.SYNOPSIS
    Posts (or updates) one comment per game on a pull request with the test summary, and coverage
    compared with the latest run on the base branch. Used by .github/workflows/godot.yml.
    Needs GITHUB_TOKEN with pull-requests: write; without it, it warns instead of failing the run.
#>
param(
    [Parameter(Mandatory)][string]$ResultsDir,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$ArtifactName,
    [Parameter(Mandatory)][int]$PullRequest,
    [string]$Outcome = 'success'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$api = if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL } else { 'https://api.github.com' }
$repo = $env:GITHUB_REPOSITORY
$headers = @{ Authorization = "Bearer $env:GITHUB_TOKEN"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
$runUrl = "$env:GITHUB_SERVER_URL/$repo/actions/runs/$env:GITHUB_RUN_ID"
$marker = "<!-- godot-test-suite:$Name -->"

# Coverage of the newest run on the base branch, from its summary.json, for the comparison line.
function Get-BaselineCoverage {
    if (-not $env:GITHUB_BASE_REF) { return $null }
    try {
        $artifacts = (Invoke-RestMethod -Headers $headers "$api/repos/$repo/actions/artifacts?name=$([uri]::EscapeDataString($ArtifactName))&per_page=50").artifacts
        $baseline = $null
        foreach ($artifact in $artifacts) {
            if (-not $artifact.expired -and $artifact.workflow_run.head_branch -eq $env:GITHUB_BASE_REF) { $baseline = $artifact; break }
        }
        if (-not $baseline) { return $null }
        $zip = Join-Path ([IO.Path]::GetTempPath()) "baseline-$([guid]::NewGuid()).zip"
        Invoke-WebRequest -Headers $headers -Uri $baseline.archive_download_url -OutFile $zip
        $dir = "$zip.d"
        Expand-Archive -LiteralPath $zip -DestinationPath $dir
        $summary = Get-ChildItem -LiteralPath $dir -Recurse -Filter 'summary.json' | Select-Object -First 1
        if (-not $summary) { return $null }
        return (Get-Content -LiteralPath $summary.FullName -Raw | ConvertFrom-Json).coverage
    } catch {
        Write-Host "No coverage baseline from $env:GITHUB_BASE_REF ($($_.Exception.Message))"
        return $null
    }
}

$summaryJson = Join-Path $ResultsDir 'summary.json'
$summaryMd = Join-Path $ResultsDir 'summary.md'
$ok = $Outcome -eq 'success'
$body = [System.Collections.Generic.List[string]]::new()
$body.Add($marker)
$body.Add("### $([char]::ConvertFromUtf32($(if ($ok) { 0x2705 } else { 0x274C }))) Godot tests: $Name")
$body.Add('')
if (Test-Path -LiteralPath $summaryMd) {
    $body.AddRange([string[]](Get-Content -LiteralPath $summaryMd))
    $coverage = (Get-Content -LiteralPath $summaryJson -Raw | ConvertFrom-Json).coverage
    if ($null -ne $coverage) {
        $baseline = Get-BaselineCoverage
        if ($null -ne $baseline) {
            $delta = [math]::Round($coverage - $baseline, 1)
            $sign = if ($delta -gt 0) { '+' } elseif ($delta -eq 0) { '+/-' } else { '' }
            $body.Add("Coverage vs ``$env:GITHUB_BASE_REF``: $baseline% -> $coverage% ($sign$delta)")
        }
    }
} else {
    $body.Add('The build failed before any tests ran.')
}
$body.Add('')
$body.Add("[Run details]($runUrl)")
$payload = @{ body = ($body -join "`n") } | ConvertTo-Json

try {
    # foreach, not Where-Object: Invoke-RestMethod returns a JSON array as one object (empty or not).
    $comments = Invoke-RestMethod -Headers $headers "$api/repos/$repo/issues/$PullRequest/comments?per_page=100"
    $existing = $null
    foreach ($comment in $comments) {
        if ($comment.body -and $comment.body.StartsWith($marker)) { $existing = $comment; break }
    }
    if ($existing) {
        Invoke-RestMethod -Method Patch -Headers $headers -Body $payload -ContentType 'application/json' "$api/repos/$repo/issues/comments/$($existing.id)" | Out-Null
        Write-Host "Updated the test summary comment on #$PullRequest"
    } else {
        Invoke-RestMethod -Method Post -Headers $headers -Body $payload -ContentType 'application/json' "$api/repos/$repo/issues/$PullRequest/comments" | Out-Null
        Write-Host "Posted the test summary comment on #$PullRequest"
    }
} catch {
    Write-Host "::warning title=No PR comment::Couldn't comment on the pull request ($($_.Exception.Message)). Give the calling job 'permissions: pull-requests: write' to get the test summary comment."
}
