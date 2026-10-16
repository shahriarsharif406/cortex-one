<#
.SYNOPSIS
  One command before a release or a long absence: tests + secret scan + doctor.
.DESCRIPTION
  1. python -m pytest -q
  2. scripts\precommit_check.py --all   (API keys, secret files, random-looking tokens in tracked files)
  3. python -m agent.main doctor        (setup check; WARN lines are normal, FAIL is not)
  Exit code 0 only when all three pass. Never reads or prints keys or tokens.
.EXAMPLE
  .\scripts\check.ps1
  .\scripts\check.ps1 -SkipTests      # secret scan + doctor only
#>
[CmdletBinding()]
param(
    [switch]$SkipTests,
    [string]$ProjectDir
)
$ErrorActionPreference = 'Continue'
if (-not $ProjectDir) { $ProjectDir = Split-Path -Parent $PSScriptRoot }
$py = Join-Path $ProjectDir '.venv\Scripts\python.exe'
if (-not (Test-Path $py)) { Write-Host "venv not found: $py" -ForegroundColor Red; exit 2 }
Set-Location $ProjectDir
$env:PYTHONIOENCODING = 'utf-8'
$failed = @()

function Step($name, [scriptblock]$body) {
    Write-Host "`n=== $name ===" -ForegroundColor Cyan
    & $body
    if ($LASTEXITCODE -ne 0) { Write-Host "FAILED: $name" -ForegroundColor Red; $script:failed += $name }
    else { Write-Host "OK: $name" -ForegroundColor Green }
}

if (-not $SkipTests) { Step 'tests (pytest)' { & $py -m pytest -q } }
else { Write-Host '(tests skipped)' -ForegroundColor Yellow }
Step 'secret scan (tracked files)' { & $py (Join-Path $PSScriptRoot 'precommit_check.py') --all }
Step 'doctor' { & $py -m agent.main doctor }

Write-Host ''
if ($failed.Count -eq 0) { Write-Host 'ALL CHECKS PASSED' -ForegroundColor Green; exit 0 }
Write-Host ("FAILED: " + ($failed -join ', ')) -ForegroundColor Red
exit 1
