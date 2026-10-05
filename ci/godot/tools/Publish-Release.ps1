#Requires -Version 7.2
<#
.SYNOPSIS
    Zips each exported build and publishes them as a GitHub Release with generated notes. On a tag it
    creates (or updates) the release for that tag; otherwise it only builds the zips (dry run).
    Used by .github/workflows/godot.yml. Needs GH_TOKEN with contents: write.
#>
param(
    [Parameter(Mandatory)][string]$Dist,
    [Parameter(Mandatory)][string]$Name,
    [string]$Tag
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$version = if ($Tag) { $Tag } else { "dev-$($env:GITHUB_SHA.Substring(0, 7))" }
$out = Join-Path $Dist '_release'
New-Item -ItemType Directory -Force $out | Out-Null
$zips = @()
# download-artifact puts each export artifact (named <name>-<preset>) in its own folder.
foreach ($dir in Get-ChildItem -LiteralPath $Dist -Directory | Where-Object Name -ne '_release') {
    $preset = $dir.Name.Substring($Name.Length).TrimStart('-')
    $zip = Join-Path $out "$Name-$version-$preset.zip"
    Compress-Archive -Path (Join-Path $dir.FullName '*') -DestinationPath $zip -Force
    Write-Host ("Packed {0} ({1:N1} MB)" -f (Split-Path $zip -Leaf), ((Get-Item $zip).Length / 1MB))
    $zips += $zip
}
if (-not $zips) { throw "No exported builds found in $Dist; set the workflow's exports input" }

if (-not $Tag) {
    Write-Host "::notice title=Release dry run::Not a tag, so nothing was published. Push a tag (e.g. v1.0.0) to create the release."
    if ($env:GITHUB_STEP_SUMMARY) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value (@('### Release dry run', '') + ($zips | ForEach-Object { "- $(Split-Path $_ -Leaf)" }))
    }
    return
}

& gh release view $Tag *> $null
if ($LASTEXITCODE -eq 0) {
    & gh release upload $Tag @zips --clobber
} else {
    & gh release create $Tag @zips --title "$Name $Tag" --generate-notes --verify-tag
}
if ($LASTEXITCODE -ne 0) { throw "Publishing the release failed (the calling job needs 'permissions: contents: write')" }
Write-Host "Published $Name $Tag with $($zips.Count) build(s)"
if ($env:GITHUB_STEP_SUMMARY) {
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value "### Released [$Name $Tag]($env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/releases/tag/$Tag)"
}
