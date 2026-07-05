# =============================================================================
#  BeamMP combined-host CPU pinning (called by start-server.bat).
#
#  WHY a script (not /affinity in the .bat): the combined binary launches BeamNG
#  as a CHILD that INHERITS the parent's CPU affinity, so pinning the combined
#  process at launch would pin (cripple) the game too. Instead we wait for BeamNG
#  to start, then set both affinities directly so the server-relay / in-memory
#  bridge gets dedicated cores the game won't touch -- this is what cuts the
#  host-side ghost drift (relay no longer time-slices against the game's physics).
#
#  IMPORTANT process-name note: BeamNG launches a small loader "BeamNG.drive.exe"
#  which then spawns the HEAVY game as "BeamNG.drive.x64.exe" (process name
#  "BeamNG.drive.x64"), often alongside several x64 worker processes. We must pin
#  the x64 process(es) -- pinning only "BeamNG.drive" (the loader) does nothing
#  useful and leaves the actual game running across ALL cores. So we WAIT for
#  "BeamNG.drive.x64" and pin every "BeamNG.drive*" process.
#
#  Tune $Reserve below: logical processors handed to the combined process (server
#  relay + bridge + launcher). 2 is a good start on 8+ threads; raise it if the
#  server's still squeezed, lower to 1 on a small CPU.
# =============================================================================

$Reserve = 2

$total = [int]$env:NUMBER_OF_PROCESSORS
if ($total -le 2) { return }                 # too few cores to bother splitting
if ($total -le 4) { $Reserve = 1 }           # small CPU: reserve just one
if ($Reserve -ge $total) { $Reserve = 1 }    # never starve the game

$gameCount = $total - $Reserve
$gameMask  = ([int64]1 -shl $gameCount) - 1                          # low cores  -> BeamNG
$allMask   = ([int64]1 -shl $total) - 1
$relayMask = $allMask -band (-bnot $gameMask)                        # top cores  -> combined host

# Wait for the HEAVY game process (BeamNG.drive.x64), not the loader, up to ~120s.
$bng = $null
for ($i = 0; $i -lt 240; $i++) {
    $bng = Get-Process 'BeamNG.drive.x64' -ErrorAction SilentlyContinue
    if ($bng) { break }
    Start-Sleep -Milliseconds 500
}
if (-not $bng) { return }                    # game never launched; leave defaults

# Apply in two passes a few seconds apart: BeamNG keeps spawning x64 workers during
# load, and a child spawned AFTER its parent is pinned inherits the parent's mask,
# so a second pass catches any that started before the first pass ran.
for ($pass = 0; $pass -lt 2; $pass++) {
    Start-Sleep -Seconds 2
    # Pin EVERY BeamNG process (loader "BeamNG.drive" + all "BeamNG.drive.x64" workers)
    # to the low game cores. Wildcard matches both names.
    foreach ($p in Get-Process 'BeamNG.drive*' -ErrorAction SilentlyContinue) {
        try { $p.ProcessorAffinity = [IntPtr]$gameMask } catch { }
    }
    # Reserve the top core(s) for the combined host (server relay + in-memory bridge).
    foreach ($p in Get-Process 'BeamMP-Combined' -ErrorAction SilentlyContinue) {
        try { $p.ProcessorAffinity = [IntPtr]$relayMask } catch { }
    }
}
