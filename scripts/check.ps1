<#
.SYNOPSIS
  One command before a release or a long absence: tests + vectors + secret scan + doctor (+ Flutter).
.DESCRIPTION
  1. python -m pytest -q                         (agent, admin-script guards, Cortex Wake vectors ...)
  2. docs\cortex-wake\reference.py --check       (the shared BLE test vectors match the reference)
  3. firmware\cortex-wake\test\run_cpp_vectors.py (the C++ header, compiled to WebAssembly, passes the
     same vectors; SKIPPED (not a failure) when clang+wasm-ld or Node.js are missing)
  4. scripts\precommit_check.py --all            (API keys, secret files, random-looking tokens in tracked files)
  5. python -m agent.main doctor                 (setup check; WARN lines are normal, FAIL is not)
  6. flutter analyze + flutter test in mobile\   (skipped with -SkipFlutter or when Flutter is not found)
  Exit code 0 only when every step that ran passed. Never reads or prints keys or tokens.
  Nothing here shuts down, sleeps, locks or changes the network: the admin scripts are only parsed.
.EXAMPLE
  .\scripts\check.ps1
  .\scripts\check.ps1 -SkipTests      # skip pytest (and Flutter tests) for a quick scan
  .\scripts\check.ps1 -SkipFlutter
#>
[CmdletBinding()]
param(
    [switch]$SkipTests,
    [switch]$SkipFlutter,
    [string]$ProjectDir
)
$ErrorActionPreference = 'Continue'
if (-not $ProjectDir) { $ProjectDir = Split-Path -Parent $PSScriptRoot }
$py = Join-Path $ProjectDir '.venv\Scripts\python.exe'
if (-not (Test-Path $py)) { Write-Host "venv not found: $py" -ForegroundColor Red; exit 2 }
Set-Location $ProjectDir
$env:PYTHONIOENCODING = 'utf-8'
$failed = @()
$skipped = @()

function Step($name, [scriptblock]$body) {
    Write-Host "`n=== $name ===" -ForegroundColor Cyan
    & $body
    if ($LASTEXITCODE -ne 0) { Write-Host "FAILED: $name" -ForegroundColor Red; $script:failed += $name }
    else { Write-Host "OK: $name" -ForegroundColor Green }
}

if (-not $SkipTests) { Step 'tests (pytest)' { & $py -m pytest -q } }
else { Write-Host '(tests skipped)' -ForegroundColor Yellow }

Step 'Cortex Wake vectors match the reference (Python)' { & $py (Join-Path $ProjectDir 'docs\cortex-wake\reference.py') --check }

Write-Host "`n=== Cortex Wake vectors in the C++ header (WebAssembly) ===" -ForegroundColor Cyan
& $py (Join-Path $ProjectDir 'firmware\cortex-wake\test\run_cpp_vectors.py')
if ($LASTEXITCODE -eq 77) { Write-Host 'SKIPPED (no clang+wasm-ld or Node.js): the C++ header is NOT verified on this run' -ForegroundColor Yellow; $skipped += 'C++ vectors' }
elseif ($LASTEXITCODE -ne 0) { Write-Host 'FAILED: C++ vectors' -ForegroundColor Red; $failed += 'C++ vectors' }
else { Write-Host 'OK: C++ vectors' -ForegroundColor Green }

Step 'secret scan (tracked files)' { & $py (Join-Path $PSScriptRoot 'precommit_check.py') --all }
Step 'doctor' { & $py -m agent.main doctor }

# --- Flutter ---------------------------------------------------------------------------
$flutter = $null
foreach ($cand in @((Get-Command flutter -ErrorAction SilentlyContinue).Source, 'D:\flutter\bin\flutter.bat', 'D:\tools\flutter\bin\flutter.bat')) {
    if ($cand -and (Test-Path $cand)) { $flutter = $cand; break }
}
if ($SkipFlutter -or -not $flutter -or -not (Test-Path (Join-Path $ProjectDir 'mobile\pubspec.yaml'))) {
    Write-Host "`n(Flutter checks skipped)" -ForegroundColor Yellow
    $skipped += 'Flutter'
}
else {
    Push-Location (Join-Path $ProjectDir 'mobile')
    try {
        Step 'flutter analyze' { & $flutter analyze }
        if (-not $SkipTests) { Step 'flutter test' { & $flutter test } }
    }
    finally { Pop-Location }
}

Write-Host ''
if ($skipped.Count -gt 0) { Write-Host ("Skipped (not verified this run): " + ($skipped -join ', ')) -ForegroundColor Yellow }
if ($failed.Count -eq 0) { Write-Host 'ALL CHECKS PASSED' -ForegroundColor Green; exit 0 }
Write-Host ("FAILED: " + ($failed -join ', ')) -ForegroundColor Red
exit 1
