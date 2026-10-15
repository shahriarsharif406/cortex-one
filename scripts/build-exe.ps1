<#
.SYNOPSIS
  OPTIONAL: builds a single-folder Windows build of the agent with PyInstaller
  (dist\CortexOneAgent\CortexOneAgent.exe). Normal use does not need this; run-agent.ps1
  with the venv is the supported way. PyInstaller is a build tool only: it is not in
  requirements.txt and is never needed at run time.
.EXAMPLE
  .\scripts\build-exe.ps1 -WhatIf     # show what would happen
  .\scripts\build-exe.ps1
.NOTES
  The build contains no config, token, key or database. It reads %APPDATA%\CortexOne\config.json
  and ANTHROPIC_API_KEY at run time, exactly like the venv version.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ProjectDir = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'
$py = Join-Path $ProjectDir '.venv\Scripts\python.exe'
if (-not (Test-Path $py)) { throw "Python venv not found at $py (see README)." }

$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& $py -m PyInstaller --version *> $null
$haveIt = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = $prev
if (-not $haveIt) {
    Write-Host 'PyInstaller is not installed in this venv. To install it (build tool only, ~10 MB):'
    Write-Host "  $py -m pip install pyinstaller"
    Write-Host 'Then run this script again. Nothing was built.'
    exit 2
}

$entry = Join-Path $ProjectDir 'scripts\pyi_entry.py'
$pyiArgs = @(
    '-m', 'PyInstaller', '--noconfirm', '--clean', '--onedir', '--console',
    '--name', 'CortexOneAgent',
    '--distpath', (Join-Path $ProjectDir 'dist'),
    '--workpath', (Join-Path $ProjectDir 'build\pyi'),
    '--specpath', (Join-Path $ProjectDir 'build\pyi'),
    '--paths', $ProjectDir,
    '--collect-submodules', 'uvicorn',
    '--collect-submodules', 'agent',
    '--hidden-import', 'psutil',
    # heavy things the agent never needs
    '--exclude-module', 'tkinter', '--exclude-module', 'matplotlib', '--exclude-module', 'numpy',
    $entry
)
Write-Host "Python  : $py"
Write-Host "Command : python $($pyiArgs -join ' ')"
Write-Host "Output  : $(Join-Path $ProjectDir 'dist\CortexOneAgent')"

if ($PSCmdlet.ShouldProcess('dist\CortexOneAgent', 'Build with PyInstaller')) {
    & $py @args
    if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed with exit code $LASTEXITCODE" }
    Write-Host 'Built. Try: dist\CortexOneAgent\CortexOneAgent.exe doctor'
    Write-Host 'To start at logon with the exe, edit run-agent.ps1 to call it instead of python -m agent.main serve.'
}
else {
    Write-Host '(dry run: nothing was built)'
}


