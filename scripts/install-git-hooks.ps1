<#
.SYNOPSIS
  Installs the Cortex One pre-commit hook (secret scan) into a git repository.
.DESCRIPTION
  Copies scripts\hooks\pre-commit.template to <repo>\.git\hooks\pre-commit with the
  paths of this checkout filled in. Refuses to replace a hook it did not write unless
  -Force is given. Supports -WhatIf. Use -RepoPath to install into another repo
  (used by the tests).
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RepoPath,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$root    = Split-Path -Parent $PSScriptRoot
if (-not $RepoPath) { $RepoPath = $root }
$checker = (Join-Path $PSScriptRoot 'precommit_check.py') -replace '\\', '/'
$venvPy  = Join-Path $root '.venv\Scripts\python.exe'
$python  = if (Test-Path $venvPy) { $venvPy } else { (Get-Command python -ErrorAction Stop).Source }
$python  = $python -replace '\\', '/'

$gitDir = Join-Path $RepoPath '.git'
if (-not (Test-Path $gitDir -PathType Container)) { throw "Not a git repository: $RepoPath" }
$hooks = Join-Path $gitDir 'hooks'
$target = Join-Path $hooks 'pre-commit'
$marker = 'Cortex One pre-commit hook'

if ((Test-Path $target) -and -not $Force) {
    if (-not (Select-String -Path $target -Pattern $marker -Quiet)) {
        throw "A different pre-commit hook already exists at $target. Use -Force to replace it."
    }
}
$text = (Get-Content (Join-Path $PSScriptRoot 'hooks\pre-commit.template') -Raw -Encoding UTF8)
$text = $text.Replace('__PYTHON__', $python).Replace('__CHECKER__', $checker) -replace "`r`n", "`n"

if ($PSCmdlet.ShouldProcess($target, 'write pre-commit hook')) {
    New-Item -ItemType Directory -Force $hooks | Out-Null
    [System.IO.File]::WriteAllText($target, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Installed: $target"
    Write-Host "It blocks: sk-ant- keys, .env, config.json, key.properties, keystores, 32+ char random tokens."
}
