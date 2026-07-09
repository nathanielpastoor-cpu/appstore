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

# Windows PowerShell 5.1 wraps a native command's stderr in ErrorRecords and,
# under $ErrorActionPreference='Stop', promotes them to terminating errors even
# when the command exited 0. gh and git both write routine progress to stderr,
# so run them through here: relax the preference for the call and branch on the
# real exit code ($LASTEXITCODE) instead of $?.
function Invoke-Native {
  param(
    [Parameter(Mandatory)][string]$File,
    [string[]]$Arguments = @(),
    [switch]$Quiet
  )
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($Quiet) { & $File @Arguments 2>&1 | Out-Null }
    else        { & $File @Arguments 2>&1 | ForEach-Object { Write-Host $_ } }
  } finally {
    $ErrorActionPreference = $prev
  }
  return $LASTEXITCODE
}

# --- preflight -------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Apk)) { throw "APK not found: $Apk" }
if ($Version -notmatch '^\d+\.\d+(\.\d+)?$') { throw "Version must look like 1.2 or 1.2.3 (got '$Version')" }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "GitHub CLI 'gh' is not installed." }

if ((Invoke-Native gh @('auth','status') -Quiet) -ne 0) { throw "Not logged in to GitHub. Run: gh auth login" }

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
if ((Invoke-Native gh @('release','view',$tag) -Quiet) -eq 0) { throw "Release '$tag' already exists. Bump -Version, or delete it: gh release delete $tag --cleanup-tag" }

# gh names the asset after the file, so stage a copy under the public name.
New-Item -ItemType Directory -Force -Path $assetDir | Out-Null
Copy-Item -LiteralPath $Apk -Destination $assetPath -Force

$file   = Get-Item -LiteralPath $assetPath
$size   = [int64]$file.Length
$sha256 = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
$today  = (Get-Date).ToString('yyyy-MM-dd')

# Best-effort: read the Android applicationId from the APK via aapt so the
# storefront's Obtainium button can identify the app. Empty if aapt isn't found
# (the storefront falls back to a repo+slug id); never fatal.
$appId = ''
try {
  $sdk = if ($env:ANDROID_HOME)     { $env:ANDROID_HOME }
         elseif ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT }
         else { @("$env:LOCALAPPDATA\Android\Sdk", "$env:USERPROFILE\android-sdk") |
                Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1 }
  if ($sdk) {
    $aapt = Get-ChildItem -LiteralPath (Join-Path $sdk 'build-tools') -Filter 'aapt.exe' -Recurse -ErrorAction SilentlyContinue |
            Sort-Object FullName | Select-Object -Last 1
    if ($aapt) {
      $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      $badging = & $aapt.FullName dump badging $assetPath 2>$null
      $ErrorActionPreference = $eap
      $m = [regex]::Match(($badging -join "`n"), "package: name='([^']+)'")
      if ($m.Success) { $appId = $m.Groups[1].Value }
    }
  }
} catch { $appId = '' }

Write-Host "Publishing $Name v$Version" -ForegroundColor Cyan
Write-Host "  asset  $assetName  ($([math]::Round($size/1MB,1)) MB)"
Write-Host "  sha256 $sha256"
if ($appId) { Write-Host "  appId  $appId" }

# --- upload ----------------------------------------------------------------
$releaseNotes = if ($Notes) { $Notes } else { "$Name v$Version" }
$rc = Invoke-Native gh @('release','create',$tag,$assetPath,'--title',"$Name v$Version",'--notes',$releaseNotes)
if ($rc -ne 0) { throw "gh release create failed." }

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
  appId     = $appId
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
Invoke-Native git @('add','apps.json') | Out-Null
Invoke-Native git @('commit','-m',"Publish $Name v$Version") -Quiet | Out-Null
if ((Invoke-Native git @('push')) -ne 0) { throw "git push failed. apps.json is committed locally; push manually." }

Write-Host ""
Write-Host "Done. Live in ~1 min at:" -ForegroundColor Green
Write-Host "  https://$($cfg.owner).github.io/$($cfg.repo)/"
