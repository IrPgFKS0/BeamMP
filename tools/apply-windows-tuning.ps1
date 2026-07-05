<#
  BeamMP LAN - Windows tuning (run as Administrator)
  Applies the LAN-TUNING.md Windows items. All changes are reversible.
  Right-click -> "Run with PowerShell" as admin, OR from an elevated PowerShell:
      Set-ExecutionPolicy -Scope Process Bypass -Force ; .\apply-windows-tuning.ps1

  NOTE: none of this fixes the map-load CRASH -- that's a BeamNG engine limit hit by
  too-large a mod set (see LAN-TUNING.md Tier 0). These help the position-sync/perf side.
#>
$ErrorActionPreference = 'Continue'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This must be run as Administrator. Re-launching elevated..." -ForegroundColor Yellow
    Start-Process powershell "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    return
}

Write-Host "=== BeamMP LAN Windows tuning ===" -ForegroundColor Cyan

# 1. Power plan -> High performance (Ultimate if available)
$ultimate = powercfg /list | Select-String 'Ultimate'
if ($ultimate -and "$ultimate" -match '([0-9a-f-]{36})') { powercfg /setactive $Matches[1]; Write-Host "[1] Power plan -> Ultimate Performance" }
else { powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c; Write-Host "[1] Power plan -> High performance" }

# 2. Multimedia profile: disable the network throttle + lower the background reservation
$mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
New-ItemProperty -Path $mm -Name NetworkThrottlingIndex -Value 0xffffffff -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $mm -Name SystemResponsiveness   -Value 10         -PropertyType DWord -Force | Out-Null
Write-Host "[2] NetworkThrottlingIndex=disabled, SystemResponsiveness=10"

# 3. Physical NIC: disable interrupt moderation + energy saving, max the ring buffers
$nic = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
if ($nic) {
    Write-Host "[3] NIC: $($nic.Name) ($($nic.InterfaceDescription))"
    $props = Get-NetAdapterAdvancedProperty -Name $nic.Name -ErrorAction SilentlyContinue
    function SetTo($match, $val) {
        $found = $props | Where-Object DisplayName -match $match   # set ALL matches (e.g. both "Energy-Efficient Ethernet" AND "Green Ethernet")
        foreach ($p in $found) { try { Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $p.DisplayName -DisplayValue $val -ErrorAction Stop; Write-Host "     $($p.DisplayName) -> $val" } catch { Write-Host "     (skip) $($p.DisplayName): $($_.Exception.Message)" -ForegroundColor DarkGray } }
    }
    function SetMax($match) {
        $p = $props | Where-Object DisplayName -match $match | Select-Object -First 1
        if (-not $p) { return }
        if ($p.ValidDisplayValues) {
            $max = $p.ValidDisplayValues | Sort-Object { [int]($_ -replace '\D','0') } -Descending | Select-Object -First 1
            try { Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $p.DisplayName -DisplayValue $max -ErrorAction Stop; Write-Host "     $($p.DisplayName) -> $max (max)" } catch { Write-Host "     (skip) $($p.DisplayName): $($_.Exception.Message)" -ForegroundColor DarkGray }
        } else {
            Write-Host "     $($p.DisplayName) = '$($p.DisplayValue)' (numeric, no preset list; raise in Device Manager if you want)" -ForegroundColor DarkGray
        }
    }
    SetTo 'Interrupt Moderation' 'Disabled'
    SetTo 'Energy.Efficient Ethernet|Green Ethernet|EEE' 'Disabled'
    SetTo 'Flow Control' 'Disabled'
    SetMax 'Receive Buffers'
    SetMax 'Transmit Buffers'
} else { Write-Host "[3] No physical NIC found 'Up' -- skipping NIC tuning" -ForegroundColor Yellow }

Write-Host ""
Write-Host "Done. NetworkThrottlingIndex + SystemResponsiveness take effect after a reboot." -ForegroundColor Green
Write-Host "To revert: set NetworkThrottlingIndex=10, SystemResponsiveness=20, and re-enable the NIC items in Device Manager." -ForegroundColor DarkGray