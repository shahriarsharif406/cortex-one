<#
.SYNOPSIS
  Make Wi-Fi the preferred internet link and the SIM / USB-tether link a backup (admin, run once).
.DESCRIPTION
  1. Prints Get-NetIPInterface (read-only) so you can see the adapter names.
  2. Asks for the Wi-Fi adapter alias and the SIM/tether adapter alias (or pass -WifiAlias / -TetherAlias).
  3. Turns off "automatic metric" on both and sets Wi-Fi metric 10, tether metric 50
     (lower number = preferred), so Windows only uses the tether when Wi-Fi has no route.
  Nothing is changed with -WhatIf. Nothing is changed unless you answer both names and run as Administrator.
  This does NOT disable any adapter (that is the optional, separate scripts\network-failover.ps1).
.EXAMPLE
  .\scripts\setup-network-priority.ps1 -WhatIf
  .\scripts\setup-network-priority.ps1 -WifiAlias 'Wi-Fi' -TetherAlias 'Ethernet 2'
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$WifiAlias,
    [string]$TetherAlias,
    [ValidateRange(1, 9999)][int]$WifiMetric = 10,
    [ValidateRange(1, 9999)][int]$TetherMetric = 50
)
$ErrorActionPreference = 'Stop'

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Write-Host 'Current IPv4 interfaces (read-only):' -ForegroundColor Cyan
Get-NetIPInterface -AddressFamily IPv4 | Sort-Object InterfaceMetric |
    Format-Table InterfaceAlias, InterfaceMetric, AutomaticMetric, ConnectionState -AutoSize | Out-Host

if (-not $WifiAlias)   { $WifiAlias   = Read-Host 'Wi-Fi adapter alias (the InterfaceAlias above)' }
if (-not $TetherAlias) { $TetherAlias = Read-Host 'SIM / USB-tether adapter alias' }
foreach ($a in @($WifiAlias, $TetherAlias)) {
    if ($a -notmatch '^[\w .\-]{1,40}$') { throw "Adapter name '$a' has unusual characters; refusing." }
    if (-not (Get-NetIPInterface -InterfaceAlias $a -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        throw "No IPv4 interface named '$a'. Plug in the tether first, then run again."
    }
}
if ($WifiAlias -eq $TetherAlias) { throw 'Wi-Fi and tether must be different adapters.' }
if ($WifiMetric -ge $TetherMetric) { throw 'The Wi-Fi metric must be lower than the tether metric.' }
if (-not $WhatIfPreference -and -not (Test-Admin)) { throw 'Run this in an Administrator PowerShell (or use -WhatIf).' }

if ($PSCmdlet.ShouldProcess($WifiAlias, "Set interface metric $WifiMetric (automatic metric off)")) {
    Set-NetIPInterface -InterfaceAlias $WifiAlias -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric $WifiMetric
}
if ($PSCmdlet.ShouldProcess($TetherAlias, "Set interface metric $TetherMetric (automatic metric off)")) {
    Set-NetIPInterface -InterfaceAlias $TetherAlias -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric $TetherMetric
}
Write-Host ''
Write-Host "Wi-Fi '$WifiAlias' = metric $WifiMetric (preferred), tether '$TetherAlias' = metric $TetherMetric (backup)." -ForegroundColor Green
Write-Host 'To undo: Set-NetIPInterface -InterfaceAlias <name> -AutomaticMetric Enabled' -ForegroundColor Yellow
