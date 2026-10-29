# BeamNG.Earth native BeamMP support on the LAN fork — compatibility record

Started 2026-10-23. Mod p13h109-p13h111 (base h108 `df61f559`), combined host p13h46 (stacked on the uncommitted
p13h45 late-join fix), game BeamNG 0.40.3.0.290897, BeamNG.Earth 1.6.0-beta (tag `b4c478d`, server package
`BeamNG.Earth-BeamMP-Server-1.6.0-beta.zip` SHA256 `2efcc5e6…8139`, copy in the workspace `dist/earth/`).

The Codex bridge in `experiments/earth-two-player` (MPEarthGE, built against Earth 1.5.x) is **not used**:
Earth 1.6.0 ships its own conversion, and running both would convert twice. Nothing from it was ported.

## How Earth plugs into BeamMP

| Earth piece | What it uses in BeamMP | Fork status |
|---|---|---|
| `mpanchor.lua` (receive conversion) | wraps `positionGE.handle(rawData)` in the global table; parses `p:<pid-vid>:{json}`; transforms `pos`/`vel`/`rvel`/`rot`; drops poses beyond 30 km | Works unchanged since h108: `MPGameNetwork` calls `positionGE.handle` through the global at call time, `handle` takes the same raw string, the payload holds exactly those four vectors (acc/racc are derived on the receiver from converted velocities), and the direct vehicle socket only SENDS. |
| `mpsession.lua` (events, hiding, damage) | `AddEventHandler(name, fn, owner)`, `TriggerServerEvent`, `MPVehicleGE.getVehicles/isOwn/restorePlayerVehicle`, `MPConfig.getPlayerServerID`, `MPCoreNetwork.isMPSession/openURL`, hook `onBeamMPPostJoin`; hides cars with `setActive(0)`; asks `nodesVE.getNodes()` for dents | Event API, exports and record fields all present. Hiding interfered with the watchdog and `getNodes` no longer existed: fixed (below). |
| `farcars.lua` | deletes and respawns the player's own far cars (normal BeamMP delete/spawn traffic) | Works unchanged. |
| `beammp.lua` | `MPCoreNetwork.isMPSession`, app-layout after `onBeamMPPostJoin` | Works unchanged. |
| server plugin `BeamNGEarth/main.lua` (Lua 5.3) | `MP.RegisterEvent`, `MP.TriggerClientEvent`, `MP.GetPlayerName`, `MP.GetPlayerIdentifiers().ip`, `MP.CreateEventTimer`, `Util.JsonEncode/Decode`, `onPlayerDisconnect` | All registered by the embedded server; `Resources/Server/<plugin>/` is loaded by the combined host. The host player's `ip` was `127.0.0.1`: fixed (below). |

Unknown client events are dropped silently (`handleEvents`), so the plugin's 2 s broadcasts cost nothing on
other maps.

## Changes, classified

| Change | Files | Class | Why |
|---|---|---|---|
| Watchdog skips deactivated ghosts and forgets their movement history | `positionGE.lua` | FIX (fork-owned watchdog) | Earth deactivates a car whose owner's origin is unknown yet and lets its packets through unconverted; the watchdog snapped the inactive car to those coordinates every second while the owner drove. A deactivated ghost runs no VE apply, so it can never be a stalled apply. |
| On-demand full-damage snapshot (`getNodes` / `'Xn'` / `applyNodes`) | `nodesVE.lua`, `nodesGE.lua` | RESTORE upstream's code + FIX for 0.40 | Earth's dents ride BeamMP's full-damage message (Earth: "BeamMP's files are not changed: its client events, its own functions"). p13h111: upstream's own `getNodes` / `sendNodes` / `applyNodes` text (h108 had deleted it), with `-- LAN:` hunks only: a `Round` fallback (no global in 0.40), the node/beam counts upstream left commented out (sent, and checked first the way `beamstate.load` checks them), `beamDeformed` guarded (not exported in 0.40), `obj:commitLoad()` (0.40's `beamstate.load` ends with it), a pcall at the GE call site. Nothing runs on a timer; the periodic 2 Hz sync removed 2026-07-09 stays removed. p13h109/p13h110 used a fork rewrite (`beamstate.save` v2 shape, 1/s limiter, `applyRemoteDamageSnapshots` option); p13h111 replaced it so BeamMP's and Earth's fixes merge cleanly (the user, 2026-10-23: minimal modifications that persist as both teams fix things). The diff against upstream is 31 added and 5 changed lines, guarded by `earth_guard.py` U1. |
| Served copy of a mod the player also has: player's copy back on and served copy off at leave; at startup an active player copy wins | `MPModManager.lua` | COMPENSATE (fork's own served-mod persistence) | The fork keeps served mods between sessions. Earth's app installs `beamng_earth`, an Earth server serves `beamng_earth.zip` (`multiplayerbeamng_earth`); after an Earth update both would be mounted in single player. Generic for any such pair; nothing is deleted. |
| The host's own player carries a LAN address for plugins; `[General] HostAddress`; one-time mismatch warning; map-switch admin recognises the in-process player | `TNetwork.cpp`, `TServer.cpp`, `Settings.*`, `TConfig.cpp`, launcher `main.cpp` | COMPENSATE (fork's combined host) | The plugin hands each player the others' addresses for shared world building (TCP 47621). The in-memory host player showed as 127.0.0.1, so LAN2 asked its own machine for the host's tiles (Earth's share code is a version fingerprint, so its own world server accepted). Choice: HostAddress > bind address when it names one interface > route address > 127.0.0.1. |

## Verification

- `tools/ge-guard/earth_guard.py` (new): 28 checks (p13h111) with the real Earth client Lua from the 1.6.0 server
  package and the real fork modules, in groups S/W/D/U/M (U: the two dents files are the last-merged upstream
  text plus hunks that each carry a `LAN:` marker). Negative controls: h108 (`--ref HEAD`) fails W1, W3, D1,
  both U1 and M2, M3 and passes the position group; `--mutate cached-dispatch` fails S2 and S4; undoing each of
  the six p13h111 hunks on its own fails D1 (Round), D1/D2/D5 (counts), D3/D4 (count check), D2 (beamDeformed),
  D2 (commitLoad), D2/D5 (pcall). The p13h109 draft of the guard found a real defect in that draft
  (`nodesGE.tick` called `flushSnapshots`, a local defined below it, i.e. a nil global on every 33 ms tick).
- A bytecode global-read scan (LuaJIT `jit.util`, GGET/GSET, every nested function) of the four touched
  modules: no new undefined global reads (validated on probe files and on the pre-fix variant).
- Existing guards on the p13h109 tree: spawn, latejoin_edit (6), traffic_rate (81), mapswitch,
  tempobjectdata (25), compat040 (5), gameplay040 (7), overlay (63): all PASS. Lua parse 42/42.
- BeamNG 0.40.3: `ui_layout_check.py` PASS (stock layout equality, 19 LAN items, idempotent rebuild) and
  `ui_compatibility_check.cjs` PASS (80 stock conditions identical); the live 0.40.3 session's log shows the
  fork's version check, banner and API self-check (14/14) clean.
- Mod zip p13h109 `DDB4F327…` (468 entries, 163 stored), verified against the source tree. p13h111 `95FDA6D1…`
  (468 entries): every other guard passes on its tree and Lua parse is 42/42; smoke gate 17/17 on it with the
  p13h46 host (2026-10-23 10:15, Utah, Earth's plugin loaded); a two-player session on it is pending. Linux
  p13h46 combined host and server built the same day (`dist/linux/BeamMP-Launcher` 71dc453f, `BeamMP-Server`
  ddeddc48).
- Server: both server builds and the combined host compiled; server unit tests 34 of 34 pass (the four
  socket-timeout cases that hang on Windows excluded), including the new address-choice test.
- Smoke gate on 0.40.3: 17 of 17 on the exact p13h109 zip and p13h46 host, with Earth's server plugin loaded:
  Server.log shows `[BeamNG.Earth] plugin loaded`, the host's own player at the auto-detected LAN
  address and `LAN auth: 'Dad' joined from` that address instead of 127.0.0.1; the client's errors
  match the h108 gate source for source. (Run on a temporary cold deploy, then rolled back.)

## Two-player session (2026-10-23, Windows host p13h109 + p13h46, Linux client p13h109)

Server: the client joined from 192.168.1.5, downloaded beamng_earth.zip, its first pose was 3 km+ from the host so the
plugin sent it to the host's place (Tempe); within 20 s the plugin put both in one generation group. Host game: 2 players
with Earth, converged onto the shared anchor, ~600 poses sent, the remote car tracked within 0.2 m of its converted
pose (posWatchdog diagnostics), the snapshot rate limit engaged for the incoming car and for the host's own car, no
snapshot rejected or failed. Client game (native Linux build, launcher still p13h43): mpanchor installed, sent to the
others, received the plugin's peer list with the host at its LAN address (whether the two world servers then exchanged
work was not recorded: the host's Earth log of that run was overwritten by the next run), a live edit of the
host's car applied, its own snapshot limit engaged once. Neither machine logged an error from fork code. Found: the
BeamMP-Session HUD app threw once a second on the client after Earth's layout switch (stale instance, page gone;
same unguarded lookups upstream) -> p13h110 guards them (`tools/ge-guard/session_app_guard.js`, HEAD fails 4 of 6
with the client's exact messages). The client's options page missed the LAN entries once and showed them after a
mod reload (a load-time glitch, not reproduced). Not exercised: a late join after an edit (p13h45).

## Second two-player session (2026-10-23 08:53-09:45, host p13h110 + p13h46, Linux client p13h110)

The host joined on Utah and switched the running session to Earth with the map switcher (generation 1); Earth started
on the host after the switch. The client joined into Earth at the same spot at 08:57 and left at 09:45:23; the log
bundles were saved mid-session (host 09:02, client 09:13), and the host's live log covers the rest except a
09:29-09:48 stretch the game's log cap dropped. Each tracked the other's car within 0.2-0.4 m (posWatchdog diagnostics
on both); the host's sync health stayed at 0.2 m drift, 0 self-heals, 0 rejected packets, ~30 updates/s applied for
the whole session. Session-bar errors: 0 on both (46 on the client before p13h110). Fork-code errors: 0 on both.

Shared world building did NOT happen. The plugin reported both players sharing one generation group ("shares
generation with 1 player(s)") and both games received the peer list (the host at 192.168.1.3), but the host's world
server never formed a group: every stats line from 09:09 to 09:51 reads `group none` with 0 tiles from or for peers
(it built 517 -> 1328 tiles alone). Candidates on Earth's side, unverified: the Windows and Linux app builds carry
different share codes (the code is a version fingerprint), or inbound TCP 47621 blocked on one machine. Needs the
client's Earth server log (`compute sharing` lines).

Edge-of-map waits, measured (host p13h108 frame records). Before the client joined: ~95 fps. With both cars present
the host fell to 10-25 fps in two long stretches (09:02-09:10 and 09:15-09:29+); its slow frames spent a median
49 ms in physics (60-108 ms at worst), against 0.2-0.5 ms otherwise; Lua, render, texture and asset phases stayed
small. Both stretches began exactly when the host's window lost focus, with the host's car parked at the spawn and
the client's car parked ~100 m away (the client's own log: 0 km/h at (119, -47) from 09:02 to 09:13); in every
focused stretch, two cars included, physics stayed under 1.2 ms. The client's machine ran the same two parked cars
at 60 fps with 0.2 ms physics. After the client left: 1 car, ~25-38 fps unfocused, physics 0.3 ms. A Linux build in
Docker (5.3 cores at normal priority, started 08:48) ran on the host the whole time, while BeamNG averaged under
2 cores, i.e. its physics was waiting, not working. Reading: CPU contention plus the loss of the foreground boost
starved the host's physics once a second car was in the session; not the fork's sync path, and not Earth's per-car
collision areas by themselves (identical geometry on the client was cheap). Earth's world server also showed the
waits: near terrain tiles 4-22 s each (the first two waited 167 s and 76 s), and the first far field 517 tiles in
13.8 min with View distance on Horizon (406 km at this spot). The build was paused about 10:00, after the client had left; a retest without it
is pending. Still not exercised: a late join after an edit, and a far teleport and return with both players present.

## Third two-player session (2026-10-23 12:01-12:14, host p13h112 + p13h46, Linux client p13h112 + launcher p13h46)

The host switched Utah -> Earth (generation 1) at 11:03 and played alone until the client joined at 12:00:58; both
bundles were saved with the client still connected (host 12:12:33, client 12:14:30; the host log's cap dropped
11:36-12:07). The client spawned its car (third-party `A6C9_2Ali`, which logs many missing meshes and materials of its
own) only at 12:09:48. Dents on p13h111's upstream snapshot code: the host applied 3 snapshots of the client's car
(~104 KB, 12:11:43-12:12:13), the client 9 of the host's (~123 KB, 12:11:28-12:14:07), each through upstream's
"Applied N bytes!" / "Node Data Should be applied!" prints; 0 rejected by the count check, 0 errors from the call-site
pcall; 10 of 12 applies had no frame over 25 ms within 0.6 s (worst 105 ms, host). Sync: drift 0.5-0.7 m, 0 heals,
0 rejected, 30 applied/s. No error and no FATAL from fork code on either machine. Earth sharing: host world server
`group none` at every stats line again.

Collision-rebuild stalls (new). While the client's parked car sat ~3 km from the host's car (client (24, -8), host
(2520, -1635), each outside the other's terrain block), five of the host's static-collision rebuilds took 18.189,
18.307, 18.517, 18.720 and 9.493 s (`PhysicsPlugin: Physics collision reloading...` -> `libbeamng.engine.staticCollision:
*** Loaded Static Collision in 18.189s, Verts 45784, Tris 84622`), each a frozen physics frame, 12:10:16-12:11:39,
until the host moved next to the client. The host's other 71 rebuilds took a median 0.002 s (one car: 67, max 0.018 s
at 165k tris); the client's 32 rebuilds stayed under 0.033 s (up to 627k tris) although its geometry was the mirror
image (the host's car 3 km away). This morning's p13h110 session had one such rebuild (12.4 s at 09:11:52, stock
Bastion ghost). The rebuilds are requested by Earth (`be:reloadCollision()` in core.lua / roads.lua / terrain.lua;
Earth's comments expect ~20-56 ms); the fork never requests one. Why only the host, and only with a distant second
car, is not known (Windows vs Linux engine, the ghost's model, the ghost outside the terrain block are the open
candidates). Not exercised again: the host window in the background with two cars (the morning's 10-25 fps case).

## BeamNG.Earth 1.6.1-beta (2026-10-24 check, mod p13h113)

Server package `BeamNG.Earth-BeamMP-Server-1.6.1-beta.zip` (sha256 `75f724fe...0b9f`, matches the release digest; copy
in the workspace `dist/earth/`; tag `v1.6.1-beta` = `a08461b`). **Compatible:** `earth_guard.py --earth-zip` with it
passes all 30 checks (position seam, watchdog incl. W4, dents path -- Earth's damage command is unchanged, upstream
shape, mod manager). Its BeamMP surface is the same as 1.6.0's: AddEventHandler / TriggerServerEvent,
positionGE.handle, nodesVE.getNodes, MPCoreNetwork.isMPSession, MPVehicleGE.isOwn / getVehicles /
restorePlayerVehicle, MPConfig.getPlayerServerID, onBeamMPPostJoin / onBeamMPServerLeave; the server plugin uses
the same five MP.* calls. New in 1.6.1 and reviewed:
- `simhold.lua`: in a BeamMP session the drop hold / edge guard hold only the player's OWN car (`setActive(0)`)
  instead of pausing the game (the pause froze everyone's cars). Remote players see that car stop (no packets while
  held); their watchdog does not heal it (no fresh positions). Watch item: upstream BeamMP's local-spawn echo
  (`MPVehicleGE.onServerVehicleSpawned`, same code upstream) deletes a local car that is inactive when the server's
  confirmation arrives -- only possible if a hold starts within the spawn's round trip; log line "Local vehicle
  ... does not exist anymore".
- removed remote cars stay removed (restore only for cars deleted while far, at most RESTORE_MAX); damage on join only
  for damaged cars; the sharing port comes from the plugin (`G.SHARE_PORT`, default 47621); the app reloads the
  game's Lua when it starts after the game with a just-installed/updated/re-enabled mod (start it before joining,
  as Earth's notes say).
**Not changed in 1.6.1:** `terrainpatch.lua` and `collisionfoci.lua` are byte-identical to 1.6.0 and `core.lua` still
passes `dtReal` to `terrainpatch.update`, so the off-block ground patches and their stale-patch clock -- the host's
13-50 s collision rebuilds above -- can still occur. Keep players in the same area.
**Installed on the host 2026-10-23 18:4x** (host stopped): the three package files (client zip `3969F3C7`, plugin
`A2F54BF4`, README `25E67804`) replaced 1.6.0's, which were byte-identical to the 1.6.0 package and are kept in
`dist/earth/installed-1.6.0-backup/`. Smoke gate 17/17 on p13h113 with it: Server.log `File
'Resources/Client/beamng_earth.zip' has been modified, rehashing` and `[BeamNG.Earth] plugin loaded (players share
world building on TCP port 47621)`; the client downloaded and mounted the new zip. Both machines' Earth apps must
be 1.6.1 too (the player's app version must match the server's).

## BeamNG.Earth 1.7.1-beta (2026-10-29 check, mod p13h114, BeamNG 0.40.4)

Earth released 1.6.2 (10-24), 1.6.3 (10-26), 1.7.0 (10-28) and 1.7.1 (10-29). Server package
`BeamNG.Earth-BeamMP-Server-1.7.1-beta.zip` (sha256 `2712368e...7ac2`, matches the release digest; copy in
`dist/earth/`; tag `v1.7.1-beta` = `8aaf4eb`); the user installed it on the host 2026-10-29 07:04 (client zip
`3E2F97E7`, plugin `DABD0F78`: both equal the package's). The client zip grew from 99 to 181 entries.

**Compatible with the fork, no mod code change.** `earth_guard.py` (default package now 1.7.1): 37 checks pass; with
the 1.6.0 / 1.6.1 packages 30. The damage contract changed:
- 1.6.0-1.6.1 queued BeamMP's own `nodesVE.getNodes()` (the fork's p13h111 hunks make that work on 0.40).
- 1.6.2+ (`mpsession.lua` DAMAGE_VE): Earth's own vehicle-Lua command lists only the broken or bent beams
  (`{ nodes = {}, beams = { [cid+1] = { rest, broken, deformation } } }`, tens of KB instead of ~200 KB) and hands
  it to `nodesGE.sendNodes(json, id)`; the fork's upstream-shaped sender puts it on the wire as 'Xn'. On a peer
  Earth wraps `nodesGE.handle` (as mpanchor wraps `positionGE.handle`): 'n' packets are kept by Earth (applied
  once the car is in range, with repairs via RESET_PHYSICS + its own apply that grows dents in over 60 frames;
  it uses `beamstate.onBeamDeformed or beamstate.beamDeformed` itself), every other code passes through to the
  fork. The fork's `MPGameNetwork` dispatch looks `nodesGE.handle` up at call time (`['X'] = function(params)
  nodesGE.handle(params) end`), so the wrap takes effect: guard D7 proves it with the real dispatch, and the
  `--mutate cached-dispatch` control (which now also caches 'X') fails it. D6 runs Earth's real DAMAGE_VE in the
  vehicle-Lua stub (6 nodes / 8 beams: one broken, one bent by deformation, one by rest length -> exactly those
  three listed) and the fork's sender (ONE 'Xn', payload verbatim); D8 shows 'Xg' still runs the fork's path.
  BeamMP's own getNodes/applyNodes path (D1-D5) stays correct; Earth 1.7 never calls it. A receiver's fork
  `applyNodes` would reject Earth's compact state by its count check if it ever reached it (it does not).
- API surface otherwise as before (AddEventHandler/TriggerServerEvent, positionGE.handle, MPCoreNetwork.isMPSession,
  MPVehicleGE.isOwn/getVehicles/restorePlayerVehicle, MPConfig.getPlayerServerID, onBeamMPPostJoin/ServerLeave);
  the plugin uses the same five MP.* calls. New: `beammp.lua` re-activates Earth's local mod in
  onBeamMPServerLeave (the fork's p13h109 twin restore does the same and also switches the served copy off; M1-M4
  pass), and `earthServers.js` adds a "BeamNG.Earth" category to BeamMP's server browser by importing the
  fork's `beammpState.js` (`useBeamMPState`, `state.view`, `state.servers` exist), using route names
  `menu.beammp.servers/direct/current-server/tiles` (all exist in `shared/constants.js`) and the DOM classes
  `.beammp-route .sidebar .nav-btn`, `.servers-wrap`, `tr.server-row`, `.title-cell .server-title-content` (all
  present in the fork's views); it lists Earth's public servers from Earth's own list service and swaps BeamMP's
  list while its view is open; by its own design it does nothing if the page's shape differs. Not yet looked at
  in-game on the LAN menu.

**Earth fixed what the fork's sessions found** (its release notes, confirmed in the code): `terrainpatch.lua` now
builds the ground under far cars in 128 m pieces, PIECES_PER_FRAME = 2, cells shared between patches (1.6.2: "Windows
took 4-26 seconds to take in one big piece"); `simhold.lua` holds the own car by gravity off + velocity zeroed
instead of `setActive(0)` (the held car vanished); `edgeguard.lua` caps the velocity it acts on to what the car
really moved (`plausible`, SPEED_SLACK) and never holds inside RESUME_INSIDE_M (the every-frame hold/let-go
flicker, 5,484 toggles in 22 s on 2026-10-23); shared world building is off from 1.7.0 (`G.SHARE_PORT` gone), so
the `group none` finding is moot. `core.lua` still passes the smoothed `dtReal` to `terrainpatch.update`, but with
small pieces the stall it could prolong is gone in principle. Earth's app also starts a BeamMP launcher by
default from 1.6.2 (`beammpOnLaunch`): README-LAN tells LAN players what to set.

**Single-player run 2026-10-29 07:06-07:16 (host, p13h113, BeamNG 0.40.4.0 build 296339, Earth 1.7.1):** fork
clean (0 errors, 0 FATAL, API self-check 14/14, version gate compatible, p13h113 banner); joined its own host on
ranch_3_2025 and switched to Earth at 07:12 (generation 1). The one long static-collision build (40.9 s, 2.5 M
triangles) was the ranch level's load at 07:10:55, before Earth. Earth's perf log: a 2.7 s hitch (engine Render
2274 ms) and a 12.6 s "LuaPre" hitch during its teleport load, one 131 ms hitch attributing "beammp 4.4" ms
(the only BeamMP attribution of the run; "sea+trees 108"), minutes at 30-52 fps while it built, and WARNINGs
"roads tile ... building for 92 s ... the road workers may be stuck" with four faulthandler thread dumps from its
`blockworker.py roads_tile` processes: Earth's own (1.7.1's notes ask for exactly that `server.log`). No frame
diagnostics (logSyncStats off).

**Release check 2026-10-29 (p13h114 zip `EC272B49…`, deployed to both paths, BeamNG 0.40.4):** a single-player
run 08:02-08:23 on ranch_3_2025 logged no fork error (p13h114 banner, API self-check 14/14, version gate
compatible). The 17-check smoke gate then passed 17/17 on the same zip and the p13h46 host (08:27-08:29, on Utah,
Server.log `[BeamNG.Earth] plugin loaded (time real, weather real)`). A two-player session on Earth 1.7.1 is
still to come.

## Known limits and observations (not fork defects)

- **Rebase blink.** When either player's origin moves (every 15 km, or a teleport), Earth moves every vehicle
  but BeamMP's predictor still holds the last target in the old frame until the next packet (about 33 ms at
  the fork's 30 Hz), and its large-error teleport can snap the ghost toward it for a frame. Same predictor
  logic as upstream; watch for it in the two-player test.
- A player without the Earth app has no origin: their cars stay hidden for everyone (Earth's rule).
- Shared world building (Earth 1.6.0-1.6.1, TCP 47621) was never seen working between the Windows and Linux
  apps (second and third sessions above); Earth switched it off from 1.7.0.
- With a second car a few km away, the host's collision rebuilds took 9-50 s each on Earth 1.6.0-1.6.1 (third
  session and the 2026-10-23 lockups above); driving together avoided it. Earth 1.6.2+ builds that ground in
  128 m pieces; not yet measured here with two players.
- Upstream 4.23.1 turns the game's MCP off in a session; the fork never adopted that, so the smoke harness
  and Earth's status file keep working.

## For upstream (not sent)

### Collision review, 2026-10-23 evening (proposal; no runtime changes)

The later h112 / BeamNG 0.40.3 session confirms repeated native collision-build blocking.
The saved 16:52 session log contains 25 initially fast builds (0.067 s total), followed by
21 consecutive slow builds (590.531 s total, 15.226–35.886 s each), consuming 99.16% of that
595.53-second span. The user's quoted first seven total exactly 174.396 s. The preceding
PhysicsPlugin extraction takes milliseconds; `libbeamng.engine.staticCollision` takes the
seconds. The log continues advancing, so this establishes severe repeated blocking, not a
deadlock. The earlier 15:47 session contains 31 slow builds totaling 2004.700 s, max 133.518 s.
Both stalled sessions have no mpFrame diagnostic records. Snapshots, hashes, full collision
population and exact line references are preserved in workspace
`tools/artifacts/earth-collision-review/LOG-FINDINGS.md` and `collision-rebuilds.json`.

The strongest geometry lead is **off-block ground patches**, not exclusively roads/buildings.
Two `737_100` aircraft spawned before the slowdown. The first `patch_*.cdae` meshes appeared
immediately before the first long rebuild. Earth's 320 m remote-vehicle island, snapped to
64 m bounds, commonly produces a 704 m square patch. Its 4 m grid contains exactly 31,329
vertices / 61,952 triangles: the repeated additions/removals in the native collision log.
This strongly identifies the extra geometry; it does not yet identify the native algorithm's
pathological cost. Installed Earth's 48 Lua-tree files match the original 1.6.0 server
package after CRLF/LF normalization.

**Corrected workaround:** Roads Off clears bridges, buildings and sidewalks but does not
disable `terrainpatch.update`, its collision requests, or trees. It can remove bridge support
while leaving this workload running. Keeping vehicles within the same local terrain area is
the cleaner temporary workaround suggested by the earlier close-versus-separated session;
it is not a guaranteed cure for every Earth stall.

Proposed bounded changes, classified by owner:

1. **FIX Earth timing:** `terrainpatch.update` advances cleanup, retry and update clocks using
   smoothed `dtReal`; its intended ten-second obsolete-patch retention can lag wall time during
   native stalls. Reuse the author's existing `beamngEarth/stopwatch.clock()` for elapsed time.
   Recompute the currently wanted set before expiry; preserve collision under wanted vehicles
   and reject obsolete/old-anchor replies. Measure retained patch population and native build
   time independently. This may reduce overlapping stale geometry; it is not proof that one
   patch will become cheap.
   Real release-module replay (`terrainpatch-clock-proof.json`): after 31.1 wall seconds but
   only 1.2 summed dtReal seconds, the obsolete patch remains and a late reply can recreate its
   collider. An in-memory-only stopwatch correction removes that patch, preserves the wanted
   patch, and ignores the late reply. Production Earth files remain unchanged.
   *Checked independently (2026-10-23 17:2x):* Earth's `core.lua:1591` calls
   `terrainpatch.update(dtReal, ...)`; `terrainpatch.lua:68` advances its clock by that `dt` and line 90 drops an
   unwanted patch after `KEEP_S` (10) of it; BeamNG's `dtReal` is smoothed (the fork's p13h108 finding: a 250 ms
   spike reads 16.7 ms); `stopwatch.clock()` is Earth's own wall clock. The 17:16 lockup log shows the growth this
   predicts: after 25 normal builds (median 2 ms), 35 back-to-back builds of 15-50 s (median 28.8 s) while the
   collision set grew from 342k to 717k triangles. Owner: Earth -- not patched in the fork; for Earth's author.
2. **FIX fork watchdog accounting:** `positionGE.lua` adds the full elapsed frame to `_stallT`
   on the first qualifying mismatch. Actual h112 module replay shows a single fresh 14,726 m
   target and one 1.1 s callback immediately trigger a heal, without observing sustained VE
   failure. Start observation at first mismatch, then require subsequent qualifying fresh-pose
   observations. The real log contains the matching 14,726 m heal at 497 s, after the first
   collision stall at 258 s: it can amplify movement/geometry churn, not explain its onset.
   `watchdog_gap_repro.py` preserves the isolated replay; it does not touch the running game.
   **Applied in p13h113 (fork-owned):** the watchdog's check clock uses `dtRaw` (BeamNG passes `onPreRender(dtReal,
   dtSim, dtRaw)`; the smoothed `dtReal` hides a frozen frame), a check more than two intervals late restarts the
   observation, and the first qualifying check only starts the timer. The 17:16 log's heal at 497.06 s came 0.3 s
   after a 29.8 s rebuild finished, "14726m off ... for ~1.1s". Guard: `earth_guard.py` W4 (fails on p13h112:
   a 1.2 s frame heals on the frozen check itself; with a smoothed `dtReal` it heals 0.6 s after the freeze).
3. **FIX Earth inactive-focus enumeration, separately:** real author-code execution includes
   an inactive remote ghost as another collision island. Filter inactive vehicles while
   retaining active remote collision. Latest captured status has `hidden: 0`, so this is not
   demonstrated as the present stall's cause.

Do not add another generic rebuild debounce: Earth already has 6 s normal / 1 s urgent /
30 s deletion scheduling and post-terrain-swap suppression. Do not globally disable remote
ground, replace collision architecture, or coarsen meshes without native performance and
contact tests. Multiple native TerrainBlocks are not a substitute: the author documents that
the engine collides only with the first. Anchor transitions also leave fork/smoother/predictor
cached coordinates uninformed; audit that separately rather than disabling the watchdog.

Verification before claiming resolution: simulated long wall gaps versus smoothed deltas;
moving-focus boundary crossings and full retained-mesh counts; delayed responses and rebases;
no ground gaps under active cars; watchdog single-observation negative and real sustained-stall
positive cases. Then native Windows/Linux comparisons with one fixed patch, overlapping
patches, stock cars versus aircraft, close versus separated players, with patch keys/bounds,
active flags, add/remove reasons and native build timings captured. If a single patch remains
multi-second, preserve a native thread-stack sample and minimal mesh reproduction for Earth /
BeamNG. No mod/package/settings/process changes were made for this review.

Author baseline: `TecnaGamer/BeamNG.Earth` tag `v1.6.0-beta` (`b4c478d`), specifically
`terrainpatch.lua`, `collisionfoci.lua`, `roads.lua`, `core.lua`, `stopwatch.lua` and
`server/terrainpatch.py`. Public issue #190 reports new 1.6 high-speed freezing; it corroborates
the symptom only, not this specific mechanism or a verified fix.

### Earlier upstream candidates

- BeamMP: `nodesVE.getNodes` raises on 0.40 (`Round` is not a global) and `applyNodes` calls the removed
  `beamstate.beamDeformed`, has its count check commented out and no `commitLoad` — so Earth's dents raise on
  stock BeamMP too (reproduced by `earth_guard.py`'s info line with upstream's file). The fork's p13h111 `-- LAN:`
  hunks in `nodesVE.lua` / `nodesGE.lua` are the whole fix and would make a small PR.
- BeamNG.Earth: a player on the BeamMP server's own machine is advertised as 127.0.0.1 and its peers connect
  to themselves; substituting the server address for a loopback member would fix every same-machine host.
- BeamNG.Earth: `be:reloadCollision()` rebuilds took 9-18.7 s on the Windows host while a second player's car
  sat ~3 km away (2 ms with one car; the Linux client's mirror case under 33 ms), against the ~20-56 ms
  `roads.lua` expects; logs: third session above.
