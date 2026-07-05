@echo off
REM ============================================================================
REM  BeamMP COMBINED HOST  (host-and-play on one PC)
REM
REM  ONE process (BeamMP-Combined.exe --combined) runs the dedicated server
REM  IN-PROCESS and bridges THIS PC's game to it over an in-memory channel (no
REM  loopback launcher<->server socket). BeamNG itself still runs as a SEPARATE
REM  child process. Other players join this PC over the LAN as usual.
REM
REM  SETUP: drop this .bat, pin-cores.ps1, and BeamMP-Combined.exe together in
REM  your server folder (the one with ServerConfig.toml + Resources). This script
REM  cd's to its OWN folder (%~dp0), so no absolute paths to edit -- portable.
REM
REM  - Do NOT also run a standalone BeamMP-Server.exe: it would grab the port
REM    first. Combined mode IS the server.
REM  - To update: just replace BeamMP-Combined.exe. This .bat needs no change
REM    (the launcher does not self-rename in this fork).
REM
REM  PRIORITY: /high gives the relay a low-latency edge. BeamNG inherits /high
REM    too (fine for a foreground game). Remove /high for normal priority.
REM
REM  CPU PINNING (the host-side ghost-drift lever): the combined binary launches
REM    BeamNG as a child that INHERITS this process's affinity, so "/affinity"
REM    here would pin the GAME too. Instead pin-cores.ps1 (started below) waits
REM    for BeamNG's heavy "BeamNG.drive.x64" process, gives the game the low
REM    cores, and RESERVES the top core(s) for the relay/bridge -- so the relay
REM    stops time-slicing against the game's physics threads. Tune $Reserve in
REM    pin-cores.ps1 (default 2 logical processors; 1 on a small CPU).
REM ============================================================================
cd /d "%~dp0"
start "BeamMP Combined Host" /high "BeamMP-Combined.exe" --combined
start "" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pin-cores.ps1"
