<#
.SYNOPSIS
  Starts the Cortex One agent (serve). Logs go to %APPDATA%\CortexOne\logs\agent.log
  (rotating, secrets scrubbed) by the agent itself; this script only adds start/exit lines.
.NOTES
  The ANTHROPIC_API_KEY is read from the environment by the agent. This script never
  reads, prints or stores it.
#>
[CmdletBinding()]
param(
    [string]$ProjectDir = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'
$py = Join-Path $ProjectDir '.venv\Scripts\python.exe'
if (-not (Test-Path $py)) { throw "Python venv not found at $py. Run: python -m venv .venv; .venv\Scripts\pip install -r requirements.txt" }

$dataDir = if ($env:APPDATA) { Join-Path $env:APPDATA 'CortexOne' } else { Join-Path $HOME '.cortex-one' }
$logDir = Join-Path $dataDir 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$launchLog = Join-Path $logDir 'launcher.log'
# keep the launcher log small (the agent log rotates itself)
if ((Test-Path $launchLog) -and ((Get-Item $launchLog).Length -gt 200KB)) {
    Move-Item -Force $launchLog "$launchLog.1"
}

Set-Location $ProjectDir
Add-Content $launchLog "$(Get-Date -Format s) starting agent"
& $py -m agent.main serve
Add-Content $launchLog "$(Get-Date -Format s) agent exited with code $LASTEXITCODE"
exit $LASTEXITCODE
