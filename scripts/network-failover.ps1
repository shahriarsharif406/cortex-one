<#
.SYNOPSIS
  OPTIONAL admin task (NOT the agent): when Wi-Fi has no internet for N minutes, switch to the SIM tether.
.DESCRIPTION
  Run by a SYSTEM scheduled task every minute (see install-network-failover.ps1). Fixed logic:
    * Wi-Fi up, internet unreachable for $FailMinutes checks in a row, tether adapter Up
        -> disable the Wi-Fi adapter so Windows uses the tether.
    * Right after disabling, if the tether has no internet either -> re-enable Wi-Fi at once and
      wait $CooldownMinutes before trying again (we never strand the computer with nothing).
    * While Wi-Fi is disabled by this task, every $RetestMinutes re-enable it for a short test; if
      internet works it stays on, otherwise it is disabled again.
  No value in this script comes from the network. Adapter names are fixed at install time
  and checked against a strict pattern. It writes only to its own log and state file.
  Every change honours -WhatIf.
.NOTES
  The agent runs as a normal user and cannot edit this file: the installer copies it to a folder
  only Administrators can write. See docs/THREAT_MODEL.md.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[\w .\-]{1,40}$')][string]$WifiAlias,
    [Parameter(Mandatory)][ValidatePattern('^[\w .\-]{1,40}$')][string]$TetherAlias,
    [ValidateRange(2, 120)][int]$FailMinutes = 5,
    [ValidateRange(5, 240)][int]$RetestMinutes = 15,
    [ValidateRange(5, 240)][int]$CooldownMinutes = 30,
    [string]$StateDir = (Join-Path $env:ProgramData 'CortexOne\failover')
)
$ErrorActionPreference = 'Stop'
$ProbeTargets = @(@('1.1.1.1', 443), @('8.8.8.8', 443))     # fixed IPs, no DNS needed
$statePath = Join-Path $StateDir 'state.json'
$logPath = Join-Path $StateDir 'failover.log'

function Write-Log([string]$msg) {
    if (-not (Test-Path $StateDir)) { return }
    $line = '{0} {1}' -f (Get-Date -Format 's'), $msg
    Add-Content -Path $logPath -Value $line -Encoding UTF8
    if ((Get-Item $logPath).Length -gt 200KB) { Move-Item $logPath "$logPath.old" -Force }
}

function Test-Internet {
    foreach ($t in $ProbeTargets) {
        $c = New-Object System.Net.Sockets.TcpClient
        try {
            $r = $c.BeginConnect($t[0], $t[1], $null, $null)
            if ($r.AsyncWaitHandle.WaitOne(3000) -and $c.Connected) { return $true }
        } catch { } finally { $c.Close() }
    }
    return $false
}

function Get-State {
    if (Test-Path $statePath) {
        try { return Get-Content $statePath -Raw | ConvertFrom-Json } catch { }
    }
    return [pscustomobject]@{ failCount = 0; disabledAt = $null; cooldownUntil = $null }
}
function Save-State($s) { $s | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8 }

if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force -WhatIf:$false | Out-Null }
$state = Get-State
$now = Get-Date
$wifi = Get-NetAdapter -Name $WifiAlias -ErrorAction SilentlyContinue
$tether = Get-NetAdapter -Name $TetherAlias -ErrorAction SilentlyContinue
if (-not $wifi) { Write-Log "Wi-Fi adapter '$WifiAlias' not found; nothing to do"; return }

if ($wifi.Status -eq 'Up') {
    if (Test-Internet) { $state.failCount = 0; Save-State $state; return }
    if ($state.cooldownUntil -and $now -lt [datetime]$state.cooldownUntil) { return }
    $state.failCount = [int]$state.failCount + 1
    Save-State $state
    if ($state.failCount -lt $FailMinutes) { return }
    if (-not $tether -or $tether.Status -ne 'Up') {
        Write-Log "Wi-Fi has no internet but the tether '$TetherAlias' is not Up; leaving Wi-Fi on"
        return
    }
    if ($PSCmdlet.ShouldProcess($WifiAlias, 'Disable Wi-Fi adapter (no internet, tether is up)')) {
        Disable-NetAdapter -Name $WifiAlias -Confirm:$false
        Write-Log "Disabled Wi-Fi '$WifiAlias' after $($state.failCount) failed checks"
        Start-Sleep -Seconds 20
        if (-not (Test-Internet)) {
            Enable-NetAdapter -Name $WifiAlias -Confirm:$false
            $state.cooldownUntil = $now.AddMinutes($CooldownMinutes).ToString('s')
            $state.disabledAt = $null
            $state.failCount = 0
            Write-Log 'Tether has no internet either; Wi-Fi re-enabled, cooling down'
        } else {
            $state.disabledAt = $now.ToString('s')
            Write-Log 'Using the tether now'
        }
        Save-State $state
    }
}
elseif ($wifi.Status -eq 'Disabled' -and $state.disabledAt) {
    # Only re-enable an adapter THIS task disabled (disabledAt is set), never one the user turned off.
    if ($now -lt ([datetime]$state.disabledAt).AddMinutes($RetestMinutes)) { return }
    if ($PSCmdlet.ShouldProcess($WifiAlias, 'Re-enable Wi-Fi for a connectivity test')) {
        Enable-NetAdapter -Name $WifiAlias -Confirm:$false
        Start-Sleep -Seconds 40
        if (Test-Internet) {
            $state.disabledAt = $null; $state.failCount = 0
            Write-Log 'Wi-Fi works again; staying on Wi-Fi'
        } else {
            Disable-NetAdapter -Name $WifiAlias -Confirm:$false
            $state.disabledAt = (Get-Date).ToString('s')
            Write-Log 'Wi-Fi still has no internet; back to the tether'
        }
        Save-State $state
    }
}
