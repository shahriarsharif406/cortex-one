<#
.SYNOPSIS
  Power settings for a laptop you control from a phone (admin, run once).
.DESCRIPTION
  - Lid close = do nothing (plugged in and on battery).
  - On mains (AC): never sleep, never turn the screen off by timeout.
  - Critical battery = hibernate (saves the session).
  - Power button = Sleep (default), Nothing or Hibernate. Used by the Cortex Wake servo:
    pressing the button on a running laptop then puts it to sleep instead of shutting it down.
  - -EnableHibernate also runs the Windows hibernate-enable command (needed for "hibernate").
  Everything is skipped with -WhatIf. Nothing is applied unless you run it yourself as Administrator.
.EXAMPLE
  .\scripts\set-power-plan.ps1 -WhatIf
  .\scripts\set-power-plan.ps1 -PowerButton Sleep -EnableHibernate
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Sleep', 'Nothing', 'Hibernate')][string]$PowerButton = 'Sleep',
    [switch]$EnableHibernate
)
$ErrorActionPreference = 'Stop'

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not $WhatIfPreference -and -not (Test-Admin)) { throw 'Run this in an Administrator PowerShell (or use -WhatIf).' }

$buttonValue = @{ Nothing = 0; Sleep = 1; Hibernate = 2 }[$PowerButton]

# Each step is [description, powercfg arguments]. The arguments are fixed text, not user input.
$steps = @(
    @('Lid close on AC = do nothing',            @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION', '0')),
    @('Lid close on battery = do nothing',       @('/setdcvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION', '0')),
    @("Power button on AC = $PowerButton",       @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'PBUTTONACTION', "$buttonValue")),
    @("Power button on battery = $PowerButton",  @('/setdcvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'PBUTTONACTION', "$buttonValue")),
    @('Critical battery action = hibernate',     @('/setdcvalueindex', 'SCHEME_CURRENT', 'SUB_BATTERY', 'BATACTIONCRIT', '2')),
    @('No sleep timeout on AC',                  @('/change', 'standby-timeout-ac', '0')),
    @('No screen-off timeout on AC',             @('/change', 'monitor-timeout-ac', '0'))
)
if ($EnableHibernate) { $steps += , @('Enable hibernate', @('/hibernate', 'on')) }
$steps += , @('Apply the plan', @('/setactive', 'SCHEME_CURRENT'))

foreach ($s in $steps) {
    Write-Host ("{0,-42} powercfg {1}" -f $s[0], ($s[1] -join ' '))
    if ($PSCmdlet.ShouldProcess('current power plan', $s[0])) {
        & powercfg.exe @($s[1])
        if ($LASTEXITCODE -ne 0) { Write-Warning "powercfg returned $LASTEXITCODE for: $($s[0])" }
    }
}
Write-Host ''
Write-Host 'Done. Check with: powercfg /query SCHEME_CURRENT SUB_BUTTONS' -ForegroundColor Green
Write-Host 'Remember: a laptop with the lid closed in a bag will run hot. Keep it ventilated.' -ForegroundColor Yellow
