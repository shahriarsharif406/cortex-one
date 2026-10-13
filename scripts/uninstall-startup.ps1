<#
.SYNOPSIS
  Removes the per-user Cortex One startup task (and stops it if running).
.EXAMPLE
  .\scripts\uninstall-startup.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$TaskName = 'CortexOneAgent'
)
$ErrorActionPreference = 'Stop'
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) {
    Write-Host "Task '$TaskName' is not installed. Nothing to do."
    return
}
Write-Host "Would stop and remove scheduled task '$TaskName' (state: $($task.State))."
if ($PSCmdlet.ShouldProcess($TaskName, 'Stop and unregister scheduled task')) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host 'Removed.'
}
else {
    Write-Host '(dry run: nothing was changed)'
}
