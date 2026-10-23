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

## Known limits and observations (not fork defects)

- **Rebase blink.** When either player's origin moves (every 15 km, or a teleport), Earth moves every vehicle
  but BeamMP's predictor still holds the last target in the old frame until the next packet (about 33 ms at
  the fork's 30 Hz), and its large-error teleport can snap the ghost toward it for a frame. Same predictor
  logic as upstream; watch for it in the two-player test.
- A player without the Earth app has no origin: their cars stay hidden for everyone (Earth's rule).
- Shared world building needs inbound TCP 47621 on each machine; otherwise each builds its own. Not yet seen
  working between the Windows and Linux apps (second and third sessions above).
- With a second car a few km away, the host's collision rebuilds can take 9-19 s each (third session above);
  driving together avoids it.
- Upstream 4.23.1 turns the game's MCP off in a session; the fork never adopted that, so the smoke harness
  and Earth's status file keep working.

## For upstream (not sent)

- BeamMP: `nodesVE.getNodes` raises on 0.40 (`Round` is not a global) and `applyNodes` calls the removed
  `beamstate.beamDeformed`, has its count check commented out and no `commitLoad` — so Earth's dents raise on
  stock BeamMP too (reproduced by `earth_guard.py`'s info line with upstream's file). The fork's p13h111 `-- LAN:`
  hunks in `nodesVE.lua` / `nodesGE.lua` are the whole fix and would make a small PR.
- BeamNG.Earth: a player on the BeamMP server's own machine is advertised as 127.0.0.1 and its peers connect
  to themselves; substituting the server address for a loopback member would fix every same-machine host.
- BeamNG.Earth: `be:reloadCollision()` rebuilds took 9-18.7 s on the Windows host while a second player's car
  sat ~3 km away (2 ms with one car; the Linux client's mirror case under 33 ms), against the ~20-56 ms
  `roads.lua` expects; logs: third session above.
