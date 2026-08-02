# BeamMP LAN Fork — Release

**Build:** mod `4.22.0-LAN p13h78` · combined host exe `p13h35` (Windows + Linux) · **for BeamNG 0.39**

A LAN-focused fork of [BeamMP](https://beammp.com) for BeamNG.drive. It runs the
server and your game together in **one process** ("combined host"), tunes position
sync for low-latency LAN play, and is hardened to keep running even when a player
loads a broken third-party mod. It also works point-to-point over the internet with
a little tuning (see `LAN-TUNING.md`).

> Built on and fully compatible with the upstream BeamMP project — all credit to the
> BeamMP team. This fork only changes/adds the items below.

---

## Highlights — what's different from stock BeamMP

- **Combined host mode (`--combined`).** One executable runs the dedicated server
  *and* bridges your own game over an in-memory channel — no separate server install,
  no loopback. Others join over your network as normal. `--server-only` still runs a
  plain dedicated server.
- **LAN-tuned position sync.** Physics-rate sending is decoupled from your frame rate,
  with a **Position send rate** selector (60 / 30 / 10 Hz, default **30**). It rides the
  **stock BeamMP predictor** — testing showed stock tracks tighter than extra corrective
  "hold"/snap logic, so the fork keeps the predictor pure and just feeds it a clean rate.
  Clients also coalesce a backed-up receive queue **latest-wins**, so a brief frame
  hitch doesn't replay stale positions afterward. A narrowly-guarded **self-heal
  watchdog** recovers a ghost that genuinely *stalls* (the engine stops applying received
  positions, e.g. during a load hitch) — it only fires when fresh positions are arriving
  but the ghost isn't moving, so it can never fight the predictor on a normally-drifting car.
- **Sync-stats overlay.** Live ghost-drift, apply rate and FPS, with red warnings and a
  one-line hint of which lever to pull while tuning — and the hints distinguish a **relay**
  problem (positions not arriving) from a **local FPS hitch** (the game can't apply them),
  so you fix the right thing. Draggable; `/synclog` mirrors it to the log for after-the-fact
  diagnosis, and an opt-in **apply-stall log** names the exact cause of a freeze.
- **Seamless map switching.** The server `map <path>` command swaps levels in place —
  no reconnect, no Lua reload, no mod re-sync.
- **Networked weapons & AI chase.** Synced weapon fire/explosions with **per-shot-accurate
  fire rate** (remotes replay exactly the rounds the source fired, not one per key-press),
  opt-in "let other players' AI chase me," and adaptive remote projectiles.
- **Broken-mod resilience.** A faulty or version-mismatched third-party mod degrades
  gracefully instead of desyncing a player or crashing the session.
- **Host tooling.** `start-server.bat` + `pin-cores.ps1` (pins BeamNG to dedicated CPU
  cores so the relay/bridge keep up), and in-game **Save all logs (zip)** for support.

## This release

- **One-shot environment sync (p13h69-p13h77).** `/syncenv` in chat — or the new **"Sync
  environment to players" button in the pause menu's Environment tab** — pushes YOUR time of day,
  clouds, fog, wind, precipitation, gravity and temperature (the game's own whole-environment
  snapshot) to everyone in the session; receivers blend over 2 seconds with a toast naming the
  sender. One-time adopt, no continuous sync; whoever runs it is the source of truth. A consent
  checkbox ("Allow environment sync from other players", default on) lets anyone opt out of
  receiving.
- **Default orbit-camera distance (p13h70-p13h74).** A Multiplayer-options slider that sets the
  orbit camera's own default distance — applied on vehicle switches and camera changes, and
  because it *is* the camera's default, vehicle resets restore it natively. (This is the lever
  the zoom keys actually move, so it works pulled out as well as in.)
- **Chat fixed on the HUD chat app — it was double-broken (p13h72-p13h78).** The default chat
  app never received messages (the mod stopped emitting the hook it listens for after the 0.39
  rename) and threw on rendering when messages did arrive (an unawaited sanitizer import). Both
  fixed; slash commands also now work typed into any chat surface, and **`/?`** lists them all
  locally.
- **Test-harness hygiene (tooling).** The automated smoke gate no longer leaks its debug settings
  (position profiler, sync log) into real sessions after each deploy.
- **Per-frame Lua garbage cleanup (p13h62).** Hand-port of the two self-contained pieces of
  upstream PR 838: nametag/spectator strings and their engine-string wrappers are now cached per
  vehicle and rebuilt only when an input changes (nick/role/name/settings/camera switches), the
  per-frame vector/quaternion allocations in the render loop and the position-receive path are
  pooled, blob colors parse once instead of three hex-parses per frame, and the imgui chat measures
  each message once at arrival instead of twice per text segment per frame. Fixes three bugs in the
  PR itself along the way (a dropped rotation negation, a nil-index on departed spectators, dead
  code not ported).
- **BeamMP settings on 0.39 (p13h63-p13h64).** 0.39 rebuilt the game Options screen on a Vue
  schema, which silently orphaned the old settings page. The fork now ships upstream 4.22's answer
  (a layout override adding a Multiplayer category) **plus all the LAN fork's own settings** with
  their original tooltips — auto-spawn on join, AI-chase consent, projectile/position/mailbox/
  marker tuning, direct vehicle socket, diagnostics, and the Save-all-logs button.
  `tools/inject_lan_options.py` re-applies the LAN items *and* the LAN prunes on every re-sync
  (notably: upstream's "refresh server list in-game" is removed — on a LAN build that request
  would terminate the running session).
- **Log-noise and polish fold-in (p13h68).** The benign-but-noisy "ResizeObserver loop" error
  lines from the server browser are silenced (the sidebar-sizing observer now defers a frame),
  and a latent init-order bug in the menu state meant the locally stored player name was never
  read at startup (masked by the launcher-name fallback; now reads correctly).
- **Settings persistence hardened (p13h67).** The game's settings loader drops any saved key it
  doesn't recognize at load time, and it loads seconds before the mod registers its keys — a
  boot-order race that could silently erase saved BeamMP settings. The mod now restores the user's
  saved values straight from the settings file at registration, verified end-to-end with a
  two-session automated probe.
- **"Playing as" reads the launcher's persisted name (p13h66).** The sidebar name, Direct
  Connect prefill and Change-name default now seed from the launcher's login response when the
  menu's own storage is empty — previously they showed "Player" on machines where the name had
  been set anywhere other than this menu's dialog.
- **In-session menu fixes (p13h63-p13h65).** The current-server view lists the server's mods
  again (`getServerMods` bridge), the "server browser" link lands on Favorites (the public list is
  empty by design on LAN), the disconnect dialog's **Continue offline / Return to menu buttons work
  again** (moved off the dead Angular dialog onto the game's native Vue dialog), and three LAN menu
  features lost in the Vue port are restored: **"Playing as" name display with a Change-name
  prompt**, the **Direct Connect name field**, and **favorite rename** (which now also survives
  list rebuilds — the 0.38 menu's rename had never stuck through one).
- **BeamNG 0.39 support (p13h58-p13h61).** Validated against 0.39.1.0 and upstream BeamMP 4.22:
  the mod version base now tracks upstream (`4.22.0-LAN`). The 0.39 blocker was stock BeamMP's own
  version gate silently deactivating the whole mod on any game update — the fork now **warns loudly
  but keeps loading** on unknown future game versions instead of bricking multiplayer. Also ported:
  the 0.39 imgui unconditional-End requirement (chat/options/player-list windows), the renamed
  unicycle/walking APIs (with 0.38 fallback), and chat keybinds on key-release.
- **New multiplayer menu (0.39's menu is Vue-only).** Upstream 4.22's rebuilt menu UI is ported and
  **trimmed for LAN**: a "BeamMP" main-menu button opens straight into your server list — no
  Rules/TOS screen, no login/account chrome, no Official/Featured/Partner categories, no
  Patreon/Discord links. Sidebar: Favorites (default) / Recent / Direct Connect, with the mod
  version shown. The bottom info-bar **version badge is back in the 0.38 style** (native font, right
  of the game version, orange divider) — upstream removed it; the fork keeps it.
- **Combined exe p13h35** — p13h34 code with an honest pairing banner (`pairs with mod
  4.22.0-LAN p13h60+; BeamNG 0.39`). If you stay on p13h34 everything still works.
- **Rollback:** the previous release bundle (`p13h57`, for BeamNG 0.38) is tagged
  `lan-0.38-last-good` on all three repos and kept in `dist/` — if a machine can't update the game,
  run that pairing.

- **Direct vehicle socket (p13h57, from BeamMP-Launcher#245 — experimental, default off).**
  Options → Multiplayer → advanced → "Direct vehicle socket": your own vehicles send
  **position + driver inputs** straight to the launcher over a dedicated per-vehicle UDP
  socket, bypassing the per-packet Lua-string compile through the game's single main-thread
  VM — the measured send-side bottleneck as vehicle counts climb (profiler-verified: the
  `GE sendVehiclePosRot` cost drops to zero when active). Only latest-wins data rides it;
  weapon fire, electrics, powertrain, break groups and controllers stay on the reliable path.
  **Safe to enable anywhere:** the mod keeps the normal path until the launcher (p13h34+)
  acknowledges the socket, and reverts with a log line if it never does — an old launcher or
  a blocked port can never silently eat a car. Vehicle edits/reloads re-register cleanly.
- **Combined exe p13h34.** Hosts the direct-vehicle socket (UDP, launcher port+2) with
  per-vehicle registration + source-port pinning, a registration ack/keepalive (what the
  safety above rides on), and reliable routing for complete-or-nothing packet families.
  The launcher banner now states its real build number.
- **Full-deformation sync removed (was experimental, default off).** Even with a fixed
  transport, serializing every node+beam (~100KB) at 2 Hz per vehicle in Lua — plus a full
  apply pass on every receiver — costs more CPU than the feature is worth. Break-group
  (parts falling off) and synced-controller sync are unchanged. Packets from old clients
  that still have it enabled are discarded silently; the old setting stays recognized so
  existing settings files don't warn.

- **Profiling + a sync-log checkbox (p13h56).** The position profiler now also times the
  GE-side send handler (`GE sendVehiclePosRot`) so a 2-player session shows the VE→GE
  send cost as vehicle count climbs. And `/synclog` is now also a checkbox under
  Options → Multiplayer → advanced → DEBUG (“Log sync health to file”) — same toggle.

- **Opt-in unreliable (UDP) events (p13h55, from upstream BeamMP#892/#253/#493).** Mods can
  now send events over UDP instead of TCP: `TriggerServerEventUnreliable(name, data)` on the
  client, `MP.TriggerClientEventUnreliable(...)` / `...JsonUnreliable(...)` on the server. On a
  LAN, loss is ~0, so these are near-reliable but avoid TCP retransmit and head-of-line
  blocking — lower latency for fire-and-forget/latest-wins data. (Weapon fire and damage stay
  reliable by design — see the note below.) Works over the combined host's in-memory bridge.
- **More vehicle sync (p13h55, cherry-picked upstream):** transbrake now syncs a released
  (`false`) state too (BeamMP#894); citybus destination signs sync (BeamMP#884); and
  hydraulic-cylinder arm/boom beams sync on construction equipment like the WL-40 (BeamMP#880) —
  inert on vehicles that don't have them.
- **Robustness (p13h55):** the server ignores an empty `mods.json` instead of erroring every
  startup (BeamMP-Server#455); the launcher's last direct mod-copy site now uses the same atomic
  write the fork uses elsewhere, so BeamNG never mounts a half-written zip (BeamMP-Launcher#250).
- **Deformation-sync & socket hardening (p13h52).** The experimental full-deformation
  sync now rejects a snapshot taken from a different vehicle configuration (a config
  edit racing the 2 Hz snapshot could feed out-of-range node ids into engine calls),
  and a partially-sent game→launcher packet now *completes or cleanly closes* the
  socket instead of being abandoned mid-frame — an abandoned half-frame permanently
  corrupted the stream framing (realistic with the ~100 KB deformation snapshots or
  large vehicle-config spawns). The "full weapon projectiles on remote cars" option
  was audited end-to-end and is correct as shipped.
- **Synced with upstream BeamMP (p13h51).** Merged upstream's *batch-based mod
  loading* (BeamMP#893): synced server mods now mount in batches of 5 with a yield
  between batches, fixing an upstream-reported BeamNG crash under many simultaneous
  mod updates and smoothing the join-time hitch — especially relevant to big synced
  mod sets like this fork's. Also merged the server's
  `BEAMMP_MAX_CONCURRENT_CONNECTIONS` env var (BeamMP-Server#496); inert unless set
  (combined exe `p13h32`, Windows + Linux).
- **Ghost freeze after a vehicle swap/edit — fixed (p13h50).** The long-standing
  intermittent "ghost stalled until someone resets it" bug is root-caused from a
  two-machine log pair: when a player **switches vehicle or changes their config**, the
  ghost's vehicle VM on every other machine is reloaded in place and silently loses all
  its sync flags — after which received positions pile up in a mailbox the fresh VM
  never polls. The ghost froze *permanently* (drifting hundreds of metres from its
  driver) until an unrelated settings change happened to re-push flags. Every vehicle
  VM now announces its (re)load and gets all flags re-pushed immediately. This also
  fixes a quiet own-car variant: after an edit, your own car reverted to a built-in
  100 Hz send rate (the relay-overload rate) until the next settings change.
- **Drift gauge / watchdog fixed for weapon-mod vehicles (p13h50).** Vehicles that fire
  node-based projectiles (turrets, tank guns) stretch their bounding box by hundreds of
  metres, which made the drift gauge read a perfectly-synced turret as "170 m off" and
  could make the self-heal *throw* a healthy ghost by that error (a visible warp). The
  gauge now measures against whichever anchor (body reference node or bounding-box
  centre) matches the received position — long vehicles keep their fix, weapon vehicles
  stop lying, genuinely frozen ghosts are still detected.
- **Ghosts no longer physics-sleep (p13h49, defense-in-depth).** A parked ghost could be
  put to sleep by the engine (its update loop stops, so it can't apply positions);
  remote vehicles now disable sleep the moment they're identified — the same engine API
  BeamNG's own walking mode uses.
- **Sender-clock robustness (p13h48).** The physics-rate send clock can no longer jump
  backwards after a game hitch (which made every other machine silently reject that
  car's positions — a remote-side ghost freeze); and a receiver now recovers from a
  sender whose clock restarted (vehicle Lua reload) instead of rejecting its packets
  until a manual reset. Also: the launcher's "no ping yet" sentinel no longer feeds a
  negative ping into the predictor's timing math.
- **Send-rate guidance: don't use 10 Hz for play.** 10 Hz packets arrive at exactly the
  predictor's 0.1 s timeout, so it regularly idles between packets and the ghost steps
  instead of gliding (confirmed in the same log). Run **30 Hz (the default) on every
  machine**; 10 Hz remains only for stock-parity testing.
- **Position sync — lower is better.** Default send rate is **30 Hz**; 100 Hz was
  removed because it oversubscribes the single-path relay with 2+ players and *degrades*
  tracking over a session. 30 Hz tracks smoother than stock's 10 Hz with no backlog.
- **Pure stock predictor + a narrowly-guarded watchdog.** The fork's earlier tracked-
  vehicle "stiffening" was removed — it fought the predictor (a skid-steer tank could
  spike tens of metres on the remote) — so every vehicle rides the stock predictor and a
  tank syncs the same as on stock. The self-heal watchdog stays, but **only** to recover a
  genuinely *stalled* ghost: it fires when fresh positions are arriving yet the ghost isn't
  moving, and only after a **sustained** stall (~1s) — brief between-apply freezes are left to
  the predictor to smooth out, so it can never snap a normally-moving car (even at high speed).
- **Freezes under heavy load are FPS hitches, not the network.** Pinned down with an opt-in
  per-vehicle apply-stall log: when a machine hitches for ~1s under a big mod set, its game
  engine stops applying received positions, so the remote ghosts it draws freeze until it
  catches up. The fix is **trimming the mod / vehicle / AI-traffic load** — and the overlay
  now says exactly that instead of blaming the relay.
- **Faster server relay.** The dedicated/embedded server finds a packet's sender with an
  **O(1)** id-indexed lookup and fans out over an immutable snapshot, instead of copying and
  scanning the whole client list on every packet — lower per-packet cost and more headroom
  as player count grows. *(in the combined exe since p13h31)*
- **Accurate remote weapon fire.** Gated/slow guns (howitzer/m242/50 cal) stream each
  real shot, so the remote cadence matches the source instead of free-running at the
  gun's max rate.
- **Client-side latest-wins receive drain.** On a frame hitch the client forwards only
  the newest position per vehicle from the backlog instead of replaying the stale ones.
- Removed the experimental "Low-GC predictor" (`fastPredict`): an audit found it correct
  but no faster under LuaJIT, so it was only a parallel code path to maintain — one
  predictor path now.
- Earlier in this line: a critical malformed-packet CPU-hang fix, broad broken-mod
  hardening, and overlay/GC polish.

## Install (combined host)

1. Put `BeamMP.zip` in your BeamNG `mods/` (or let the launcher mount it).
2. Run **`BeamMP-Combined.exe --combined`** (or use `start-server.bat`). Keep the window
   open — it's your server.
3. Other players use the normal BeamMP launcher and **Direct Connect** to your IP on
   port `30814`.

Full setup, build-from-source, and the dedicated-server option are in `README-LAN.md`.

## Tuning

- **Leave the send rate at 30** unless you have a specific reason — **lower is better**
  here (it never oversubscribes the relay). 60 is the ceiling, only worth it at a
  rock-steady 60 FPS on both machines.
- Keep the live **heavy-vehicle count low** and your **mod set trimmed** — many
  soft-body/large mods drag both machines' frame rate into hitches, which is the usual
  cause of big drift (and can even crash BeamNG's own engine), not the network.
- Internet point-to-point: see the remote/over-the-internet section in `LAN-TUNING.md`.

## Compatibility

Same protocol as the host's build — **everyone in a session should run the matching
`BeamMP.zip` *and* the matching combined/launcher exe.** Provided for Windows and Linux
(x86-64).

## Source & license (AGPL-3.0-or-later)

A fork of [BeamMP](https://beammp.com) — all credit to the upstream BeamMP team; this fork only
changes the items above. Under **AGPL-3.0**, the complete corresponding source for these binaries
is published (branch `lan`, tag `lan-release-p13h56`):

- **Mod + client Lua** — https://github.com/IrPgFKS0/BeamMP
- **Launcher / combined host** — https://github.com/IrPgFKS0/BeamMP-Launcher
- **Dedicated server** — https://github.com/IrPgFKS0/BeamMP-Server
