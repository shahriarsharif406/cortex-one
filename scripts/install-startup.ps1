<#
.SYNOPSIS
  Registers a per-user Scheduled Task that starts Cortex One at logon.
  No admin rights needed. Hidden window. Restarts on failure.
.EXAMPLE
  .\scripts\install-startup.ps1 -WhatIf     # dry run: prints what it would do, changes nothing
  .\scripts\install-startup.ps1             # install
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ProjectDir = (Split-Path -Parent $PSScriptRoot),
    [string]$TaskName = 'CortexOneAgent'
)
$ErrorActionPreference = 'Stop'
$runScript = Join-Path $ProjectDir 'scripts\run-agent.ps1'
$user = "$env:USERDOMAIN\$env:USERNAME"
$arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runScript`""

Write-Host "Task name : $TaskName"
Write-Host "Runs as   : $user (limited rights, only while logged on)"
Write-Host "Trigger   : at logon of $user"
Write-Host "Command   : powershell.exe $arg"
Write-Host "Behaviour : hidden window, restart up to 5 times (1 min apart) if it fails, runs on battery"

if (-not (Test-Path $runScript)) { throw "run-agent.ps1 not found at $runScript" }

if ($PSCmdlet.ShouldProcess($TaskName, 'Register per-user scheduled task')) {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg -WorkingDirectory $ProjectDir
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Description 'Cortex One agent (starts at logon)' -Force | Out-Null
    Write-Host "Installed. It will start at your next logon. Start it now with: Start-ScheduledTask -TaskName $TaskName"
}
else {
    Write-Host '(dry run: nothing was changed)'
}
