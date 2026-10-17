<#
.SYNOPSIS
  Install (or remove) the optional Wi-Fi -> SIM-tether failover task. Run as Administrator.
.DESCRIPTION
  Copies network-failover.ps1 to %ProgramData%\CortexOne\failover\ and makes that folder
  writable ONLY by Administrators and SYSTEM (ordinary users, and therefore the Cortex One agent
  and anything it could be tricked into running, can read but not change it). Then registers a
  SYSTEM scheduled task 'CortexOneNetFailover' that runs it every minute with the adapter names
  you give here. The agent never touches this task.
  -WhatIf prints the plan and changes nothing. -Remove deletes the task (and re-enables Wi-Fi
  if you also pass -WifiAlias).
.EXAMPLE
  .\scripts\install-network-failover.ps1 -WifiAlias 'Wi-Fi' -TetherAlias 'Ethernet 2' -WhatIf
  .\scripts\install-network-failover.ps1 -WifiAlias 'Wi-Fi' -TetherAlias 'Ethernet 2'
  .\scripts\install-network-failover.ps1 -Remove -WifiAlias 'Wi-Fi'
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidatePattern('^[\w .\-]{1,40}$')][string]$WifiAlias,
    [ValidatePattern('^[\w .\-]{1,40}$')][string]$TetherAlias,
    [ValidateRange(2, 120)][int]$FailMinutes = 5,
    [switch]$Remove,
    [string]$TaskName = 'CortexOneNetFailover'
)
$ErrorActionPreference = 'Stop'
$dest = Join-Path $env:ProgramData 'CortexOne\failover'
$src = Join-Path $PSScriptRoot 'network-failover.ps1'

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not $WhatIfPreference -and -not (Test-Admin)) { throw 'Run this in an Administrator PowerShell (or use -WhatIf).' }

if ($Remove) {
    Write-Host "Removing scheduled task $TaskName"
    if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister scheduled task')) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($WifiAlias -and $PSCmdlet.ShouldProcess($WifiAlias, 'Enable Wi-Fi adapter')) {
        Enable-NetAdapter -Name $WifiAlias -Confirm:$false -ErrorAction SilentlyContinue
    }
    return
}
if (-not $WifiAlias -or -not $TetherAlias) { throw 'Give -WifiAlias and -TetherAlias (see Get-NetAdapter).' }
if ($WifiAlias -eq $TetherAlias) { throw 'Wi-Fi and tether must be different adapters.' }
if (-not (Test-Path $src)) { throw "network-failover.ps1 not found at $src" }

$script = Join-Path $dest 'network-failover.ps1'
$arg = "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -WifiAlias `"$WifiAlias`" -TetherAlias `"$TetherAlias`" -FailMinutes $FailMinutes"
Write-Host "Task name : $TaskName (runs as SYSTEM, every minute)"
Write-Host "Script    : $script (Administrators/SYSTEM can write; Users read-only)"
Write-Host "Command   : powershell.exe $arg"
Write-Host "Rule      : no internet on Wi-Fi for $FailMinutes min AND tether is Up -> disable Wi-Fi; retest every 15 min"

if ($PSCmdlet.ShouldProcess($dest, 'Create folder, copy script, lock permissions')) {
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item -Path $src -Destination $script -Force
    # remove inherited rights, then grant: SYSTEM + Administrators full, Users read and execute
    & icacls.exe $dest /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
}
if ($PSCmdlet.ShouldProcess($TaskName, 'Register SYSTEM scheduled task')) {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Description 'Cortex One optional Wi-Fi to SIM failover (not the agent)' -Force | Out-Null
    Write-Host ('Installed. Log: ' + (Join-Path $dest 'failover.log'))
}
else { Write-Host '(dry run: nothing was changed)' }
