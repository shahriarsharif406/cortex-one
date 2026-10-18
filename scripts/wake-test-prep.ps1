<#
 Cortex One - checks to confirm BEFORE a wake-from-Sleep test. READ-ONLY: it changes nothing.
 Run:  powershell -ExecutionPolicy Bypass -File scripts\wake-test-prep.ps1
 It never prints MAC addresses (look them up yourself: Get-NetAdapter, on this computer only).
#>
$ErrorActionPreference = 'Continue'
function Say($t) { Write-Host $t }

Say "== 1. Fast Startup (should be OFF for a clean wake test) =="
try {
    $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction Stop).HiberbootEnabled
    if ($v -eq 1) { Say "Fast Startup: ON (turn it off: Control Panel > Power Options > Choose what the power buttons do)" }
    else { Say "Fast Startup: OFF" }
} catch { Say "Fast Startup: unknown (could not read)" }

Say ""
Say "== 2. Devices allowed to wake the PC (powercfg /devicequery wake_armed) =="
powercfg /devicequery wake_armed

Say ""
Say "== 3. Adapter link state =="
try {
    Get-NetAdapter -Physical | Select-Object Name, InterfaceDescription, Status, LinkSpeed | Format-Table -AutoSize | Out-String | Write-Host
} catch { Say "Get-NetAdapter not available" }
Say "A cable that is unplugged or Wi-Fi that is off cannot receive a wake packet."

Say ""
Say "== 4. Power plan: lid close and sleep settings =="
powercfg /query SCHEME_CURRENT SUB_BUTTONS 2>$null | Select-String -Pattern 'Lid close action|Power Setting Index|Current AC|Current DC' | ForEach-Object { $_.Line.Trim() }
powercfg /query SCHEME_CURRENT SUB_SLEEP 2>$null | Select-String -Pattern 'Sleep after|Hibernate after|Current AC|Current DC' | ForEach-Object { $_.Line.Trim() }

Say ""
Say "== 5. Reminders you must check yourself =="
Say "- BIOS (F10 on HP): Wake on LAN / WLAN options enabled."
Say "- Device Manager > network adapter > Power Management: 'Allow this device to wake the computer' and 'Only allow a magic packet' ticked."
Say "- Laptop on mains with a charged battery. Use Sleep from the Start menu, NOT Shutdown or Hibernate."
Say "- The phone WoL app must be on the SAME Wi-Fi/LAN as the laptop."
Say "- This is a test: Wi-Fi magic-packet wake is often unreliable, Ethernet is better."
