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

# Linux binaries lose their executable bit in upload-artifact/download-artifact, and Compress-Archive can't
# set it; find them by their ELF header so they can be fixed and zipped with Unix modes.
function Test-ElfFile([string]$Path) {
    $header = [byte[]]::new(4)
    $stream = [System.IO.File]::OpenRead($Path)
    try { $read = $stream.Read($header, 0, 4) } finally { $stream.Dispose() }
    return $read -eq 4 -and $header[0] -eq 0x7F -and $header[1] -eq 0x45 -and $header[2] -eq 0x4C -and $header[3] -eq 0x46
}

$version = if ($Tag) { $Tag } else { "dev-$($env:GITHUB_SHA.Substring(0, 7))" }
# Absolute: zip runs from inside each build folder.
$out = [System.IO.Path]::GetFullPath((Join-Path $Dist '_release'))
New-Item -ItemType Directory -Force $out | Out-Null
$zips = @()
# The workflow downloads every export artifact with merge-multiple, so each preset's build is in
# <Dist>/<preset>/ (exports are written to <output>/<preset>/), however many artifacts there are.
foreach ($dir in Get-ChildItem -LiteralPath $Dist -Directory | Where-Object Name -ne '_release') {
    $preset = $dir.Name
    $zip = Join-Path $out "$Name-$version-$preset.zip"
    $executables = @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -File | Where-Object { Test-ElfFile $_.FullName })
    if ($executables -and -not $IsWindows -and (Get-Command zip -ErrorAction SilentlyContinue)) {
        & chmod +x @($executables.FullName)
        Push-Location $dir.FullName
        try { & zip -q -r -X $zip . } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) { throw "zip failed for $preset" }
    } else {
        Compress-Archive -Path (Join-Path $dir.FullName '*') -DestinationPath $zip -Force
    }
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
