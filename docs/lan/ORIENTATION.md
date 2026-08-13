<!-- Published snapshot of the workspace-root CLAUDE.md (the working canon lives beside the
     three repos, which is not itself a git repo). Re-mirror when the root copy changes.
     Named ORIENTATION.md, not CLAUDE.md: a CLAUDE.md here would be auto-loaded as
     directory-scoped instructions for everything under docs/lan/. -->

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
client). [AGENTS-2026-07.md](AGENTS-2026-07.md) is a snapshot kept for *rationale*
— the measured perf findings, the intent behind each LAN toggle, the profiling workflow, the
relay-throughput ceiling and the release mechanics. It predates the 0.39/4.22 work and its own
header lists what went stale; this file is the current state.

## Commands

**Build the mod zip** (canonical — `zip` is not on this box, and `mp_locales/` was retired in 4.22):

```bash
cd /d/beamMP_rewrite/BeamMP && python -c "
import zipfile, os, hashlib, shutil, sys, time
out  = r'D:\beamMP_rewrite\BeamMP.zip'
back = r'D:\beamMP_rewrite\dist'
dirs = ['icons','locales','lua','scripts','settings','ui','vehicles']
docs = ['CONTRIBUTING.md','CODE_OF_CONDUCT.md','LICENSE','README.md','NOTICES.md']
missing = [d for d in dirs if not os.path.isdir(d)] + [f for f in docs if not os.path.isfile(f)]
if missing: sys.exit('ABORT: missing from the mod tree: ' + ', '.join(missing))
if os.path.exists(out):
    shutil.copy2(out, os.path.join(back, time.strftime('BeamMP_backup-%Y%m%d-%H%M%S.zip'))); os.remove(out)
z = zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED); n = 0
for d in dirs:
    for root,_,fs in os.walk(d):
        for f in fs: p=os.path.join(root,f); z.write(p,p.replace(os.sep,'/')); n+=1
for f in docs: z.write(f,f); n+=1
z.close(); print(n, 'entries', hashlib.sha256(open(out,'rb').read()).hexdigest().upper())"
```

A renamed or moved source folder must be **loud**: `os.walk` on a missing directory yields nothing
and raises nothing, so without the pre-flight check above a `mp_locales/`-style rename produces a
valid-looking zip with a whole subsystem missing. Sanity-check the entry count (466 at p13h83).

**Build the C++ binaries.** `cmd.exe /c foo.bat` from the **Bash tool silently does nothing** (prints
the cmd banner, exits 0) — always invoke batch files from PowerShell with an absolute path:

```powershell
& cmd.exe /c "D:\beamMP_rewrite\build-launcher.bat"    # combined host exe (server embedded)
```

```powershell
& cmd.exe /c "D:\beamMP_rewrite\build-server.bat"      # standalone dedicated server
```

`build-launcher.bat` configures into `BeamMP-Launcher/build`, `build-server.bat` into
`BeamMP-Server/bin`. If either complains the cache directory doesn't match, delete that build dir —
a stale `CMakeCache.txt` from the workspace's former `C:\Users\...\Documents` path.

Linux (Docker, both binaries → `dist/linux/`). From Git Bash the MSYS path conversion mangles
docker's `-w /work` into `C:/Program Files/Git/work`, so disable it:

```bash
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' TARGET_PLATFORM=linux/amd64 ./build-linux-docker.sh
```

The container builds into `bin-linux` (wiped each run) precisely so it never collides with the
Windows caches above.

**Test — the 17-assert smoke gate** (the only automated test; boots the combined host, drives a real
BeamNG session via BeamNGpy, asserts over the three logs; ~4 min, exit 0 = clean). Run it before
every deploy that touches sync, the launcher, or the mod's Lua:

```bash
cd /d/beamMP_rewrite/tools/mp-smoketest && python run_smoketest.py
```

It captures and restores `directVehicleSocket` / `profilePosSync` / `logSyncStats` around the run —
if it dies mid-run, check those didn't stay on. Flags: `--assert-only` (bare — it re-scores the three
logs already on disk, it does **not** take a log directory); `--keep-running` leaves the session up
**and deliberately skips the settings restore**; `--force-kill` clears stale processes;
`--drive <seconds>` shortens or extends the AI drive.

The gate runs the **deployed** host, `D:\BeamMP Server\BeamMP-Combined.exe` — not the build output.
Rebuilding the launcher without the copy below silently gates the old exe.

**Lua syntax check** (lupa is installed — the 2026-07 snapshot's "no Lua toolchain" note is obsolete):

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
load a torn file and report a parse error on a file that is actually valid. Chain the copies with
`&&`, not `;` — the launcher serves one copy and installs the other, so a half-completed deploy
leaves the served hash disagreeing with the installed one (clients then re-download forever):

```powershell
Copy-Item "D:\beamMP_rewrite\BeamMP.zip" "D:\BeamMP Server\BeamMP.zip" -Force && Copy-Item "D:\beamMP_rewrite\BeamMP.zip" "$env:LOCALAPPDATA\BeamNG\BeamNG.drive\current\mods\multiplayer\BeamMP.zip" -Force
```

The exe is a separate deploy — `build-launcher.bat` emits `BeamMP-Launcher\build\BeamMP-Launcher.exe`
and the host runs it under a different name:

```powershell
Copy-Item "D:\beamMP_rewrite\BeamMP-Launcher\build\BeamMP-Launcher.exe" "D:\BeamMP Server\BeamMP-Combined.exe" -Force
```

Third-party mods the server serves live under `D:\BeamMP Server\Resources\Client\`.

**Sync with upstream — merge, never cherry-pick.** Cherry-picking is what let the mod fall 180
commits behind (a folder rename, hook namespacing, the locales restructure and a batch of menu work
all went missing). The merge base is now recorded on `lan`, so this is cheap:

```bash
cd /d/beamMP_rewrite/BeamMP && git fetch upstream && git merge upstream/development
```

A **BeamMP-Server merge means rebuilding BOTH exes** — the combined host statically embeds the
server as a library, so a server-side fix that is only built into `BeamMP-Server.exe` never reaches
the machine that actually runs the session.

## Upstream-sync guardrails — do NOT let a merge take these

Every serious regression this fork has shipped came from an upstream sync, and each was a **seam**:
upstream's half and the fork's half both parse, every syntax check passes, and the break only shows
at runtime — often only with a second player. Resolve conflicts with this list in hand, and treat
any upstream change that *touches* one of these areas as guilty until proven innocent.

**Fork-owned surfaces upstream must never overwrite (resolve to OURS, then re-check by hand):**
- **`positionGE`/`positionVE` receive + predictor path.** The fork's `applyPos` takes the **decoded
  table**; upstream's takes the raw JSON string. In p13h82 the merge kept upstream's caller with the
  fork's callee — `string.pos` is nil, so every remote position was rejected as "malformed pose" and
  remote cars froze all session (13,963 rejections in one log). The fork also does NOT use
  upstream's `vehPosPckt` VE mailbox path (it has its own `mpPos` mailbox + #245 direct socket +
  predictor); keeping a second, never-called receive path invites drift — delete it on sight.
- **The VE-guard convention.** Every GE→VE `queueLuaCommand` must stay wrapped in
  `if XxxVE then ... end`. Upstream's tick loops are unguarded; re-guard them when adopting.
- **The nametag/tag-string assembly.** Upstream owns the distance-string *format* (trailing-space
  since 4.22.1), the fork owns the cached *assembly* — p13h85's `Caden42 m` came from taking their
  format without re-checking the pairing. When upstream changes any producer whose consumer is
  fork-owned (string formats, JSON shapes, event payloads), re-verify both halves together.
- **The Vue menu LAN trims** (no public list/TOS/Patreon/account/metrics), the "Playing as" panel,
  favorite rename, the Direct Connect name field + `30814` default port, and small fork fixes inside
  upstream-owned files — upstream edits the same views every release and will silently revert them
  (#926 reverted the h61 logo-path fix; the merge diff looks like an innocent upstream cleanup).
  `git diff` the fork's LAN comment markers (`-- LAN:`, `// LAN:`) before and after any merge: a
  marker that vanished is a fix that got reverted.
- **The options layout override is NEVER git-merged.** Rebuild it: game layout (current patch) +
  upstream's beammp category family + `tools/inject_lan_options.py`. The injector also re-applies
  the LAN prunes — upstream keeps re-adding **`refreshIngame`** to their options UI and it must
  never come back (it sends the session-killing `B` request) — and `LAN_TEXT_FIXUPS` (known
  upstream typos, e.g. their `beammpHowBlobIllegal` ghost condition).
- **`conditions.js` (and any other `ui/ui-vue/src/**` file the mod ships) VFS-shadows the game's
  copy.** After every game patch AND every upstream sync, diff it against the game's same-path
  file — upstream shipped a stale `richPresenceEnabled` that disabled a **stock game option**
  game-wide while the mod was mounted. A shadow file can break the base game, not just the mod.
- **`modScript.lua`'s version gate stays warn-only.** Upstream hard-deactivates the whole mod on an
  unexpected game version — that is exactly how MP silently died on a Steam auto-update. Never take
  their `deactivateMod` branch.
- **Do not re-take features the fork deliberately removed or rejected:** full deformation sync
  (removed 2026-07 — CPU-infeasible), the 100Hz send-rate option (relay oversubscription; 60 is the
  ceiling, lower is better), upstream's async batch mod loading semantics if they change again
  (#893 caused under-map spawns), and anything moving weapon fire off the reliable `B` path.

**Why the standard checks don't save you:** parse, the sandbox export check, orphan-call scans and
the 17-assert smoke gate are all **single-machine** — remote receive paths (`applyPos` and friends)
only execute when a second player streams in. The p13h82 regression passed every one of them. So:

1. After resolving, run the deterministic gauntlet (Conventions below) **plus** a caller/callee
   shape check for every fork-owned receive callee upstream's diff touched.
2. For any multi-file merge, run an adversarial seam review (fresh-eyes agents hunting the three
   seam classes: renamed symbols, producer/consumer format pairs, caller/callee arg shapes — the
   p13h87 review caught five upstream-authored defects this way).
3. Nothing that touches sync, spawn, or receive paths is "verified" until a **real 2-player
   session** ran clean — the gate alone is necessary but not sufficient. Package only after that.

## Architecture

**The data path.** Own vehicle → `positionVE` (VE Lua, physics step) → either the GE funnel
(`positionGE.sendVehiclePosRot`) or, with `directVehicleSocket` on, straight to the launcher's UDP
port 4446 → launcher → server relay → other clients → `positionGE.applyPos` → the ghost's
`positionVE` predictor. Three launcher ports, all derived from `launcherPort`: **4444** the core
channel (`MPCoreNetwork`, handshake/server list), **4445** (= +1) the game data channel
(`MPGameNetwork` — this is what the GE funnel actually rides), **4446** (= +2) the direct vehicle
UDP socket. **Combined host** (`--combined`) runs the server in-process and bridges the host's own
client over an in-memory link instead of loopback sockets — `g_CombinedMode` gates the transport,
and the mod is unaware.

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
controllers, `Xg` break groups, `Vi` driver inputs, and `B` — the fork's own reliable relay,
sub-tagged `BF:` weapon fire, `C:` AI chase, `E:` environment sync. Weapon fire must stay on the
reliable path (edge/count data, not latest-wins). Don't change the `Zp` payload without a both-ends
plan; local apply-path changes are safe because they leave the wire alone. The direct vehicle socket
is a **transport swap, not a new protocol** — it carries the same `Zp`/`Vi` tags (plus `Va`/`Vd`
registration), so only latest-wins codes may ride it.

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
settings.json keys it doesn't know about. It runs ~0.7s into boot — roughly **6 seconds before**
`MPConfig.onExtensionLoaded` registers the mod's keys (see the comment at `MPConfig.lua:188`) — so
"value is nil" usually means "the user's value was thrown away", not "never set". `MPConfig`
therefore registers upstream's `settings/mp_defaults.json` **and** its own `defaultSettings`, and
refills a nil key from the user's file before falling back to a default. The 40 "Unrecognized
setting" warnings each boot are expected. UI writes go through `settings.setState`.

## Conventions

- **`modVersion` in `MPCoreNetwork.lua`** is display-only (never a handshake gate). Bump the
  `pNNhNN` suffix on **every** rebuild and prepend a `modPatchNote` entry — that string is what the
  in-game badge and the log banner show, and it is how a deployed build gets identified.
- **LuaJIT caps a function at 60 upvalues.** Exceeding it fails the *entire file* at load. This
  already bit `MPVehicleGE.onPreRender` in the 4.22 merge — it is **deliberately split** into
  `onPreRenderHousekeeping` + `onPreRender`. Do not fold them back together, and expect any further
  growth there to need another split.
- **A mis-resolved merge conflict can still parse.** One `end` too few makes later `local function`s
  nest inside the previous one, so exports resolve to nil at runtime. After any merge, load each
  module in a stub sandbox and assert every `M.foo = foo` really came out a function, and grep for
  calls to upstream names the fork renamed — a parser will not catch either. There is no packaged
  tool for this; write a throwaway script (the Lua parse check above is the starting point — it only
  proves the file *compiles*, which is exactly what makes this failure mode invisible).
- **Never bypass `requestServerList`'s in-session guard** — the `B` request tears the session down.
  The guard is `if isMpSession and not settings.getValue("refreshIngame")`, so the legacy
  `refreshIngame` setting is itself a bypass; it is no longer offered in the UI, leave it that way.
- **Guard new BeamNG engine calls** (`if gameplay_markerInteraction then ...`). The game's Lua API
  churns between versions; this fork tracks its `development` branch.
- **Ship risky perf work behind a default-off toggle**, keep the original path, A/B it in-game, and
  delete the toggle if it proves a footgun. Position send rate is one such lesson: **lower is
  better** (default 30Hz, 60 ceiling) — the old 100Hz oversubscribed the relay.
- Verification gauntlet before shipping: Lua parse → sandbox export check → `node --check` on touched
  JS and each `.vue` `<script>` block → JSON parse (note `settings/mp_defaults.json` is JSONC) →
  smoke gate → a real 2-player session. Package and tag (`lan-release-p13hNN` on all three repos)
  only after the user has verified in-game.
- **Releasing also mirrors into the mod repo**, which doubles as the fork's landing page: the
  workspace-root docs → `BeamMP/docs/lan/`, the root build/host scripts → `BeamMP/tools/`, the
  bundle → `BeamMP/dist/` + its `README.md` sha table. The root copies stay the working canon.
  Rewrite relative links when mirroring — `docs/lan/` is two levels deep, so `host/` →
  `../../tools/host/` and `BeamMP/lua/…` → `../../lua/…` — and re-diff the existing mirrors, because a
  fix applied only to the published copy silently makes the "canon" the stale one. (`README-LAN.md`
  was re-synced 2026-08-07: the two copies now differ only in those five rewritten link targets.)

## Durable project state

Long-lived findings — measured perf numbers, the reasoning behind each toggle, third-party mod
fixes, release history — live in the agent memory at
`C:\Users\modde\.claude\projects\D--beamMP-rewrite\memory\` (`MEMORY.md` is the index). Read it
before re-deriving anything; `UPSTREAM-PRS.md` at the workspace root tracks what is worth sending
upstream and what has already been merged in from it.
