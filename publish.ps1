<#
.SYNOPSIS
  Publish an APK to the private app store.

.DESCRIPTION
  Uploads the APK as a GitHub Release asset, updates apps.json, and pushes.
  The storefront (index.html on GitHub Pages) reads apps.json and renders it.

.EXAMPLE
  .\publish.ps1 -Name "Today" -Apk "C:\Dev\Notes App\android\app\build\outputs\apk\debug\app-debug.apk" -Version 1.0.0 -Tagline "A todo list that forgets yesterday."
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Name,
  [Parameter(Mandatory)][string]$Apk,
  [Parameter(Mandatory)][string]$Version,
  [string]$Tagline = "",
  [string]$Notes   = ""
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

# --- preflight -------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Apk)) { throw "APK not found: $Apk" }
if ($Version -notmatch '^\d+\.\d+(\.\d+)?$') { throw "Version must look like 1.2 or 1.2.3 (got '$Version')" }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "GitHub CLI 'gh' is not installed." }

gh auth status *> $null
if (-not $?) { throw "Not logged in to GitHub. Run: gh auth login" }

$cfg = Get-Content -LiteralPath 'apps.json' -Raw | ConvertFrom-Json

# --- derive ----------------------------------------------------------------
$slug = ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
if (-not $slug) { throw "Could not derive a slug from name '$Name'." }

$tag      = "$slug-v$Version"
$assetDir = Join-Path $env:TEMP "appstore-$slug-$Version"
$assetName = "$slug-$Version.apk"
$assetPath = Join-Path $assetDir $assetName

# Existing release with this tag? Refuse rather than silently clobber a build
# friends may already have installed.
gh release view $tag *> $null
if ($?) { throw "Release '$tag' already exists. Bump -Version, or delete it: gh release delete $tag --cleanup-tag" }

# gh names the asset after the file, so stage a copy under the public name.
New-Item -ItemType Directory -Force -Path $assetDir | Out-Null
Copy-Item -LiteralPath $Apk -Destination $assetPath -Force

$file   = Get-Item -LiteralPath $assetPath
$size   = [int64]$file.Length
$sha256 = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
$today  = (Get-Date).ToString('yyyy-MM-dd')

Write-Host "Publishing $Name v$Version" -ForegroundColor Cyan
Write-Host "  asset  $assetName  ($([math]::Round($size/1MB,1)) MB)"
Write-Host "  sha256 $sha256"

# --- upload ----------------------------------------------------------------
$releaseNotes = if ($Notes) { $Notes } else { "$Name v$Version" }
gh release create $tag $assetPath --title "$Name v$Version" --notes $releaseNotes | Out-Null
if (-not $?) { throw "gh release create failed." }

Remove-Item -Recurse -Force -LiteralPath $assetDir -ErrorAction SilentlyContinue

# --- update manifest -------------------------------------------------------
# ConvertFrom-Json gives PSCustomObjects; rebuild the list as hashtables so we
# can add/replace entries without fighting the type system.
$entry = [ordered]@{
  slug      = $slug
  name      = $Name
  tagline   = $Tagline
  version   = $Version
  tag       = $tag
  file      = $assetName
  size      = $size
  sha256    = $sha256
  published = $today
}

$kept = @()
foreach ($a in @($cfg.apps)) {
  if ($null -eq $a) { continue }
  if ($a.slug -eq $slug) { continue }   # replaced by $entry below
  $h = [ordered]@{}
  foreach ($p in $a.PSObject.Properties) { $h[$p.Name] = $p.Value }
  $kept += ,$h
}
$kept += ,$entry

$out = [ordered]@{ owner = $cfg.owner; repo = $cfg.repo; apps = $kept }
$json = $out | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'apps.json'), $json + "`n")

# --- push ------------------------------------------------------------------
git add apps.json
git commit -m "Publish $Name v$Version" | Out-Null
git push | Out-Null
if (-not $?) { throw "git push failed. apps.json is committed locally; push manually." }

Write-Host ""
Write-Host "Done. Live in ~1 min at:" -ForegroundColor Green
Write-Host "  https://$($cfg.owner).github.io/$($cfg.repo)/"
