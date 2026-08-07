<!-- Published snapshot of the workspace-root CLAUDE.md (the working canon lives beside the
     three repos, which is not itself a git repo). Re-mirror when the root copy changes. -->

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this workspace is

A **LAN-only fork of [BeamMP](https://github.com/BeamMP)** (multiplayer for BeamNG.drive) with the
public backend/auth stripped out. The workspace root is **not** a git repo — it holds three sibling
repos, each with its own `lan` branch and an `upstream` remote:

| Path | Language | Role | upstream branch |
|---|---|---|---|
| `BeamMP/` | Lua + Vue/Angular UI | the client mod, packaged as `BeamMP.zip` | `development` |
| `BeamMP-Launcher/` | C++ | installs the mod, bridges game↔server; **also the combined host** | `master` |
| `BeamMP-Server/` | C++ | dedicated server / relay | `minor` |

Tested across two machines: **LAN1** (Windows host, runs the combined host) and **LAN2** (Linux
client). [AGENTS-2026-07.md](AGENTS-2026-07.md) is a 2026-07 snapshot kept for *rationale*
— the measured perf findings, the intent behind each LAN toggle, the profiling workflow, the
relay-throughput ceiling and the release mechanics. It predates the 0.39/4.22 work and its own
header lists what went stale; this file is the current state.

## Commands

**Build the mod zip** (canonical — `zip` is not on this box, and `mp_locales/` was retired in 4.22):

```bash
cd /d/beamMP_rewrite/BeamMP && python -c "
import zipfile, os, hashlib
out = r'D:\beamMP_rewrite\BeamMP.zip'
if os.path.exists(out): os.remove(out)
dirs = ['icons','locales','lua','scripts','settings','ui','vehicles']
docs = ['CONTRIBUTING.md','CODE_OF_CONDUCT.md','LICENSE','README.md','NOTICES.md']
z = zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED)
for d in dirs:
    for root,_,fs in os.walk(d):
        for f in fs: p=os.path.join(root,f); z.write(p,p.replace(os.sep,'/'))
for f in docs:
    if os.path.exists(f): z.write(f,f)
z.close(); print(hashlib.sha256(open(out,'rb').read()).hexdigest().upper())"
```

**Build the C++ binaries.** `cmd.exe /c foo.bat` from the **Bash tool silently does nothing** (prints
the cmd banner, exits 0) — always invoke batch files from PowerShell with an absolute path:

```powershell
& cmd.exe /c "D:\beamMP_rewrite\build-launcher.bat"    # combined host exe (server embedded)
```

```powershell
& cmd.exe /c "D:\beamMP_rewrite\build-server.bat"      # standalone dedicated server
```

Linux (Docker, both binaries → `dist/linux/`). From Git Bash the MSYS path conversion mangles
docker's `-w /work` into `C:/Program Files/Git/work`, so disable it:

```bash
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' TARGET_PLATFORM=linux/amd64 ./build-linux-docker.sh
```

If CMake complains the cache directory doesn't match, delete `BeamMP-Server/bin/` — a stale
`CMakeCache.txt` from the workspace's former `C:\Users\...\Documents` path.

**Test — the 17-assert smoke gate** (the only automated test; boots the combined host, drives a real
BeamNG session via BeamNGpy, asserts over the three logs; ~4 min, exit 0 = clean). Run it before
every deploy that touches sync, the launcher, or the mod's Lua:

```bash
cd /d/beamMP_rewrite/tools/mp-smoketest && python run_smoketest.py
```

It captures and restores `directVehicleSocket` / `profilePosSync` / `logSyncStats` around the run —
if it dies mid-run, check those didn't stay on. `--assert-only <logdir>` re-scores existing logs;
`--keep-running` leaves the session up.

**Lua syntax check** (lupa is installed — AGENTS.md's "no Lua toolchain" note is obsolete):

```bash
cd /d/beamMP_rewrite/BeamMP && python -c "
import pathlib
from lupa import luajit21 as lupa
lua = lupa.LuaRuntime(); load = lua.eval('function(s) local f,e = loadstring(s) return f~=nil, e end')
for f in list(pathlib.Path('lua').rglob('*.lua')) + list(pathlib.Path('scripts').rglob('*.lua')):
    ok, err = load(f.read_text(encoding='utf-8', errors='replace'))
    if not ok: print('FAIL', f, err)"
```

**Deploy (cold — never while the host is live).** Overwriting a served zip mid-session makes BeamNG
load a torn file and report a parse error on a file that is actually valid:

```powershell
Copy-Item "D:\beamMP_rewrite\BeamMP.zip" "D:\BeamMP Server\BeamMP.zip" -Force; Copy-Item "D:\beamMP_rewrite\BeamMP.zip" "$env:LOCALAPPDATA\BeamNG\BeamNG.drive\current\mods\multiplayer\BeamMP.zip" -Force
```

The combined host exe lives at `D:\BeamMP Server\BeamMP-Combined.exe` (copy of the launcher build);
third-party mods the server serves live under `D:\BeamMP Server\Resources\Client\`.

**Sync with upstream — merge, never cherry-pick.** Cherry-picking is what let the mod fall 180
commits behind (a folder rename, hook namespacing, the locales restructure and a batch of menu work
all went missing). The merge base is now recorded on `lan`, so this is cheap:

```bash
cd /d/beamMP_rewrite/BeamMP && git fetch upstream && git merge upstream/development
```

## Architecture

**The data path.** Own vehicle → `positionVE` (VE Lua, physics step) → either the GE funnel
(`positionGE.sendVehiclePosRot`) or, with `directVehicleSocket` on, straight to the launcher's UDP
port 4446 → launcher → server relay → other clients → `positionGE.applyPos` → the ghost's
`positionVE` predictor. The launcher's core channel is TCP 4444. **Combined host** (`--combined`)
runs the server in-process and bridges the host's own client over an in-memory link instead of
loopback sockets — `g_CombinedMode` gates the transport, and the mod is unaware.

**GE vs VE Lua is the split that matters.** `lua/ge/extensions/` runs once in the game-engine VM;
`lua/vehicle/extensions/BeamMP/` runs per vehicle. GE talks to VE with
`veh:queueLuaCommand("...")` — a *fire-and-forget string eval in a VM that may not have loaded its
extensions yet* (after a spawn, recover, or config edit). Every such call must be guarded:

```lua
veh:queueLuaCommand("if MPElectricsVE then MPElectricsVE.check() end")
```

An unguarded one FATALs the vehicle's VM and silently kills that car's sync for the session. Same
class of hazard: a vehicle **edit reloads the VE VM in place** (same object id), resetting every
VE-side flag while GE-side one-time gates still look satisfied — so any flag GE pushes down must
also be re-pushed from `positionGE.veReady()`, which `positionVE.onInit` calls on every VM load.

**Packet codes** (`MPGameNetwork` / server `TServer.cpp`): `Zp` position, `Om` active vehicle, `Rc`
controllers, `Xg` break groups, `Vi` inputs (direct socket), and `B` — the fork's own reliable relay,
sub-tagged `BF:` weapon fire, `C:` AI chase, `E:` environment sync. Weapon fire must stay on the
reliable path (edge/count data, not latest-wins). Don't change the `Zp` payload without a both-ends
plan; local apply-path changes are safe because they leave the wire alone.

**UI is three surfaces, and they are not interchangeable:**
- **Vue main menu** — `ui/ui-vue/mods/BeamMP/` (routes, views, `shared/beammpState.js`). This is the
  0.39 menu; the old Angular menu module is deleted. LAN trims live here (no public list, TOS,
  Patreon, account) alongside fork additions: version badge, "Playing as" name, favorite rename.
- **Options page** — a VFS override of the *game's* `ui/ui-vue/src/modules/options/runtime/layout.json`.
  Do not hand-edit it: `BeamMP/tools/inject_lan_options.py` re-injects the LAN items (marked
  `"version": "LAN"`) and re-applies the prunes. **Re-run it after every BeamNG patch.**
- **In-session HUD apps** — `ui/modules/apps/BeamMP-*`; the Angular ones plus upstream's newer Vue
  `-Chat2`/`-PlayerList2`. Lua reaches them through `guihooks.trigger`, and the fork **dual-emits**
  the legacy name plus upstream's `onBeamMP*` twin (chat broke twice over exactly this). The one
  exception is dialogs: emit `onBeamMPShowVueDialog` **only**, or the dead Angular overlay renders on
  top of the working Vue one and eats the clicks.

**Extension hooks are namespaced** since 4.22: `onBeamMPPostJoin`, `onBeamMPServerLeave`,
`onBeamMPLoadControllerSyncFunctions`, `onBeamMPTrackCameraMode`. Emitter and every listener must be
renamed together — a half-rename means a hook that silently never fires.

**Settings have a boot-order hazard.** The game's loader (`lua/common/settings.lua`) *drops*
settings.json keys it doesn't know about, and it runs ~0.7s before the mod registers its defaults —
so "value is nil" usually means "the user's value was thrown away", not "never set". `MPConfig`
therefore registers upstream's `settings/mp_defaults.json` **and** its own `defaultSettings`, and
refills a nil key from the user's file before falling back to a default. The 40 "Unrecognized
setting" warnings each boot are expected. UI writes go through `settings.setState`.

## Conventions

- **`modVersion` in `MPCoreNetwork.lua`** is display-only (never a handshake gate). Bump the
  `pNNhNN` suffix on **every** rebuild and prepend a `modPatchNote` entry — that string is what the
  in-game badge and the log banner show, and it is how a deployed build gets identified.
- **LuaJIT caps a function at 60 upvalues.** Exceeding it fails the *entire file* at load. Growing a
  big function (`MPVehicleGE.onPreRender` is at the edge) may require splitting it.
- **A mis-resolved merge conflict can still parse.** One `end` too few makes later `local function`s
  nest inside the previous one, so exports resolve to nil at runtime. After any merge, load each
  module in a stub sandbox and assert every `M.foo = foo` really came out a function, and grep for
  calls to upstream names the fork renamed — a parser will not catch either.
- **Never bypass `requestServerList`'s in-session guard** — the `B` request tears the session down.
- **Guard new BeamNG engine calls** (`if gameplay_markerInteraction then ...`). The game's Lua API
  churns between versions; this fork tracks its `development` branch.
- **Ship risky perf work behind a default-off toggle**, keep the original path, A/B it in-game, and
  delete the toggle if it proves a footgun. Position send rate is one such lesson: **lower is
  better** (default 30Hz, 60 ceiling) — the old 100Hz oversubscribed the relay.
- Verification gauntlet before shipping: Lua parse → sandbox export check → `node --check` on touched
  JS and each `.vue` `<script>` block → JSON parse (note `settings/mp_defaults.json` is JSONC) →
  smoke gate → a real 2-player session. Package and tag (`lan-release-p13hNN` on all three repos)
  only after the user has verified in-game.

## Durable project state

Long-lived findings — measured perf numbers, the reasoning behind each toggle, third-party mod
fixes, release history — live in the agent memory at
`C:\Users\modde\.claude\projects\D--beamMP-rewrite\memory\` (`MEMORY.md` is the index). Read it
before re-deriving anything; `UPSTREAM-PRS.md` at the workspace root tracks what is worth sending
upstream and what has already been merged in from it.
