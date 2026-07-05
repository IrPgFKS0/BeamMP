-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

--- MPCoreNetwork API. Handles Main Launcher <-> Game Network. Version Check, Server list transfer, login, connect to X server, quiting a server etc.
--- Author of this documentation is Titch
--- @module MPCoreNetwork
--- @usage connectToLauncher() -- internal access
--- @usage MPCoreNetwork.connectToLauncher() -- external access


local M = {}

local ffi = require("ffi")


-- VV============= VARIABLES =============VV
-- launcher
local TCPLauncherSocket = nop -- Launcher socket
local socket = require('socket')
local http = require("socket.http")
local ltn12 = require("ltn12")
local launcherConnected = false
local isConnecting = false
local proxyPort = ""
local socketPartialData
local launcherVersion = "" -- used only for the server list
-- LAN fork display version. BUMP the pN every time BeamMP.zip is rebuilt so the loaded build
-- is identifiable in-game (bottom info bar) AND in the console (logged at connect). This is
-- DISPLAY ONLY -- never sent to the server (the join handshake checks the launcher version),
-- so changing it can't cause a version-mismatch kick. Versioning: pNN is the feature level,
-- hN is the hotfix number within it -- bump hN on every post-release fix (no date needed).
local modVersion = "4.21.1-LAN p13h52"
-- One-line summary of what this build contains; logged at startup next to the version.
local modPatchNote = "p13h52 (pairs combined exe p13h32, unchanged): FULL-DEFORMATION + WEAPONS-PROJECTILE audit fixes. (1) nodesVE: the syncFullDeformation apply now carries+checks nodeCount/beamCount -- a 2Hz snapshot serialized before the owner EDITED/swapped their vehicle could arrive after the ghost's reload and feed out-of-range cids straight into engine calls (setNodePosition/breakBeam); a mismatched snapshot is stale by definition and is skipped (the next one <=0.5s matches). Fork-internal wire addition (both ends ship in this zip; old packets without counts still apply). (2) MPGameNetwork.sendData FRAME-INTEGRITY rework: a partial send must COMPLETE or the socket must CLOSE -- the 4-byte length header is already on the wire, so the old bounded 1-retry could abandon mid-frame and permanently corrupt the game<->launcher stream framing (realistic trigger: the ~100KB deformation snapshot or a large vehicle-config spawn needing several send() calls). Now: retry while progress; zero-progress allowed a 0.25s window (launcher mid-hitch), then clean disconnect (beats both the pre-fork infinite GE freeze and the bounded-retry corruption). Weapons audit verdict: remoteFullProjectiles chain (MPConfig -> UI -> MPWeaponsGE.handleFire -> uw_fullProjectiles -> fireOneRound lightOnly) verified correct incl. ghost recoil suppression + owner-authoritative blasts; leftover p13h38 uwVeDiag per-shot log in UniversalWeapons.zip flagged for a separate mod repack (not in this repo). p13h51 (pairs combined exe p13h32): UPSTREAM SYNC -- merged BeamMP/BeamMP@c6053fc 'Switched to batch based mod loading' (#893): loadServerMods now mounts synced mods in batches of 5 inside a core_jobsystem job (yielding between batches) instead of all at once -- fixes an upstream-reported BeamNG crash when overloaded by many mod updates and reduces the join-time hitch; directly relevant to this fork's large synced mod set. The fork never modified loadServerMods, so the merge was clean; requestMap still fires after ALL mods are mounted (now a few frames later, async). SERVER: merged BeamMP-Server@176de6b 'BEAMMP_MAX_CONCURRENT_CONNECTIONS env var' (#496) -- per-IP connection-attempt limit configurable via env var; INERT by default (stays 10) and the combined host's virtual client bypasses the accept path, so LAN behavior is unchanged; combined exe rebuilt as p13h32 (Windows; Linux binaries pending a docker rebuild). p13h50 (pairs combined exe p13h31 -- still compatible with p13h32, the exe change is inert): GHOST-FREEZE TRUE ROOT CAUSE -- freeze-after-EDIT flag wipe -- + weapon-vehicle fake-drift metric fix. CORRECTS p13h49's sleep diagnosis: the dual-log pair (host 17:52 + LAN2 17:51) shows every freeze starts at 'applyVehEdit Updating vehicle ...' (the owner swapped vehicle/config: LAN2 froze Dad's ghost at BOTH his 335s Chiron->B25 and 554s B25->ultrabump swaps; the 17:21 'sleep' freeze also began at a 661s edit) and every recovery at an unrelated SETTINGS change. MECHANISM: an edit reloads the ghost's VE VM IN PLACE (same object id) wiping every VE-side flag to default, and applyPos's one-time setup never re-fires (gated on veh.mpVehicleType==nil, which persists on the GE object wrapper) -> with mailboxApplyPos on, GE keeps writing a mailbox the fresh VM never polls (the 17:51 stall log: mailbox version frozen at v1229) = PERMANENT freeze until refreshFlags happens to run. Also hit the OWN car: a reloaded own VM fell back to the VE-default 100Hz SEND_INTERVAL (the relay-overload rate) until the next settings change. FIX: positionVE.onInit announces every VM (re)load to GE (positionGE.veReady) which re-pushes ALL per-vehicle flags (mailbox/profiling/stall-diag/sendHz) and, for remote vehicles, re-arms type 'R' + the anti-sleep (new positionVE.setRemote; the h49 first-packet arm can't fire when the mailbox flag itself was wiped). The h49 anti-sleep stays as defense-in-depth. SECOND FIX (watchdog/overlay honesty): the drift metric compared rxPos to the OOBB CENTER only (p13h27 long-vehicle fix) -- but weapon-mod vehicles that fire NODE projectiles (turretsystem, tank bllt guns) stretch the OOBB hundreds of meters, so a HEALTHY turret ghost applying a steady 30/s read as a constant '170m of drift' on the host overlay, and on LAN2 the watchdog could false-heal a healthy ghost by the OOBB error (throwing it hundreds of meters = a visible warp). Now BOTH anchors (refNode + OOBB center) are measured and the one closer to rxPos is used (long vehicles keep the p13h27 behavior via the OOBB anchor, weapon vehicles get the refNode anchor); 'moved' tracks the refNode (immune to flung nodes); a truly frozen ghost is far on both anchors so detection/heal is unchanged. Overlay drift + /synclog inherit the correction. p13h49 (pairs combined exe p13h31, unchanged): GHOST PHYSICS-SLEEP freeze FIX -- the long-standing intermittent 'apply stalled / recv+0' ghost freeze is ROOT-CAUSED and fixed. Live log (2026-07-04 17:21 host bundle): ghost 0-0 applied 60/s for 5min (peaks ~1m), owner PARKED ~70s, the stationary ghost hit BeamNG's vehicle physics-SLEEP -- the engine stops calling a sleeping vehicle's updateGFX entirely -- and since the mailbox apply is a PULL from updateGFX, the sleeping ghost could never apply again: when the owner drove off, GE kept receiving 10/s for 110s while the ghost VM ran ZERO frames; the watchdog snapped it 24x (24-103m) without ever waking it, until physics happened to rouse it. NOT a p13h48 regression (nothing was removed; the blind spot shipped with mailboxApplyPos in p13) -- the trigger is park-a-while-then-drive-off. FIX (positionVE.setVehiclePosRot): on the FIRST received packet (vehicle guaranteed awake post-spawn) the ghost calls obj:setSleepingEnabled(false) -- the same API BeamNG's own playerController uses -- so a ghost can never doze; re-armed after onReset. Cost: parked ghosts keep simulating (no sleep CPU saving) -- correct behavior for a synced vehicle, matches the pre-mailbox era where the per-packet queueLuaCommand stream kept ghosts awake. ALSO from this log: physRateSendHz=10 sits exactly AT the predictor's 0.1s packetTimeout (updateGFX.stale 2-4/s = the predictor idles between 100ms-apart packets -> steppy ghosts even when healthy). RECOMMENDATION: run 30Hz (the default) on ALL machines; 10Hz is stock-parity but starves the fork's predictor timing. p13h48 (pairs combined exe p13h31, unchanged): SENDER-CLOCK-RESET ghost-freeze fixes -- closes the 'reject+N' stall the p13h43 posApplyStall diagnostic names ('packets REJECTED out-of-order at the tim guard'). (1) positionVE.armSelfSend: the self-send wire clock now resyncs FORWARD-ONLY (max(sendClock, timer)) on a re-arm. The physics thread keeps stepping during a GE hitch, so sendClock runs AHEAD of the frame-driven timer; the old 'sendClock = timer' re-arm after a >0.5s hitch jumped our wire time BACKWARD, making every receiver reject our packets until its clock caught up = our ghost froze on all other machines for the jump duration. (2) positionVE.setVehiclePosRot: a >3s BACKWARD jump in the sender's clock (vehicle Lua reload / clock re-base; same 3s reset rule the GE smoother has always had) now RE-BASES the predictor on the new packet (deltas zeroed, no acc spike; the timeOffset jump guard snaps the time smoother) instead of rejecting every future packet -- previously such a ghost froze until a manual reset, with only the 1Hz watchdog snap papering over it. Small backward steps (real UDP reordering) are still rejected. (3) positionGE.setPing: the launcher's sentinel pings (-1 = no pong yet, -2 = >800ms) were passed through as NEGATIVE ownPing to every vehicle's predictor time-offset; now clamped to 0. p13h47 (pairs combined exe p13h31): REMOVED the p13h42 speed-aware self-heal fast path -- it WARBLED a high-speed car. Live log (h46): the watchdog fired 107x in one session on a fast Bugatti Chiron ghost, every ~0.5s for 15s, snapping it back from 19-27m -- a visible warble. Root: under multi-vehicle load the per-vehicle apply rate dips below the 0.1s packetTimeout (e.g. 58 applied/s / 8 vehicles = ~7Hz = 0.14s gaps), so each ghost briefly FREEZES between applies; harmless at low speed but a hypercar drifts >20m in that 0.3s freeze, and the fast path (heal at >=20m after 0.3s) snapped every one instead of letting the predictor catch up on the next packet. FPS was fine (67-112) so it was NOT an FPS hitch. FIX: the watchdog heals ONLY after a SUSTAINED stall again (>=1.0s + the rxMoved guard) -- the proven-clean p13h41/h44 behavior (0 false heals with the Chiron present). The fast path's only beneficiary was the broken B25 aircraft (now heals ~100m not ~50m, still far better than the 1000m with no watchdog). The residual high-speed stutter is LOAD (trim the live vehicle/AI count), not a snap. p13h46 (pairs combined exe p13h31): sync-stats overlay messages CORRECTED to match the confirmed apply-stall root cause. The 'Pos applied' rate reflects BOTH relay delivery AND local apply throughput (the apply runs per render frame), so a drop can be the relay OR a local FPS hitch. The overlay used to ALWAYS say '>> relay starving: lower send rate' on any apply-rate drop -- wrong when the drop is an FPS hitch (lowering the send rate doesn't help a hitch). FIX (MPDebug): the 'relay starving' hint now only shows when the apply drop is NOT accompanied by an FPS drop (applyBad and not fpsBad); when FPS is also dropping it's a LOCAL hitch and only the FPS-hitch hint shows (trim load). The drift/heals hint now names BOTH causes (load/FPS hitch -> trim mods+AI-traffic; or relay overload -> lower rate; never raise). p13h45 (pairs combined exe p13h30, unchanged): REMOVED fastPredict (the 'Low-GC predictor') entirely -- the function, the toggle, the UI checkbox, the MPConfig setting, the scratch vecs. WHY: a thorough line-by-line audit of updateGFXFast vs the reference updateGFX found NO aliasing/accumulation bug (scratch vecs never leak into persistent state; lastAcc/lastRacc are copied by value; no smoother ever gets a scratch input) -- it was mathematically equivalent. But its GC savings were marginal (~10 scratch vecs while it still allocated quats + the vehVel block + error diffs every frame) and under LuaJIT the allocation-heavy updateGFX is often FASTER (the JIT sinks short-lived allocs), so fastPredict added per-frame overhead + a 160-line parallel predictor that had to mirror updateGFX on every change -- a maintenance footgun that USER-OBSERVED made hitches worse (stock cars hitting the watchdog 'like the B25' with it on, because more hitches = more of the h44 apply-stalls turning visible). The apply-stall ROOT was confirmed (h44, fastPredict off): a ~1s GAME-SIDE FRAME HITCH under heavy load stops the local engine writing the ghost's mailbox (recv+0) -- not netcode. So one correct predictor path now; the lever for the stalls is LOAD (trim mods/traffic), surfaced in the overlay FPS-spike hint. p13h44 (pairs combined exe p13h30, unchanged): the p13h43 apply-stall diagnostic is now a permanent UI TOGGLE instead of always-on. New checkbox Options>Multiplayer>advanced 'Log position apply-stalls' (DEFAULT OFF) -> MPConfig.applyStallDiag -> positionGE.refreshFlags -> positionVE.setApplyStallDiag (live, mirrors fastPredict). Off = no tracking + no logs (the diagnostic is kept, not ripped out). When on it behaves exactly like h43. Also documented (LAN-TUNING.md) WHY the relay caps ~150 pkt/s -- the server's UDPServerMain is a SINGLE thread doing recv -> O(players) locked client lookup -> O(players) fan-out per packet, so it saturates ~150 pkt/s aggregate -- and the trade-offs of raising it (raising the send rate BACKFIRES: backlog->latency->drift->drops; the safe lever is an O(1) client lookup, not more Hz). p13h43 (pairs combined exe p13h30, unchanged): DIAGNOSTIC build to NAME the apply-stall trigger (the thing the self-heal watchdog has been catching). positionVE now instruments its ONE freeze point -- updateGFX's 'no fresh packet' early-return -- and on a sustained stall logs ONE 'posApplyStall' line that distinguishes the cause: recv+0 = packets aren't reaching the VE (GE->VE delivery stalled); reject+N = packets arrive but are rejected out-of-order at the tim guard (sender clock reset on a respawn); realGap small + simSpeed high = the simSpeed-scaled VE clock (dt*localSimspeed, clamped 25) raced past the 0.1s packetTimeout between packets; realGap large = packets genuinely stopped. Purely additive (counters + a one-shot 'W' log, no behavior change); the diag state is one table to stay under LuaJIT's 60-upvalue cap on the hot path. REPRO: fly the B25, let a freeze happen, /savelogs on LAN2 -> grep 'posApplyStall' for the verdict. p13h42 (pairs combined exe p13h30, unchanged): SPEED-AWARE self-heal fast path. The p13h41 watchdog waited a fixed 1.0s before healing a stalled ghost -- fine for a car, but at aircraft speed (~100 m/s) that 1s = ~100m of visible drift before the snap (seen live: a B25Mitchell bomber froze and its ghost ran out to 1038m). FIX (positionGE): a frozen ghost already >= SELFHEAL_FAST_DIST (20m) diverged is healed on FIRST detection instead of waiting the full 1.0s -- a fast sender crosses 20m within one ~0.25s check, so its visible drift is capped ~20-30m; a slow vehicle never reaches 20m in a single check so it still uses the conservative 1.0s path (no new false-heal risk -- moved/rxMoved are 0.25s deltas, so 'frozen-while-sender-moving' is already confirmed, not a 1-frame blip). The B25Mitchell itself is NOT broken -- it's a working aircraft; fast flight is just the worst case for position prediction, which the watchdog now recovers faster. p13h41 (pairs combined exe p13h30, unchanged): RE-ENABLED the self-heal watchdog with a new 'sender-moving' guard. p13h39-40 turned the watchdog fully OFF to stop it fighting the stock predictor on a drifted TANK (the 38-74m warble) -- but that regressed a genuinely STALLED ghost (e.g. a NaN-stuck fullsuv): it would sit out of sync until a manual reset (~10s+, no auto-recovery). FIX (positionGE): the heal now fires ONLY when the ghost is far + FROZEN (its own body barely moved) WHILE fresh positions keep ARRIVING (rxMoved > 0 = the sender is moving and streaming) -- i.e. a real VE-apply stall where the VE isn't applying what the GE is receiving. The tank's transient prediction gaps have rxMoved ~0 (no new packet to apply), so they NEVER qualify -- the warble can't come back. Net: genuine freezes auto-recover in ~1s again; the tank still rides the pure-stock predictor. STALL threshold raised 0.5->1.0s (the rxMoved guard already excludes the tank, so favour fewer false heals). p13h40 (release finalization, pairs combined exe p13h30): (1) launcher [DEBUG] logging is now OFF by DEFAULT (--debug re-enables) -- cleaner logs + a little less CPU/IO on every machine. (2) Removed the broken 'Auto-collect logs when profiling stops' option (autoCollectProfLogs) -- use /savelogs in chat or the 'Save all logs (zip)' button to bundle logs. (3) MPWeaponsGE per-shot SEND/RECV DIAG silenced (DIAG=false). (4) Combined exe: a --debug-gated 'latest-wins drain: coalesced N stale position(s)' log so the client receive-coalescing is verifiable under load. (5) The dead 'Remote sync mode' dropdown + its tracked-hold code are fully REMOVED (UI multiplayer.partial.html + positionGE syncMode/FPS-watcher/pushTrackedHold + MPConfig setting) -- the predictor is pure-stock with no dead toggle. (6) Public docs (RELEASE-NOTES/README-LAN/LAN-TUNING) rewritten to match -- removed watchdog/mode no longer advertised, deep '100 Hz' examples genericized to the configured rate. p13h39: TANK SYNC -- removed the fork's tracked-vehicle predictor BAND-AIDS (hardware testing showed STOCK BeamMP syncs the T-80UD fine with NONE, while the fork's additions made the tank spike 38-74m on the remote at 30Hz). (1) positionVE: the x2 force/ceiling stiffening for >=10-wheel vehicles is OFF (TRACKED_WHEEL_MIN 10->999) -> the tank rides the SAME pure stock predictor force constants as every car. (2) positionGE: the self-heal watchdog SNAP is OFF (SELFHEAL_ENABLED=false) -- it had fired 12x on a drifted tank ghost, snapping it back = the warble; a drifted/frozen ghost is now left to the stock predictor's own teleport. The drift GAUGE (overlay) still runs. So all vehicles, tank included, ride the stock predictor with zero fork interference; the Remote sync mode + setTrackedHold are now inert. (Howitzer per-shot from p13h38 is VALID code -- LuaJIT 2.1 compiles it; its load failures were a torn-file COPY RACE, the launcher re-installing the 78MB UniversalWeapons.zip while BeamNG mounts it. Restart with the mod already cached so the launcher skips the re-copy.) p13h38: ACCURATE per-shot weapon fire RE-ENABLED. The p13h37 diagnostic PROVED the chain is sound: the owner streamed 12 's' shot events, LAN2 received them all ('RECV fire state=s ... vobj=true'), and handleFire set uw_remoteFireShot on the ghost -- so the 'B' relay + per-shot delivery were never the problem (my p13h37 'relay not reaching LAN2' theory was wrong; the p13h36 'nothing fires' was the VE replay side, or the early window where the ghost wasn't found yet, vobj=false). So universalweapons.lua's remote loop is back to firing EXACTLY the streamed shots (uw_remoteFireShot) for slow/gated guns -- no key-press edge-fire, no free-run = no phantom round on a tap -- and ONLY a fast gun (minigun) free-runs on the fire STATE. Added a VE-side 'uwVeDiag' log ('remote replayed N per-shot round(s)') so a /savelogs confirms the ghost actually fires this time. The MPWeaponsGE.DIAG SEND/RECV logs stay on for one more confirming round (set DIAG=false to silence). p13h37: WEAPON-SYNC DIAGNOSTIC build. After p13h36 the remote saw NO projectiles and NO damage from a firing peer (both at once -> the shared 'B' relay is the prime suspect, since fire 's' AND the explosion blast both ride 'B'). TWO changes: (1) reverted the remote fire loop to the pre-per-shot FREE-RUN so weapons WORK again (projectiles + damage; the constant-fire over-firing is back TEMPORARILY) -- this unblocks play while we find the per-shot break; (2) added a temporary MPWeaponsGE.DIAG log on BOTH ends of the 'B' relay: LAN1 logs every SEND (fire code + explosion), LAN2 logs every RECV (handle()/handleFire/explosion incl. parse-fail + vehicle-lookup DROP reasons). Fire one salvo at a target, /savelogs on BOTH, and the SEND-without-a-matching-RECV pinpoints whether 'B' even reaches the remote vs. mis-routes vs. the VE replay. p13h36: weapon fire-rate sync FIX (refines p13h32; UniversalWeapons.zip re-served). The remote still fired a phantom round on the fireweapons KEY-PRESS edge (the owner's BF:1), not only on real shots -- so TAPPING the fire key on a slow/gated gun (the howitzer fires ~1 round / 3s) spawned a projectile per tap on remote screens even when the owner's gun didn't actually fire. Root cause: the remote's free-run '0->1 edge fires one round' path was gated on a per-shot-ping-timing heuristic (perShotActive) that is FALSE on the first tap, before any shot event has arrived. FIX: gate the edge-fire + free-run purely on the gun's STATIC rate (fireInterval < SHOT_SYNC_MIN_INTERVAL = a FAST gun like the minigun, which the owner doesn't per-shot); a per-shot gun (slow/gated) now fires ONLY on the actual broadcast shot events, NEVER on a key edge. p13h35: sync-stats overlay recommendation FIXED -- the 'ghost drifting/correcting' hint said 'cut AI/traffic count or RAISE Position send rate', which is now backwards (raising the rate oversubscribes the relay = MORE drift). Now reads 'cut AI/traffic count or LOWER Position send rate (overload, not too-low a rate)', consistent with the 'relay starving -> lower' hint. Docs (LAN-TUNING.md/README-LAN.md/AGENTS.md) updated with the new sync defaults (30Hz default, 60 ceiling, 100 removed, buffers 256->16) and the 'lower is better' principle. p13h34: REMOVED the 100Hz Position-send-rate option from the in-game UI. 100Hz is above what the single-path relay can carry with 2+ players (~150 pkt/s cap), so it always oversubscribed -> the option was a footgun. UI select is now 60/30/10 (60 = the 2-player ceiling, 30 = default, 10 = stock). positionGE.refreshFlags clamps + MIGRATES any saved value >60 down to 30 (and writes it back, so an existing user who had 100 doesn't keep oversubscribing and the dropdown doesn't show a blank orphaned selection). Read fallbacks (positionGE/MPDebug) default to 30. p13h33: position send-rate DEFAULT 100 -> 30 Hz. Hardware testing showed the fork's remote-car tracking DEGRADED over a session vs the stock mod (stock stays tight). Root cause: the 100Hz default oversubscribed the shared relay (~150 pkt/s total cap, single-threaded UDP forwarder) -- two players each streaming a driven car = ~200 pkt/s, so the relay backlog GREW and every applied remote position got progressively more stale -> the predictor extrapolated further -> growing drift. The predictor INTERPOLATES between updates, so it never needed a high rate (that's why stock's 10Hz looks fine); 100Hz was actively fighting it. 30Hz = ~60 pkt/s for 2 players (under the cap), smoother than stock, no backlog. Tune via Options > Multiplayer > Position send rate (10 = exact stock). p13h32: ACCURATE remote weapon fire RATE. The remote used to free-run UniversalWeapons' own fire loop at the gun's MAX rate for the whole time the owner held fire -- so a turret (which only sets fireweapons=1 when AIMED, gating its real cadence below max) looked like CONSTANT firing on other screens while the source actually fired slower. Now guns at/below ~14 rounds/s (howitzer/m242/50cal) broadcast each ACTUAL shot (reliable 'B' relay, new 's' sub-state) and the remote replays EXACTLY those -> the remote cadence matches the source even when gated. Fast guns (minigun, 20/s) keep the cheap fire-STATE free-run so the relay stays light; a pre-p13h32 owner (no per-shot stream) also falls back to free-run (graceful, via a 0.4s 'is the owner streaming shots?' check). Touches MPWeaponsGE (broadcast + handle the 's' shot, sets uw_remoteFireShot) + universalweapons.lua (owner per-shot broadcast gated by fireInterval >= 0.07s; remote per-shot replay). Re-serves UniversalWeapons.zip. p13h31: sync-health LOG TRAIL. New '/synclog' chat command (toggle, OFF by default) mirrors the sync-stats overlay's line to beamng.log every ~15s ('N synced | drift Xm, M heals | in/out pkt+KB/s | applied/s | FPS') so a /savelogs after an intermittent drift episode captures what the overlay showed over time -- runs even with the overlay hidden. PAIRS WITH combined exe p13h27: server-side mod re-download LOOP DETECTOR -- if a client re-requests the same mod 4+ times in one join (outdated < p13h26 launcher or a stale client cache), the HOST log now prints ONE clear WARN naming the client + mod instead of a silent wall of 'Download ... took Xms' lines. (Earlier this batch: combined exe p13h26 fixed the ACTUAL LAN2 re-download loop -- the client launcher's NewSyncResources had NO success-exit, so a CLEAN verified download re-requested the same mod forever; now it breaks on success with a bounded 3x retry for a genuinely corrupt transfer. p13h25: launcher --no-debug flag. p13h24: server RefreshFiles per client-join so a hot-swapped mod's new hash/size is advertised. Also: turrets.zip re-served fixed -- a repack had put Windows NTFS extras in a Unix (cs=3) zip's LOCAL headers, which BeamNG can't read; stripped them.) p13h30: sync-stats overlay is now DRAGGABLE (removed the NoMove/NoInputs flags; SetNextWindowPos is FirstUseEver so it starts at the top-left but remembers wherever you drag it) and has a darker, more readable backdrop (BgAlpha 0.35 -> 0.7). Drag anywhere on the panel body. PAIRS WITH combined exe p13h25: a new launcher '--no-debug' flag that suppresses [DEBUG] log lines entirely -- it skips both the string build AND the per-line log-file open/write/close in addToLog, shaving a little CPU/IO on a busy host (the launcher's debug() calls are mostly event-driven, so the win is modest, biggest during mod downloads + event bursts). (Turret mod, shipped separately: semi-auto target readout now shows the player's NAME via MPVehicleGE.getNicknameMap() instead of the raw vehicle id, with a #id fallback; plus a DIAG build of missiles.lua that step-logs each missile's lifecycle to pinpoint the 'only the first launches' bug.) p13h29: FINAL pre-public-release robustness sweep (4-agent audit of the mod + combined exe). MOD-side FATAL-class guards so a broken/version-mismatched 3rd-party mod (or a crafted packet) can't kill a vehicle's VE sync VM (the one-way-desync class): (1) controllerSyncVE 'setCameraControlData' rebuilt a quat from variables[1].cameraRotation BEFORE the receive pcall with no nil checks -> now type-guards variables/[1]/cameraRotation first (the one spot the controllerSync pcall didn't cover); (2) MPInputsVE.applyGear ran on the per-frame remote path (NOT pcall'd) and assumed electrics.values.gear is a string and controller.mainController exists -> a custom-powertrain car (gearIndex set, gear nil/no mainController) FATAL-looped its ghost; now guarded; (3) propsControllers spinner engineInfo[6] string-checked to match the hamster path; (4) couplerVE checks getGroupState exists before calling; (5) nodesVE.applyNodes shape-guards its decode (the full-deformation RECEIVE side applies regardless of the local toggle, so a peer with the experimental feature on reaches it); (6) GE-side nil guards: applyVehEdit decode + playerVehicle.config, onServerVehicleResetted pos/rot shape, onServerVehicleCoupled + onVehicleSpawned nil vehicle, applyPos malformed-pose. Position-sync polish: the self-heal watchdog reuses its per-check table (no GE GC litter) and only tracks _diagPeak while profiling. PAIRS WITH combined EXE p13h23: fixes a DeComp() empty-input INFINITE-LOOP HANG (CPU-spin) on both the server and the launcher, reachable by any peer sending a bare 4-byte 'ABG:' packet (empty body -> 0-size buffer -> zlib Z_BUF_ERROR -> grow stays 0 -> never throws); plus the launcher DeComp grow-cap, throwing-fs::file_size hardening in the mod-download paths, and an Options --user-path arg fix. The combined-host leave/rejoin concurrency rewrite was audited CLEAN (no UAF/deadlock/double-client). p13h28: DEFAULT Remote sync mode changed Auto -> SMOOTH (chosen after testing). The firm tracked-vehicle hold that Auto applies at high FPS consistently felt WORSE than the stock-smooth predictor (the tank warble), and Auto's x1<->x2 flipping as FPS bounced added inconsistency. Smooth = pure stock predictor + the frozen-only watchdog = the best default feel. Auto and Accurate stay as options (Options>Multiplayer>advanced) for anyone who wants the firmer hold. (Reminder: heavy sync drift is usually OVERLOAD, not the mode -- keep the live heavy-vehicle count low; the fullsuv is the worst offender.) p13h27: LONG-VEHICLE self-heal FALSE POSITIVE (the 'capsule' 12m bus snapping every 0.5s). Root cause: the sender broadcasts its COG (doSendPosRot = getPosition()+cogRel) so rxPos is the COG, but the self-heal watchdog compared it to veh:getPosition() = the REFNODE. On a long vehicle the COG<->refNode gap is ~6m, which the watchdog read as a permanent '6m off frozen' and snapped the refNode to the COG every 0.5s -- shoving the bus by cogRel each time = visible jitter (looked like a tank/sync issue but was the bus). FIX: the watchdog now compares + snaps against the OOBB CENTER (be:getObjectOOBBCenterXYZ, BeamNG's geometric/COG-proxy center) so it's COG-vs-COG (~0 when synced) at any vehicle length, and the heal offsets the refNode by the refNode->center vector so it no longer shoves long vehicles. Cars unaffected (cogRel <1m). This also makes the overlay 'Ghost drift' number correct for long vehicles. NOTE from the h25 logs: the TANK is now fine (0 self-heals on the host, held x2 in Auto) -- the frozen-only watchdog fix worked; the 157 self-heals were ALL the bus. p13h26: removed the deprecated setCEFFocus(true) call from the Chat/PlayerList/Session UI apps' select() handlers -- BeamNG deprecated it ('doesn't need to be called'; the engine now manages CEF/UI-app focus automatically), so it was just spamming an E-level deprecation warning. Handlers kept as no-ops so the ng-click bindings stay valid. p13h25: SYNC FEEL (why the high-rate fork felt WORSE than stock's 10Hz for the tank). Two of our additions were FIGHTING the stock predictor: (1) the self-heal watchdog HARD-SNAPPED a ghost to the RAW last-received position whenever it was >5m off -- but the stock predictor already teleports to the PREDICTED position, so on a continuously-drifting tank the two yanked it opposite ways ~2x/sec (the warble). FIX: the watchdog is now FROZEN-ONLY -- it only snaps a ghost that's far AND barely moving (a stalled apply); a moving/drifting ghost is left to the stock predictor's own smooth teleport. (2) the tracked-vehicle hold was a fixed x4 (h24) which over-stiffened the tank. FIX: reverted to x2 base and made it a refactor (BASE*multiplier, recomputable, hot paths untouched). NEW 'Remote sync mode' option (Options>Multiplayer>advanced; default Auto): SMOOTH = stock-like (hold x1, frozen-only watchdog -> smoothest), ACCURATE = firm hold x2, AUTO = adapt by local FPS (firm when FPS high, smooth when it drops, hysteresis 42-55fps) -- positionGE pushes the hold to positionVE.setTrackedHold live. Cars are unaffected (never stiffened). If the tank still feels off, try Smooth. p13h24: TANK GHOST DRIFT -- raised the tracked-vehicle position hold from x2 to x4. Diagnosed from a live log: the T-80UD ghost WAS being detected + stiffened ('tracked vehicle (14 wheels): stiffened ... x2') but still drifted ~6-10m (above the 5m self-heal threshold), so the posWatchdog kept snapping it back every ~0.5s (visible warping) -- the tank's tracks were out-muscling the x2 corrective ceiling. x4 should hold it under threshold; if a tank ghost VIBRATES in place, dial TRACKED_HOLD back toward 3.0 (positionVE.lua:~52). The early severe drift (12-18m) was just the window before the detection fires (it waits for wheels to init, ~12s after spawn). NOTE the 'applyVehEdit ... does not correspond' WARNING is NORMAL vehicle-swap handling (it re-spawns the ghost as the new model), not a bug. p13h23: COMMUNITY-RELEASE robustness sweep (multiagent review of the mod + combined exe). FATAL-class hardening so a broken/3rd-party mod in the wild can't kill a vehicle's VE sync VM or the GE receive loop (the one-way-desync class): (1) the top-level GE network dispatch (MPGameNetwork.onUpdate) is now pcall-wrapped -- any error in ANY handler (a broken mod's data, a removed BeamNG API, a malformed packet) is LOGGED instead of breaking that frame's whole receive loop, matching the event-queue path; (2) couplerVE default coupler-RECEIVE path: a peer's trailer/coupler controller that doesn't exist locally was an unguarded getControllerSafe(name).getGroupState() chain (plus a detachGroup() on an empty table) -> FATAL; now resolves a real controller first and skips the branch if absent; (3) controllerSyncVE RECEIVE dispatch is pcall-wrapped, covering EVERY advancedCouplers/general/weapon-mod receive function at once (a controller removed after registration, or a malformed 'variables', no longer FATALs); (4) jsonDecode results nil-guarded in MPPowertrainVE (x2), couplerVE, controllerSyncVE, nodesGE; (5) nodesVE beamstate.beamBroken guarded the same way as beamDeformed; (6) MPVehicleGE spawn handler guards players[ownerID] (nil on a spawn-before-join race). All edits verified parsing under luac 5.3. In-game options/overlays/version strings were audited clean (no dead toggles, overlays report accurate fields). PAIRS WITH combined exe p13h22 (host leave/rejoin gHostLink/gHostClient race + decompression-buffer min/max fix + broken-mod mount log-and-skip) and the new host/ scripts (start-server.bat + pin-cores.ps1 now pin the real BeamNG.drive.x64 process, not the idle loader). p13h22: SECOND FATAL fix in the same syncFullDeformation path -- once p13h21 let getNodes actually SEND, the RECEIVE side (nodesVE.applyNodes) hit beamstate.beamDeformed, which BeamNG 0.3x REMOVED (only the onBeamDeformed callback remains), so the nil call FATAL-killed the receiver's vehicle VM (spammed on a TriX_Chiron). Guarded it; the deformed SHAPE still syncs via setBeamLength, only the (now-absent) damage-system bookkeeping is skipped. syncFullDeformation remains experimental + heavy -- leave it OFF unless you specifically want crash-damage parity. p13h21: (1) FATAL FIX -- nodesVE called a capital 'Round' that is a nil global (the real fn is lowercase 'round', and it was defined AFTER getNodes so out of lexical scope anyway), so every full-deformation-sync tick threw a FATAL Lua error that killed the vehicle's VE VM -- seen crash-looping on a TriX_Chiron. Moved 'round' above getNodes + fixed the case; syncFullDeformation now actually works instead of crash-looping (still gated by the toggle + heavy, leave it off unless you want crash-damage parity). (2) Tracked-vehicle position hold: a driven tank's skid-steer/tracks pushed its ghost off the synced position faster than the predictor's spring caught up, so ONLY the driven tank self-healed (~6m repeatedly) while cars stayed clean. positionVE now detects tracked vehicles by wheel count (>=10; T-80UD has 16, cars 4) and stiffens the correction force/ceiling x2 for them (force/ceiling only, not the gains, to avoid oscillation), once per vehicle, covering both the default and fastPredict paths; wheeled cars untouched. PAIRS WITH the new launcher/combined exe: (a) server DeComp pre-sizes the decompression buffer (16x estimate, clamp 30MB) so a large vehicle config decompresses in one shot instead of the fail-then-retry that logged 'zlib uncompress() failed, trying a larger buffer'; (b) /savelogs in --combined no longer fails with err 123 -- start-server.bat launches via `start` with a relative argv0 so GetEP() returned no dir -> launcherDir empty -> the tar CreateProcessW got an empty lpCurrentDirectory (ERROR_INVALID_NAME); now anchored to the absolute process cwd. (p13h20: a failed/partial vehicle spawn no longer FATAL-crashes the whole multiplayer mod. MPVehicleGE.sendVehicleEdit (run from onVehicleSpawned) indexed nil vehicleData.config when a vehicle failed to load (e.g. a broken mod whose jbeam files couldn't be read -> 'main slot not found') -> a FATAL GE Lua error that killed sync for the ENTIRE session. Now guards nil veh/vehicleData/config and skips the edit broadcast with a warning. (Triggered by a corrupt Tank_T80UD zip: the earlier PowerShell ZipFile.Update repack made a zip bsdtar could read but BeamNG could NOT -- re-packed with bsdtar, the proven method.) (h19: map-switch self-disconnect fix -- the seamless map-switch watchdog gave up after only 60s and force-LEFT the server, but big modded levels load ~90s (ogc_map measured 90.6s), so the HOST doing an in-place switch disconnected its own launcher mid-load ('LAN1 disconnected from itself') while a fresh-joining client (LAN2) was fine (a fresh join gets the new map via the normal handshake, no transition watchdog). Bumped MAP_TRANSITION_TIMEOUT 60->180s (named constant, tunable). (h18: sync-stats overlay now reports the ACTUAL drift symptom. It was staying GREEN while ghosts drifted/corrected because it only watched apply-rate DROPS + FPS -- both look healthy during a traffic FLOOD (high aggregate apply rate, one ghost still starved). NEW 'Ghost drift: X.Xm [N corrections]' row, driven by the positionGE self-heal watchdog's told-vs-actual gap + correction count; reddens when a self-heal fires OR drift exceeds ~8m (well past the few-metre healthy predictor lead). Spawn/teleport transients (>100m) excluded so the number reflects real drift. (h17: traffic-drift/glitch ROOT CAUSE -- h10 claimed non-driven owned vehicles 'drop to the low tick-rate send' but there was NO actual throttle. positionGE.tick (driven at ~FPS by MPUpdatesGE's positionTickrate 1/100) armed only the DRIVEN car to physRateSendHz; EVERY other owned vehicle was sent via getVehicleRotation() on EVERY tick (~FPS 60-90Hz) -- the rate lever never touched it. So N spawned vehicles flooded the relay: the LAN1 log measured 370 pos/s APPLIED at a '10Hz' setting with 7 cars (= 1 driven x10 + 6 AI x~60), starving every ghost into drift, and dialing physRateSendHz down did nothing. FIX: MPUpdatesGE now gates non-driven owned vehicles at a fixed trafficTickrate (12Hz) decoupled from the driven car (which stays full-rate): positionGE.tick(sendTraffic). The driven car can now run 30-60Hz smoothly even with traffic present. The 10Hz no-traffic 'glitch' was just low-rate prediction coarseness -- the predictor was clean in the log (90fps, 0 stale, 0 teleports) -- so run the driven car higher now that traffic no longer floods. (h16: final 3-agent review sweep -- fixed places where earlier nil-guards were one-sided: MPNetworkHelpers 'ready'-branch #nil crash on a pure-timeout partial receive; MPControllerGE.applyControllerData (receive side) + positionGE.sendVehiclePosRot (send side) jsonDecode guards I'd only added on the opposite side. Plus a real CASE bug: MPVehicleGE passed `ServerVehicleString` (capital) to Vehicle:new which reads `serverVehicleString` (lowercase) -> the vehicle got a nil id and every edit-before-spawn was silently dropped. Plus cheap hardening: loginReceived + unknown-role nil-guards, double profiler :stop(), dropped leftover dump() spam (MPNetworkHelpers/MPVehicleGE), FFI header over-alloc (uint32_t[?] count 4->1). PAIRS WITH new launcher+server exes: server FILE-DOWNLOAD path (TCPSendRaw/sendfile) now held under the per-client TCP send-mutex for the whole transfer (completes the C1 desync fix -- it bypassed the mutex), GetPidVid empty-part guard, 'P'-ping stray-NUL, mMods.clear lock-order; launcher WSACleanup on socket-create failure, 'Zp' drop now checks the packet CODE not find()-anywhere, __linux__ typo, crash-history is_directory guard. (h15: base-code review hardening (3-agent audit of the Lua mod + launcher + server). Lua VE-fatal nil-crash fixes that could kill a vehicle's whole sync: getControllerSafe on cars lacking transbrake/lineLock/compressionBrake, unchecked jsonDecode in positionGE/positionVE/MPVehicleGE/MPControllerGE, getOwner/players_vehicle_configs nil on a fast vehicle-edit, a per-frame spectators nil-deref after a player leaves, decoded.vel/rvel + getObjectByID guards. Also: MPNetworkHelpers partial-receive truncation fix (dropped the tail of a split packet), a velocityVE table.remove-in-forward-loop that skipped half the detached nodes, an infinite send-retry loop (MPGameNetwork+MPCoreNetwork) that could freeze the game on a persistent socket error, and a per-send dump() pulled from the controller hot path. PAIRS WITH new launcher+server exes: UDP recv buffers bumped (socket SO_RCVBUF + 64KB per-recv = the drift fix) and a server per-client TCP send-mutex (fixes interleaved-write framing corruption = the one-way desync), plus launcher crash/guard fixes (abort()-on-packet now a graceful drop, uninitialized RegEnumKeyExW buffer, atomic cross-thread flags). OS side: LAN-TUNING.md (Linux net.core.rmem_max is the key item). (h14: sync-stats overlay now flags problems in RED (relay starving / FPS spiking) and tracks peak+persistent severity -- 'Pos applied' and 'FPS' show '[dipped to X, bad Ns total]' that persists after recovery so you can see how deep and how long an issue ran while tuning, with an auto-reset each time you change the send rate (fresh measurement per step) + a red one-line hint of which lever to pull. (h13 tunable position send rate + diagnostic overlay for the 'both-low-CPU, one-drifts-at-a-time' issue (= the shared server relay's throughput, not CPU). NEW UI select 'Position send rate' 100/60/30/10 Hz (live; 10 = stock BeamMP) -> dial down so both players' streams fit a loaded relay, tune back up. Sync-stats overlay now shows 'Pos applied/s' (falls to ~0 when the relay starves -> lower the rate) and 'FPS' (drops with it = one core pegged e.g. the predictor -> try the existing fastPredict toggle). Both levers apply live, no reload. (h12 AI-chase consent rework -- the old 'AI cars chase nearest player' toggle is now 'Allow other players' AI cars to chase me' (opt-in, default OFF): by default nobody else's AI/weapon cars can lock onto you; flip it on to volunteer as a target. Your OWN cars are unchanged (AI radial 'Chase') -- they now target yourself + any remote player who opted in. Opt-in synced via the reliable 'B'/C: relay (no server change for this part). (h11: adaptive remote weapon projectiles -- a weapon car the owner is DRIVING fires full physics projectiles on other screens (broadcastFire tags the owner's active vehicle); a SPAWNED/AI weapon car gets a light muzzle-flash+sound replay (CPU saver, since h10 throttles non-driven cars anyway). New UI toggle 'Full weapon projectiles on remote cars' (default off) forces full everywhere for strong machines. (h10: send-rate budget fix -- ROOT of the no-weapons drift. The relay tops out ~100-150 position pkts/s TOTAL, but physicsRateSend self-sent EVERY owned vehicle at 100Hz; with several owned vehicles (AI traffic) that oversubscribed the budget and starved every ghost into drift. Now only the actively-driven vehicle gets the 100Hz physics-rate send; other owned vehicles drop to the low tick-rate send. (h9: (1) weapon-fire sync per-shot -> fire-STATE (on/off edges + low-rate keepalive): a full-auto burst now costs ~2 packets/sec instead of ~30, fixing the position-sync DRIFT that heavy firing caused by flooding/starving the position stream (remote runs its own fire loop while 'firing'; single shots stay precise via a 0->1 edge that fires one round). (2) self-heal watchdog corrects sooner: 5m/0.5s (was 10m/1.5s) now that h8's gauge reads true divergence. -- h8 FIX watchdog read nametag-clobbered vehicle.position (now rxPos/rxRot)" -- it was reading vehicle.position, which MPVehicleGE's nametag loop overwrites every frame with the rendered OOBB center, so it compared the rendered position to itself (a constant ~height offset per car) and NEVER saw the real drift or fired. Now uses a dedicated rxPos/rxRot copy taken straight from the received packet -> it actually detects a drifted/frozen ghost, the self-heal force-resyncs it, and the 'told-vs-actual peak' instrumentation finally shows true divergence. Also explains 'two map markers far apart for one car': vehicle.position flickers between received and rendered during a drift. (h7 weapon-FIRE sync; h6 drift instrumentation; h5 self-heal watchdog; h4 velocityVE guard+popen; h3 mp_state; h2 savelogs button; h1 explosion-receive be:; base p13 /savelogs+/netdebug+/mpstate; p12 LAN caps, p11 explosion 'B', p10 weapon-chase, p8 electrics/VE hardening))"
-- server

local serverList -- server list JSON
local currentServer = nil -- Table containing the current server IP, port and name
local isMpSession = false
local isGoingMpSession = false
local status = "" -- "", "waitingForResources", "LoadingResources", "LoadingMap", "LoadingMapNow", "Playing"

-- seamless map switch (LAN): set while a server-initiated map change is in progress, so
-- onClientEndMission treats the level swap as a rejoin (no leaveServer / Lua reload) and
-- runPostJoin sends the map-ready ack + re-spawns our car. See beginMapTransition.
local isChangingMap = false
local mapGeneration = 0       -- server session generation we are transitioning to / acked
local mapTransitionTimer = 0  -- watchdog: fall back to a full leave if the load stalls
-- Big modded levels load slowly (ogc_map measured ~90s). The old 60s watchdog fired DURING a
-- legitimate load and force-LEFT the host's own client mid-switch -- i.e. "LAN1's launcher
-- disconnected from itself". (A client joining FRESH was unaffected: it gets the new map via the
-- normal handshake, which has no transition watchdog.) 180s = ~2x the worst observed load while
-- still backstopping a genuinely hung loadLevel. Bump higher if a map ever loads slower than this.
local MAP_TRANSITION_TIMEOUT = 180

-- Resource (VRAM) headroom monitor. Heavy modded sessions can exhaust VRAM during a map
-- load and crash the game (KERNELBASE thrown exception); warn the player while they're
-- still playing so they can trim before the next switch tips it over. See checkVramHeadroom.
local vramCheckTimer = 0
local vramTotalMB = nil   -- card total (queried once); -1 = API unavailable, stop trying
local vramWarned = false  -- hysteresis: warn once per high-water crossing

-- auth

local loggedIn = false
local authResult = {}

-- event functions

local onLauncherConnected = nop
local runPostJoin = nop
local originalFreeroamOnPlayerCameraReady

local loadMods = false -- gets set to true when mods should get loaded
--[[
Z  -> The client asks the launcher its version
B  -> The client asks the launcher for the servers list
QG -> The client tells the launcher that it's is leaving
C  -> The client asks for the server's mods
--]]

-- timer variables
local pingTimer = 0
local onUpdateTimer = 0
local updateUiTimer = 0
local heartbeatTimer = 0
local reconnectTimer = 0
local reconnectAttempt = 0

-- AA============= VARIABLES =============AA


-- VV============= LAUNCHER RELATED =============VV


--- Sends data through a TCP socket
-- @param s string containing the data to send to the launcher
local function send(data) -- TODO currently the socket keeps retrying indefinitely if timed out, this freezes the game if the launcher is frozen, breaking the loop with offset the header and break the connection, we could maybe buffer data and try again next frame?
	if TCPLauncherSocket == nop then return end

	local header = ffi.string(ffi.new("uint32_t[?]", 1, #data), 4)
	local packet = header .. data

	local retries = 1

	local bytes, error, index = TCPLauncherSocket:send(packet)

	if error == 'timeout' then
		while (retries > 0 and error) do
			isConnecting = false
			log('E', 'sendData', 'Socket error: '..error)
			if error == "timeout" then
				log('W', 'sendData', 'Stopped at index: '..index..' while trying to send '..#packet..' bytes of data. retries:' .. retries)
				packet = string.sub(packet, index + 1)

				bytes, error, index = TCPLauncherSocket:send(packet)
			else
				break -- non-timeout error (e.g. closed): stop retrying instead of spinning forever
			end
			retries = retries - 1 -- bounded; was never decremented -> infinite loop on a persistent timeout
		end
	end

	if error then
		if error == "Socket is not connected" then
			-- tcp handshake still in progress; keep isConnecting=true and let onUpdate retry
			return
		end
		isConnecting = false
		log('E', 'send', 'Socket error: '..error)
		if error == "closed" and launcherConnected then
			log('W', 'send', 'Lost launcher connection!')
			if launcherConnected then guihooks.trigger('LauncherConnectionLost') end
			launcherConnected = false
			TCPLauncherSocket = nop
			authResult = {}
			guihooks.trigger("authReceived", authResult)
		elseif error == "closed" then
			-- socket died before we finished connecting, force new socket next attempt
			TCPLauncherSocket = nop
		else
			log('E', 'send', 'Stopped at index: '..index..' while trying to send '..#data..' bytes of data.')
		end
	else
		if not launcherConnected then launcherConnected = true isConnecting = false onLauncherConnected() end

		if not settings.getValue("showDebugOutput") then return end
		log('M', 'send', 'Sending Data ('..bytes..'): '..data)
	end
end

--- Connects to the Launcher.
-- @param silent boolean determines if the connection request should be done silently
local function connectToLauncher(silent)
	--log('M', 'connectToLauncher', debug.traceback())

	isConnecting = true
	if not silent then log('W', 'connectToLauncher', "connectToLauncher called! Current connection status: "..tostring(launcherConnected)) end
	if not launcherConnected then
		if TCPLauncherSocket == nop then
			TCPLauncherSocket = socket.tcp()
			TCPLauncherSocket:setoption("keepalive", true) -- keepalive to avoid connection closing too quickly
			TCPLauncherSocket:settimeout(0) -- set timeout to 0 to avoid freezing
			TCPLauncherSocket:connect(settings.getValue("launcherIp", '127.0.0.1'), settings.getValue("launcherPort", 4444))
		end
		send('A') -- will succeed once handshake completes, triggering onLauncherConnected
	else
		log('W', 'connectToLauncher', 'Launcher already connected!')
		guihooks.trigger('onLauncherConnected')
	end
end

--- Disconnect from the Launcher --unused, for debug purposes
-- @param reconnect boolean Should Lua reconnect to the launcher after disconnecting?
-- @usage MPCoreNetwork.disconnectLauncher(true)
-- @return nil
local function disconnectLauncher(reconnect) 
	log('W', 'disconnectLauncher', 'Launcher disconnect called! reconnect: '..tostring(reconnect))
	if launcherConnected then
		log('W', 'disconnectLauncher', "Disconnecting from launcher")
		TCPLauncherSocket:close()
		launcherConnected = false
		isGoingMpSession = false
		socketPartialData = nil
	end
	if reconnect then connectToLauncher() end
end


-- This is called everytime we receive a heartbeat from the launcher
local function receiveLauncherHeartbeat() -- TODO: add some purpose to this function or remove it

end
-- AA============= LAUNCHER RELATED =============AA

--- Request the launcher opens the url in the users web browser
-- @usage `MPCoreNetwork.openURL("<url>")`
local function openURL(url)
	send("O"..url)
	log('M', 'openURL', 'Requesting the BeamMP Launcher to open url: '..url)
	-- Remove this when the url opening is in the public launcher release
	guihooks.trigger('ConfirmationDialogOpen', "Link opened", "Please open  "..url.." in your browser if nothing happens.", "OK", "guihooks.trigger('ConfirmationDialogClose', 'Link opened')")
end

-- ================ UI ================
--- Called from multiplayer.js UI
-- Returns the version of the launcher.
-- @return string version The version of the launcher.
local function getLauncherVersion()
	return launcherVersion
end

--- Returns true or false if the user is logged in.
-- @return boolean loggedIn True if the user is logged in, false otherwise.
local function isLoggedIn()
	guihooks.trigger('actuallyLoggedIn', loggedIn)
	return loggedIn
end

--- Returns true or false if the launcher is connected.
-- @return boolean launcherConnected True if the launcher is connected, false otherwise.
local function isLauncherConnected()
	return launcherConnected
end

--- Logs in the user with the given identifiers by sending the request to the launcher
-- @param identifiers table The identifiers used for login.
local function login(identifiers)
	log('M', 'login', 'Attempting login...')
	identifiers = identifiers and jsonEncode(identifiers) or ""
	send('N:'..identifiers)
end

--- Automatically logs in the user.
-- @usage autoLogin() -- Tells the launcher to attempt to auto authenticate with BeamMP Services
local function autoLogin()
	send('Nc')
end

--- LAN: set the local player's display name (used by the server as the name).
-- The launcher adopts and persists it. Call before connecting.
-- @param name string The desired player name.
local function setPlayerName(name)
	if not name or name == "" then return end
	send('N:setname:'..tostring(name))
end

--- Gets the current login data.
-- @usage getLoginState() -- Triggers a return of the login data
local function getLoginState()
	guihooks.trigger("authReceived", authResult)
end

--- Tells the launcher to log out the user.
-- @usage logout() -- Tells the launcher to logout from BeamMP Services
local function logout()
	log('M', 'logout', 'Attempting logout')
	send('N:LO')
	loggedIn = false
	authResult = {}
	guihooks.trigger("authReceived", authResult)
end

--- Sends the current player and server count plus the mod and launcher version to the CEF UI.
-- @usage MPCoreNetwork.sendBeamMPInfo()
local function sendBeamMPInfo()
	local servers = jsonDecode(serverList)
	local p, s = 0, 0
	if servers and not tableIsEmpty(servers) then
		guihooks.trigger('onServerListReceived', servers) -- server list
		for _,server in pairs(servers) do
			p = p + server.players
			s = s + 1
		end
	end
	-- LAN fork: ALWAYS send the mod/launcher version (and counts) to the UI, even with
	-- no public server list. The stock code returned early on an empty list, which on a
	-- LAN (the server browser is disabled) left the info-bar stuck on the "..." version
	-- placeholder. Counts are 0 when there's no list -- that's correct for LAN.
	guihooks.trigger('BeamMPInfo', { -- <players> count on the bottom of the screen
		players = ''..p,
		servers = ''..s,
		beammpGameVer = ''..modVersion,
		beammpLauncherVer = ''..launcherVersion
	})
end

--- Request the server list data from the launcher.
-- @usage MPCoreNetwork.requestServerList()
local function requestServerList()
	if not launcherConnected then return end
	if isMpSession and not settings.getValue("refreshIngame") then
		log('W', 'requestServerList', 'Currently in MP Session! Using cached server list.') --TODO: add UI warning when cached server list is being displayed
		sendBeamMPInfo()
		return
	end
	send('B') -- Request server list
end

--- Request the UI counts and other metrics by calling `sendBeamMPInfo()`
-- @usage `MPCoreNetwork.requestPlayers()`
-- @see sendBeamMPInfo
local function requestPlayers()
	--log('M', 'requestPlayers', 'Requesting players.')
	sendBeamMPInfo()
end
-- AA================ UI ================AA



-- ============= SERVER RELATED =============
--- Set the mods for the server you are joining
-- @param receivedMods string The mods from the server in string form.
-- @usage setMods(`<modsstring>`)
local function setMods(receivedMods) -- receiving mods means that the client authenticated with the server successfully
	isMpSession = true
	isGoingMpSession = true
	MPModManager.setServerMods(receivedMods)
end

--- Returns the current server information
-- @return currentServer table
-- @usage MPCoreNetwork.getCurrentServer()
local function getCurrentServer()
	--dump(currentServer)
  return currentServer
end

--- Set the current server information for later use
-- @param ip string The IP/URL of the server
-- @param port number The Port of the server
-- @param name string The Name of the server (Used at the top of the screen when in session)
-- @param skipModWarning boolean If the mod security warning should be skipped
-- @usage MPCoreNetwork.setCurrentServer('localhost', 30814, 'Test Server', false)
local function setCurrentServer(ip, port, name, skipModWarning)
	-- If the server is different then lets also clear the existing chat data as this does not always done on leaving
	if currentServer ~= nil then
		if currentServer.port ~= port and currentServer.ip ~= ip then
			print('Clearing Chat!')
			be:executeJS('localStorage.removeItem("chatMessages");')
		end
	else
		-- otherwise lets clear it again anyway for good measure as the server we are joining may not be the same server.
		be:executeJS('localStorage.removeItem("chatMessages");')
	end
	currentServer = {
		ip             = ip,
		port	       = port,
		name	       = name,
		skipModWarning = skipModWarning or false
	}
end

-- Tell the launcher to open the connection to the server so the MPGameNetwork can connect to the launcher once ready. This starts the setup and download of mods and other session related data.
-- @param ip string The IP/URL of the server
-- @param port number The Port of the server
-- @param name string The Name of the server (Used at the top of the screen when in session)
-- @param skipModWarning boolean If the mod security warning should be skipped
-- @usage MPCoreNetwork.connectToServer('localhost', 30814, 'Test Server', false)
local function connectToServer(ip, port, name, skipModWarning)
	if isMpSession then log('W', 'connectToServer', 'Already in an MP Session! Leaving server!') M.leaveServer() end

	if ip and port then -- Direct connect
		currentServer = nil
		setCurrentServer(ip, port, name, skipModWarning)
	else
		log('E', 'connectToServer', 'IP and PORT are required for connecting to a server.')
		return
	end

	local ipString = currentServer.ip..':'..currentServer.port
	send('C'..ipString..'')

	log('M', 'connectToServer', "Connecting to server "..ipString)
	status = "waitingForResources"
	
	guihooks.trigger('clearChatHistory')
end

--- Parse the map file name into its loadable string form and return it.
--- @param string The Map file
--- @treturn string the maps misFilePath
--- @usage `MPCoreNetwork.parseMapName(<map>)`
--- @todo this needs finishing and using.
local function parseMapName(map) -- TODO: finish
	local mapName = string.lower(map)
	if string.match(mapName, '/(.*).mis') then
		mapName = string.match(mapName, '/(.*)/') or mapName
	end
	mapName = mapName:gsub(' ', '_')
	mapName = mapName:gsub('levels/', '')
	mapName = mapName:gsub('info.json', '')
	mapName = mapName:gsub('.mis', '')
	mapName = mapName:gsub('/', '')
	for _,v in pairs(core_levels.getList()) do
		if string.match(string.lower(v.misFilePath), map) or string.match(string.lower(v.misFilePath), mapName) then
			log('M', 'loadLevel', 'Found match!')
			log('M', 'loadLevel', mapName..' matches '..v.misFilePath)
			return v.misFilePath
		end
	end
end

--- Load the desired map/level by name.
-- @param map string The Map String
-- @usage MPCoreNetwork.loadLevel('/levels/gridmap_v2/info.json')
local function loadLevel(map)
	if getMissionFilename() ~= "" then log("W","loadLevel", "REMOVING ALL VEHICLES") core_vehicles.removeAll() end -- remove old vehicles if joining a server with the same map

	log("W","loadLevel", "loading map " ..map)
	log('W', 'loadLevel', 'Loading level from MPCoreNetwork -> freeroam_freeroam.startFreeroam')

	spawn.preventPlayerSpawning = true -- don't spawn default vehicle when joining server

	currentServer.map = map

	--local parsedMapName = parseMapName(map)

	if freeroam_freeroam.onPlayerCameraReady ~= nop then -- temp fix for traffic spawning in MP
		originalFreeroamOnPlayerCameraReady = freeroam_freeroam.onPlayerCameraReady
		freeroam_freeroam.onPlayerCameraReady = nop
	end

	if getMissionFilename() == map then --or string.match(getMissionFilename(), parsedMapName) then
		log('W', 'loadLevel', 'Requested map matches current map, rejoining')
		runPostJoin()
		return
	end
	if not core_levels.expandMissionFileName(map) then --and not parsedMapName then
		UI.updateLoading("lMap "..map.." not found. Check your server config.")
		status = ""
		M.leaveServer()
		return
	else
		log('W', 'loadLevel', 'not core_levels.expandMissionFileName')
		--map = parsedMapName
	end

	freeroam_freeroam.startFreeroam(map)
	status = "LoadingMapNow"
end

--- Seamless map switch (LAN). Triggered by the server's `onMapChange` event. Loads the
--- new level in place: the old level is unloaded (its memory freed), but the mounted
--- car/physics mods, the launcher sockets and the GE Lua VM all stay alive -- so there's
--- no mod re-download, no reconnect and no Lua reload. The server-ack + car re-spawn run
--- in runPostJoin once the new level is live.
--- @param newMap string the target level path (e.g. /levels/italy/info.json)
--- @param generation number the server session generation to ack

-- Delete the current level's Forest object(s) up-front, BEFORE the level teardown. On unload
-- the engine runs ForestData::clear AFTER the tree shape instances are already freed, which
-- logs "Missing shapeinstance" once per item -- ~11k lines for a big forested map, enough to
-- single-handedly trip BeamNG's 15000-line/file log cap and freeze the log mid-switch (so we
-- couldn't even tell if the new map finished loading). Deleting the forest now, while its
-- instances are still valid, makes that later clear a no-op -> no spam. Best-effort: the trees
-- are about to vanish with the level anyway, and a pcall keeps a failure from blocking the switch.
local function preClearForest()
	local ok, err = pcall(function()
		if not (scenetree and scenetree.findClassObjects) then return end
		local forests = scenetree.findClassObjects("Forest")
		if not forests then return end
		local n = 0
		for _, name in ipairs(forests) do
			local f = scenetree.findObject(name)
			if f then f:delete(); n = n + 1 end
		end
		if n > 0 then log('I', 'preClearForest', 'Cleared '..n..' forest object(s) before map unload (avoids ForestData log spam)') end
	end)
	if not ok then log('W', 'preClearForest', 'forest pre-clear skipped: '..tostring(err)) end
end

local function beginMapTransition(newMap, generation)
	if not isMpSession then return end
	if not newMap or newMap == "" then return end
	-- Already mid-transition: ignore the duplicate (the in-flight switch will finish).
	-- Stops an impatient re-type of /map during the (possibly long) load from stacking.
	if isChangingMap then
		log('W', 'beginMapTransition', 'Already changing map; ignoring duplicate request')
		mapGeneration = tonumber(generation) or mapGeneration
		return
	end
	-- Gate on RELIABLE signals, not status=="Playing": in heavy-mod sessions `status` can
	-- lag at "LoadingMapNow" even after the join fully completes (isGoingMpSession=false,
	-- a level is loaded, player driving) -- which silently dropped the switch. Accept the
	-- switch once the initial join is done (isGoingMpSession false) AND a level is loaded.
	-- While still joining, the normal handshake delivers the current map, so skip.
	if isGoingMpSession or getMissionFilename() == "" then
		log('W', 'beginMapTransition', 'Not ready for map change yet (status="'..tostring(status)..'", joining); ignoring')
		mapGeneration = tonumber(generation) or mapGeneration
		return
	end
	log('W', 'beginMapTransition', 'Seamless map switch to '..newMap..' (generation '..tostring(generation)..')')
	mapGeneration = tonumber(generation) or 0
	isChangingMap = true
	mapTransitionTimer = 0
	-- Feedback: a big modded level can take a while to load, so tell the player it's
	-- working (the engine loading screen also shows once startFreeroam kicks in).
	local shortName = newMap:match("/levels/([^/]+)/") or newMap
	if UI and UI.showNotification then UI.showNotification("Switching map to "..shortName.."...", nil, "map") end
	if UI and UI.updateLoading then UI.updateLoading("lSwitching map to "..shortName.."...") end
	-- Also drop a persistent chat line: a big map can take a minute+ to load and the toast
	-- fades, so this gives the player a standing "it's working" record (the prior complaint
	-- was "no message after switching"). The "now on X" confirmation lands in runPostJoin.
	if UI and UI.chatMessage then UI.chatMessage(":Server: Switching map to "..shortName.." -- large maps can take a minute to load, please wait...") end
	-- Drop the networked vehicle tables (the level reload despawns the actual cars) but
	-- keep the player roster. Marking this a "rejoin" stops onClientEndMission from
	-- tearing the session down when the old level unloads.
	if MPVehicleGE and MPVehicleGE.clearVehiclesForMapChange then MPVehicleGE.clearVehiclesForMapChange() end
	preClearForest() -- delete the old forest now (valid instances) so teardown doesn't spam the log
	isGoingMpSession = true
	-- pcall the level load: if a BeamNG API loadLevel relies on (core_levels/freeroam_freeroam/
	-- core_vehicles) ever changes, a switch must NOT throw out of the event handler and wedge
	-- the session. On failure, abort the switch cleanly, re-arm spawning, stay on the current
	-- map, and tell the player -- the 60s watchdog is the backstop if loadLevel hangs instead.
	local okLoad, loadErr = pcall(loadLevel, newMap)
	if not okLoad then
		log('E', 'beginMapTransition', 'loadLevel failed ('..tostring(loadErr)..'); aborting switch, staying on current map')
		isChangingMap = false
		isGoingMpSession = false
		mapTransitionTimer = 0
		pcall(function() if spawn then spawn.preventPlayerSpawning = false end end)
		if UI and UI.chatMessage then UI.chatMessage(":Server: Map switch failed (see console) -- staying on the current map.") end
	end
end

-- VV============= OTHERS =============VV

--- Handles the storing of the port received from the launcher that is where the http proxy is located on.
-- @param port number the port number received from the launcher.
local function setProxyPort(port)
	log('M', 'setProxyPort', 'HTTP Proxy Port Received: ' .. port)
	proxyPort = port
end

--- Handles the returning of the port received from the launcher that is where the http proxy is located on.
local function getProxyPort()
	return proxyPort
end

--- Handles the login result received from the launcher.
-- @param params string The JSON-encoded login results.
local function loginReceived(params)
	--log('M', 'loginReceived', 'Logging result received')
	local result = jsonDecode(params)
	if not result then return end
	if (result.success == true or result.Auth == 1) then
		log('M', 'loginReceived', 'Login successful.')
		loggedIn = true
		guihooks.trigger('LoggedIn', result.message or '')
	else
		log('M', 'loginReceived', 'Login failed.')
		loggedIn = false
		guihooks.trigger('LoginError', result.message or '')
	end

	authResult = result
	-- LAN-only build: there is no online avatar/forum service. We skip the avatar
	-- request, which would otherwise block the game thread trying to reach the
	-- internet through the launcher's HTTP proxy. Roles are always "USER" locally,
	-- so the role-color lookup below is effectively a no-op but kept for safety.
	if authResult.username then
		if authResult.role and authResult.role ~= "USER" then
			local roleInfo = MPVehicleGE.getRoleInfoTable()[authResult.role]
			local roleColor = roleInfo and roleInfo.backcolor
			if roleColor then
				authResult.color = "rgba(" .. roleColor.r .. "," .. roleColor.g .. "," .. roleColor.b .. "," .. (roleColor.a or 127)/255 .. ")"
			end
		end
	end

	guihooks.trigger('authReceived', authResult)
end

-- Enable making a http request on demand
local function makeRequest (e, p, r)
	local res = {}; 
	local _, code, headers = http.request{
		url = "http://localhost:".. proxyPort .."/"..e.."/"..p, 
		sink = ltn12.sink.table(res)
	}; 
	local ret = {}
	ret["code"] = code
	ret["body"] = res
	guihooks.trigger(r, ret)
end

--- Returns the result from authentication, which includes the user's name, beammp id and role
local function getAuthResult()
	return authResult
end

--- Leaves the server and performs necessary cleanup.
-- @param goBack boolean Whether to go back to the previous screen after leaving the server.
-- @usage MPCoreNetwork.leaveServer(true)
local function leaveServer(goBack)
	log('W', 'leaveServer', 'Reset Session Called! goBack: ' .. tostring(goBack))
	send('QS') -- Quit session, disconnecting MPCoreNetwork socket is not necessary
	extensions.hook('onServerLeave')
	isMpSession = false
	isGoingMpSession = false
	loadMods = false
	currentServer = nil
	status = "" -- Reset status
	updateUiTimer = 0
	UI.updateLoading("")
	MPGameNetwork.disconnectLauncher()
	MPVehicleGE.onDisconnect()
	local callback = nop
	--if not settings.getValue("disableLuaReload") then callback = function() MPModManager.reloadLuaReloadWithDelay() end end
	callback = function() MPModManager.reloadLuaReloadWithDelay() end -- force lua reload every time until a proper fix is introduced
	if goBack then endActiveGameMode(callback) end
end

--- Informs the Launcher that we do not want to download the mods from this server.
-- @usage MPCoreNetwork.rejectModDownload()
local function rejectModDownload()
	if status == "waitingForResources" then
		send('WN') -- Inform the Launcher that we decline
		isMpSession = false
		isGoingMpSession = false
		loadMods = false
		currentServer = nil
		status = "" -- Reset status
		updateUiTimer = 0
		UI.updateLoading("")
	end
end

--- Informs the Launcher that we do not want to download the mods from this server.
-- @usage MPCoreNetwork.approveModDownload()
local function approveModDownload()
	if status == "waitingForResources" then
		send('WY') -- Inform the Launcher that we accept the risk
	end
end


--- Returns if the current session is a multiplayer session / if we expect to be in one.
-- @return boolean isMpSession True if it is a multiplayer session, false otherwise.
-- @usage if MPCoreNetwork.isMPSession() then `code` end
local function isMPSession()
	return isMpSession
end

--- Returns if the game is currently transitioning to a multiplayer session.
-- @return boolean isGoingMpSession True if transitioning to a multiplayer session, false otherwise.
-- @usage if MPCoreNetwork.isGoingMPSession() then `code` end
local function isGoingMPSession()
	return isGoingMpSession
end

-- AA============= OTHERS =============AA

--- Requests the map from the launcher
-- @usage MPCoreNetwork.requestMap()
local function requestMap()
	log('M', 'requestMap', 'Requesting map!')
	send('M') -- request map string from launcher 
	status = "LoadingMap"
	loadMods = false
end

--- Handles the update of the loading UI and performs necessary actions based on the received parameters.
-- @param params string The parameters received for updating the loading UI.
-- @usage MPCoreNetwork.handleU('lstart')
local function handleU(params)
	UI.updateLoading(params)
	local code = string.sub(params, 1, 1)
	local data = string.sub(params, 2)
	if code == "l" then
		if data == "start" then
		end
		if string.match(data, 'Loading') then send('R'..math.random()) end --get the launcher to copy all the mods without loading them one by one
		if data == "done" and status == "LoadingResources" and not loadMods then --load all the mods once they have been copied over
			loadMods = true
			MPModManager.loadServerMods()
		end
		--if string.sub(data, 1, 17) == "Connection Failed" then
		--	leaveServer(false) -- reset session variables
		--end
	elseif code == "p" and isMpSession then
		UI.setPing(data.."")
		positionGE.setPing(data)
	end
end

--- Prompts the user for auto join confirmation.
-- @param params string The parameters received for auto join confirmation.
-- @usage MPCoreNetwork.promptAutoJoin(`...`)
local function promptAutoJoin(params)
	UI.promptAutoJoinConfirmation(params)
end

local function handleModWarning(params)
	if params == 'MODS_FOUND' and settings.getValue("skipModSecurityWarning", false) == false and not currentServer.skipModWarning then
		guihooks.trigger('DownloadSecurityPrompt', params) 
	else 
		send('WY') 
	end
end

-- VV============= EVENTS =============VV

--- Handle network message events.
--- @param code string The network message code
--- @param params string The network message content/parameters
--- @usage `HandleNetwork[<code>]('<params>')`
local HandleNetwork = {
	['A'] = function(params) receiveLauncherHeartbeat() end, -- Launcher heartbeat
	['B'] = function(params) serverList = params; sendBeamMPInfo() end, -- Server list received
	['J'] = function(params) promptAutoJoin(params) end, -- Automatic Server Joining
	['L'] = function(params) setMods(params) status = "LoadingResources" end, --received after sending 'C' packet
	['M'] = function(params)
		log('W', 'HandleNetwork', 'Received Map! '..params)
		-- pcall so a loadLevel failure (e.g. a renamed BeamNG API) logs one clear line instead
		-- of an opaque stack trace through the network handler; the compat self-check explains why.
		local ok, err = pcall(loadLevel, params)
		if not ok then log('E', 'HandleNetwork', 'loadLevel failed on join ('..tostring(err)..'); the BeamNG API compatibility check above lists any missing APIs') end
	end,
	['N'] = function(params) loginReceived(params) end,
	['P'] = function(params) setProxyPort(params) end,
	['U'] = function(params) handleU(params) end, -- Loading into server UI, handles loading mods, pre-join kick messages and ping
	['W'] = function(params) handleModWarning(params) end,
	['Z'] = function(params) launcherVersion = params; end,
}

local recvState = {
	-- 'ready': ready to receive a new packet, data is contained within `data` if any
	-- 'partial': `partialData` contains data, we're missing `missing` bytes
	-- 'error': errorneous state
	state = 'ready',
	data = "",
	missing = 0,
}


--- onUpdate is a game eventloop function. It is called each frame by the game engine.
-- This is the main processing thread of BeamMP in the game
-- @param dt float
-- Poll the GPU's tracked graphics memory and warn (once per high-water crossing) when it
-- gets close to the card's total -- the next big map load/switch is what tips a near-full
-- card into the resource-exhaustion crash. Engine.Render.calculateGfxMemory() sums BeamMP's
-- per-category gfx allocations (an underestimate of true VRAM pressure, so a conservative
-- signal); Engine.Platform.getGPUInfo().memoryMB is the card total. Best-effort: if the
-- engine APIs are missing/changed on a build, it disables itself silently (never spams).
local function checkVramHeadroom()
	if vramTotalMB == -1 then return end -- API unavailable on this build; gave up earlier
	local ok = pcall(function()
		if not vramTotalMB then
			local gpu = Engine and Engine.Platform and Engine.Platform.getGPUInfo and Engine.Platform.getGPUInfo()
			vramTotalMB = (gpu and tonumber(gpu.memoryMB)) or 0
		end
		if not vramTotalMB or vramTotalMB <= 0 then vramTotalMB = -1; return end -- can't read total
		local res = Engine and Engine.Render and Engine.Render.calculateGfxMemory and Engine.Render.calculateGfxMemory()
		if type(res) ~= 'table' then vramTotalMB = -1; return end
		local usedMB = 0
		for _, v in pairs(res) do usedMB = usedMB + (tonumber(v) or 0) end
		usedMB = usedMB / 1048576
		if usedMB <= 0 then return end
		local pct = usedMB / vramTotalMB
		if pct >= 0.85 and not vramWarned then
			vramWarned = true
			local msg = string.format("High VRAM use: %.1f / %.1f GB (%d%%). Switching/loading maps may crash the game -- consider fewer mods or maps.",
				usedMB / 1024, vramTotalMB / 1024, math.floor(pct * 100))
			log('W', 'checkVramHeadroom', msg)
			if UI then
				if UI.showNotification then UI.showNotification(msg, nil, "warning") end
				if UI.chatMessage then UI.chatMessage(":Warning: "..msg) end
			end
		elseif pct < 0.78 then
			vramWarned = false -- recovered (e.g. a map unloaded); re-arm the warning
		end
	end)
	if not ok then vramTotalMB = -1 end -- engine API threw; disable to avoid log spam
end

local function onUpdate(dt)
	pingTimer = pingTimer + dt
	reconnectTimer = reconnectTimer + dt
	-- VRAM headroom warning (opt-out via showVramWarning); poll occasionally, not per-frame
	-- (calculateGfxMemory walks all gfx resources). Only while in a session.
	if isMpSession and settings.getValue('showVramWarning') ~= false then
		vramCheckTimer = vramCheckTimer + dt
		if vramCheckTimer >= 15 then
			vramCheckTimer = 0
			checkVramHeadroom()
		end
	end
	if status == "LoadingResources" then
		updateUiTimer = updateUiTimer + dt
	end
	heartbeatTimer = heartbeatTimer + dt
	-- Seamless map switch watchdog: if the new level never finishes loading, fall back to
	-- a clean full leave so the client can't get stuck mid-transition.
	if isChangingMap then
		mapTransitionTimer = mapTransitionTimer + dt
		if mapTransitionTimer > MAP_TRANSITION_TIMEOUT then
			log('E', 'onUpdate', 'Map transition timed out after '..MAP_TRANSITION_TIMEOUT..'s; leaving server')
			isChangingMap = false
			mapTransitionTimer = 0
			leaveServer(true)
		end
	end
	--====================================================== DATA RECEIVE ======================================================
	if launcherConnected then
		if TCPLauncherSocket ~= nop then
			while(true) do
				recvState = MPNetworkHelpers.receive(TCPLauncherSocket, recvState)
				if recvState.state == 'error' then
					-- error! :(
					break
				end
				if recvState.state ~= 'ready' then
					-- full packet NOT received, retry
					break
				end
				if recvState.data == "" then
					break
				end

				local received = recvState.data

				if settings.getValue("showDebugOutput") then -- TODO: add option to filter out heartbeat packets
					log('M', 'onUpdate', 'Receiving Data ('..#received..'): '..received)
				end

				-- break it up into code + data
				local code = string.sub(received, 1, 1)
				local data = string.sub(received, 2)
				
				if settings.getValue("showDebugOutput") then -- TODO: add option to filter out heartbeat packets
					log('M', 'onUpdate', 'Receiving Data ([' .. code .. '] ' .. #received .. '): ' .. received)
				end
				
				if not HandleNetwork[code] then
					log('E', 'onUpdate', 'Received corrupted packet fragment ([' .. code .. '] ' .. #received .. '): ' .. received)
				else
					HandleNetwork[code](data)
				end
			end
		end
		--================================ SECONDS TIMER ================================
		if heartbeatTimer >= 1 then
			heartbeatTimer = 0
			send('A') -- Launcher heartbeat
		end
		if updateUiTimer >= 0.1 and status == "LoadingResources" then
			updateUiTimer = 0
			send('Ul') -- Ask the launcher for a loading screen update
		end
		if MPGameNetwork and MPGameNetwork.launcherConnected() and pingTimer >= 1 and isMPSession() then
			pingTimer = 0
			send('Up')
		end
	else
		if isConnecting then
			-- socket exists but handshake is still completing; retry heartbeat frequently
			if reconnectTimer >= 0.25 then
				reconnectTimer = 0
				send('A') -- succeeds once connected, fires onLauncherConnected
			end
		elseif reconnectAttempt < 10 and reconnectTimer >= 2 then
			-- no socket or socket died; create a fresh one
			reconnectAttempt = reconnectAttempt + 1
			reconnectTimer = 0
			connectToLauncher(true)
		end
	end
end

-- EVENTS

-- ============================ BeamNG API compatibility self-check ============================
-- This mod is tightly coupled to BeamNG engine/core APIs (core_levels, core_vehicles,
-- freeroam_freeroam, Engine.*, scenetree, ...). A future BeamNG upgrade that renames or removes
-- one of them otherwise surfaces as a cryptic mid-session stack trace. This runs once at session
-- start, verifies the APIs the critical paths depend on, and logs ONE clear report naming exactly
-- what's missing -- turning "BeamMP mysteriously broke after the BeamNG update" into an actionable
-- "BeamNG no longer provides <api> (powers <feature>); this BeamMP build needs an update." It does
-- NOT change behavior -- pure diagnostics -- so it can't itself regress anything.
local compatChecked = false
-- { dotted path, kind ('function'|'table'), feature it powers, optional? }
-- Optional = a best-effort feature that already self-disables if the API is gone (warn, not error).
local requiredBeamNGApis = {
	{ 'getMissionFilename',                'function', 'level load / switch' },
	{ 'core_levels.getList',               'function', 'map-name matching' },
	{ 'core_levels.expandMissionFileName', 'function', 'level load' },
	{ 'core_vehicles.removeAll',           'function', 'join cleanup' },
	{ 'core_vehicles.spawnDefault',        'function', 'map-switch car respawn' },
	{ 'freeroam_freeroam.startFreeroam',   'function', 'level load' },
	{ 'core_gamestate.setGameState',       'function', 'multiplayer session state' },
	{ 'extensions.hook',                   'function', 'session lifecycle hooks' },
	{ 'guihooks.trigger',                  'function', 'UI events' },
	{ 'spawn',                             'table',    'default-spawn gating' },
	{ 'scenetree.findClassObjects',        'function', 'forest pre-clear (log de-spam)', true },
	{ 'scenetree.findObject',              'function', 'forest pre-clear (log de-spam)', true },
	{ 'Engine.Render.calculateGfxMemory',  'function', 'VRAM warning',                   true },
	{ 'Engine.Platform.getGPUInfo',        'function', 'VRAM warning',                   true },
}

-- Resolve a dotted path ("a.b.c") against the global env, never erroring on a nil mid-path.
local function resolveApi(path)
	local cur = _G
	for part in string.gmatch(path, '[^.]+') do
		if type(cur) ~= 'table' then return nil end
		cur = cur[part]
		if cur == nil then return nil end
	end
	return cur
end

local function checkBeamNGCompat()
	if compatChecked then return end
	compatChecked = true
	local missingReq, missingOpt = {}, {}
	for _, a in ipairs(requiredBeamNGApis) do
		local path, kind, feature, optional = a[1], a[2], a[3], a[4]
		local v = resolveApi(path)
		local okType = (kind == 'table' and type(v) == 'table') or (kind == 'function' and type(v) == 'function')
		if not okType then table.insert(optional and missingOpt or missingReq, path..' ('..feature..')') end
	end
	if #missingReq > 0 then
		log('E', 'checkBeamNGCompat', 'This BeamNG build is missing '..#missingReq..' API(s) BeamMP depends on -- the mod may misbehave and likely needs an update for this BeamNG version:')
		for _, m in ipairs(missingReq) do log('E', 'checkBeamNGCompat', '  MISSING (required): '..m) end
	end
	if #missingOpt > 0 then
		log('W', 'checkBeamNGCompat', #missingOpt..' optional API(s) unavailable; the related BeamMP feature self-disables (no crash):')
		for _, m in ipairs(missingOpt) do log('W', 'checkBeamNGCompat', '  unavailable (optional): '..m) end
	end
	if #missingReq == 0 and #missingOpt == 0 then
		log('I', 'checkBeamNGCompat', 'BeamNG API compatibility OK ('..#requiredBeamNGApis..' APIs present).')
	end
	return missingReq, missingOpt
end

--- onLauncherConnected is an event which is called by internal scripts. This one is called when connection to the launcher is established
--- @usage INTERNAL ONLY / GAME SPECIFIC
onLauncherConnected = function()
	loggedIn = false
	reconnectAttempt = 0
	log('W', 'onLauncherConnected', 'onLauncherConnected')
	log('W', 'onLauncherConnected', '==== BeamMP LAN fork '..modVersion..' loaded ===='); log('I', 'onLauncherConnected', modPatchNote)
	checkBeamNGCompat() -- once-per-session: verify BeamNG APIs still exist, log what's missing
	send('Z') -- request launcher version
	send('P') -- request launcher proxy port
	requestServerList()
	extensions.hook('onLauncherConnected')
	guihooks.trigger('onLauncherConnected')
	autoLogin()
	if isMpSession and currentServer then
		connectToServer(currentServer.ip, currentServer.port, currentServer.name)
	end
end

--- runPostJoin is an event which is called by internal scripts. This one is called when the game has finishing loading into a map as part of loading into a session
--- @usage INTERNAL ONLY / GAME SPECIFIC
runPostJoin = function() -- gets called once loaded into a map
	log('W', 'runPostJoin', 'isGoingMpSession: '..tostring(isGoingMpSession))
	log('W', 'runPostJoin', 'isMpSession: '..tostring(isMpSession))
	if freeroam_freeroam.onPlayerCameraReady == nop and originalFreeroamOnPlayerCameraReady then -- restore function to original once already loaded in so it works if user switches to freeroam
		freeroam_freeroam.onPlayerCameraReady = originalFreeroamOnPlayerCameraReady
	end
	if isMpSession and isGoingMpSession then
		extensions.hook('runPostJoin')
		spawn.preventPlayerSpawning = false -- re-enable spawning of default vehicle so it gets spawned if the user switches to freeroam
		MPGameNetwork.connectToLauncher()
		log('W', 'runPostJoin', 'isGoingMpSession = false')
		isGoingMpSession = false
		-- pcall: in heavy-mod sessions a mod's gamestate hook can throw here, which
		-- previously aborted runPostJoin BEFORE status="Playing" and the map-switch ack
		-- below (so the switch loaded but the client stayed fenced/carless, and status
		-- got stuck at "LoadingMapNow"). Never let setGameState kill the rest.
		local okGs, gsErr = pcall(core_gamestate.setGameState, 'multiplayer', 'multiplayer', 'multiplayer')
		if not okGs then log('E', 'runPostJoin', 'setGameState failed (continuing): '..tostring(gsErr)) end
		status = "Playing"
		-- Seamless map switch: we're now live on the new level. Tell the server we're
		-- ready (clears its stale-packet fence) and arm a deferred re-spawn of our car.
		-- The sockets, mounted mods and Lua VM were never torn down, so this resumes the
		-- existing session in place -- no reconnect, no mod re-sync, no Lua reload.
		if isChangingMap then
			isChangingMap = false
			mapTransitionTimer = 0
			MPGameNetwork.send("Mr"..tostring(mapGeneration)) -- map-ready ack
			if MPVehicleGE and MPVehicleGE.beginMapRespawn then MPVehicleGE.beginMapRespawn() end
			-- Completion feedback (pairs with the "Switching map..." line from beginMapTransition)
			local nowName = (getMissionFilename() or ""):match("/levels/([^/]+)/") or "the new map"
			if UI and UI.showNotification then UI.showNotification("Map switched to "..nowName, nil, "map") end
			if UI and UI.chatMessage then UI.chatMessage(":Server: Map switched to "..nowName..".") end
		end
		guihooks.trigger('onServerJoined')
	end
end

--- This event is called as part of the games level loading process. It also works as the start event which can be paired with the end event onClientEndMission
--- @usage `extensions.hook('onClientStartMission')`
local function onClientStartMission()
	if isMpSession and isGoingMpSession then runPostJoin() end
end

--- Executes when the user or mod ends a mission/session (map) .
-- @param mission table The mission object.
local function onClientEndMission(mission)
	log('W', 'onClientEndMission', 'isGoingMpSession: '..tostring(isGoingMpSession))
	log('W', 'onClientEndMission', 'isMpSession: '..tostring(isMpSession))
	if not isGoingMpSession then -- leaves server when loading into another freeroam map from an MP sesison
		leaveServer(false)
	end
end

--- Serializes data for saving to be loaded on lua reload. Allows for lua state memory persistence between reloads
-- @return table The serialized data.
local function onSerialize()
	return {currentServer = currentServer,
			isMpSession = isMpSession}
end

--- Deserializes data after loading lua state. Allows for lua state memory persistence between reloads
-- @param data table The deserialized data.
local function onDeserialized(data)
	log('M', 'onDeserialized', dumps(data))

	currentServer = data and data.currentServer or nil
	isMpSession = data and data.isMpSession

	if isMpSession and currentServer then
		log('I', 'onDeserialized', 'reconnecting')
	end
end

--- Triggered by BeamNG when the lua mod is loaded by the modmanager system.
-- We use this to load our UI info and connect to the launcher
local function onExtensionLoaded()
	connectToLauncher(true)
	reloadUI() -- required to show modified mainmenu
end

-- TODO: remove functions that shouldnt be public
-- launcher
M.connectToLauncher    = connectToLauncher
M.disconnectLauncher   = disconnectLauncher
M.isLauncherConnected  = isLauncherConnected
M.getLauncherVersion   = getLauncherVersion
M.getProxyPort         = getProxyPort
-- security
M.rejectModDownload    = rejectModDownload
M.approveModDownload   = approveModDownload
-- auth
M.login                = login
M.autoLogin            = autoLogin
M.setPlayerName        = setPlayerName
M.getLoginState        = getLoginState
M.logout               = logout
M.isLoggedIn           = isLoggedIn
M.getAuthResult        = getAuthResult
-- events
M.onExtensionLoaded    = onExtensionLoaded
M.onUpdate             = onUpdate
M.onClientEndMission   = onClientEndMission
M.onClientStartMission = onClientStartMission
-- UI
M.openURL              = openURL
M.makeRequest          = makeRequest
M.sendBeamMPInfo       = sendBeamMPInfo
M.requestPlayers       = requestPlayers
M.requestServerList    = requestServerList
-- server
M.connectToServer      = connectToServer
M.leaveServer          = leaveServer
M.beginMapTransition   = beginMapTransition -- seamless map switch (server onMapChange handler)
M.getCurrentServer     = getCurrentServer
M.isMPSession          = isMPSession
M.isGoingMPSession     = isGoingMPSession
M.getModVersion        = function() return modVersion end

M.onSerialize          = onSerialize
M.onDeserialized       = onDeserialized

M.requestMap           = requestMap
M.send                 = send
M.onInit = function() setExtensionUnloadMode(M, "manual") end

-- TODO: finish all this

return M
