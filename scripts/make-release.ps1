<#
.SYNOPSIS
  Builds dist\cortex-one-<version>.zip from TRACKED files only (nothing from your machine's
  config, database, keys, .venv, build folders or untracked files) and prints size + SHA-256.
.DESCRIPTION
  Refuses to run when the tree has uncommitted changes (use -AllowDirty to override; the zip
  still contains only the committed versions of tracked files, taken with `git archive`)
  or when the secret scan finds anything. Supports -WhatIf.
.EXAMPLE
  .\scripts\make-release.ps1 -WhatIf
  .\scripts\make-release.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$AllowDirty,
    [string]$ProjectDir,
    [string]$OutDir
)
$ErrorActionPreference = 'Stop'
if (-not $ProjectDir) { $ProjectDir = Split-Path -Parent $PSScriptRoot }
Set-Location $ProjectDir
if (-not $OutDir) { $OutDir = Join-Path $ProjectDir 'dist' }

$py = Join-Path $ProjectDir '.venv\Scripts\python.exe'
if (-not (Test-Path $py)) { $py = (Get-Command python -ErrorAction Stop).Source }

$version = (& $py -c "from agent import __version__; print(__version__)").Trim()
if (-not $version) { throw 'could not read the version' }

$dirty = git status --porcelain --untracked-files=no
if ($dirty -and -not $AllowDirty) {
    throw "Uncommitted changes in tracked files. Commit them or pass -AllowDirty.`n$dirty"
}

& $py (Join-Path $PSScriptRoot 'precommit_check.py') --all
if ($LASTEXITCODE -ne 0) { throw 'The secret scan found problems. Nothing was packed.' }

# the agent and the phone app must carry the same version
$appVersion = ((Select-String -Path (Join-Path $ProjectDir 'mobile\pubspec.yaml') -Pattern '^version:\s*(\S+?)(\+\d+)?\s*$').Matches[0].Groups[1].Value)
if ($appVersion -ne $version) { throw "Version mismatch: agent $version, app $appVersion. Fix agent/__init__.py or mobile/pubspec.yaml." }

# the shared Cortex Wake test vectors must match their reference, and no firmware secret may be tracked
& $py (Join-Path $ProjectDir 'docs\cortex-wake\reference.py') --check
if ($LASTEXITCODE -ne 0) { throw 'docs/cortex-wake/test_vectors.json does not match reference.py. Nothing was packed.' }
$tracked = git ls-files
if ($tracked -match 'firmware/cortex-wake/include/secrets\.h$') { throw 'firmware secrets.h is tracked by git. Remove it from git. Nothing was packed.' }

$zip = Join-Path $OutDir "cortex-one-$version.zip"
Write-Host "Version : $version"
Write-Host "Output  : $zip"
Write-Host "Content : files tracked by git at HEAD (git archive)"
if ($PSCmdlet.ShouldProcess($zip, 'create release zip')) {
    New-Item -ItemType Directory -Force $OutDir | Out-Null
    if (Test-Path $zip) { Remove-Item $zip -Force }
    git archive --format=zip --prefix="cortex-one-$version/" -o $zip HEAD
    if ($LASTEXITCODE -ne 0) { throw 'git archive failed' }
    & $py (Join-Path $PSScriptRoot 'verify_release.py') $zip
    if ($LASTEXITCODE -ne 0) { Remove-Item $zip -Force; throw 'The release zip failed verification (secret/config/MAC). It was deleted.' }
    $size = (Get-Item $zip).Length
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    $count = (& $py -c "import zipfile,sys; print(len(zipfile.ZipFile(sys.argv[1]).namelist()))" $zip).Trim()
    Write-Host ("Files   : {0}" -f $count)
    $tops = (& $py -c "import zipfile,sys; print(' '.join(sorted({n.split('/')[1] for n in zipfile.ZipFile(sys.argv[1]).namelist() if n.count('/') > 1})))" $zip).Trim()
    Write-Host "Folders : $tops"
    Write-Host 'Reminder: the zip holds no config, tokens, keys, database, firmware secrets.h, PROGRESS.md or prompt files.'
    Write-Host ("Size    : {0:N0} bytes ({1:N1} KB)" -f $size, ($size / 1KB))
    Write-Host "SHA-256 : $hash"
}
else {
    Write-Host '(dry run: nothing was created)'
}
