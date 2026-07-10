# BeamMP — LAN-only fork

A stripped-down BeamMP for **local LAN play only**: no BeamMP account, no login,
no backend, no public server list. Tuned for **aggressive, low-latency sync** and
**up to 10 players** on a single LAN.

This workspace contains three forked components:

| Folder              | Language | Role                                                        |
|---------------------|----------|-------------------------------------------------------------|
| `BeamMP-Server`     | C++      | Dedicated server. Relays vehicle/event traffic.             |
| `BeamMP-Launcher`   | C++      | Per-player launcher. Injects the mod and proxies to the server. |
| `BeamMP`            | Lua/JS   | The in-game mod that runs inside BeamNG.drive.              |

---

## What changed vs. upstream

### No login / no backend
- **Server** (`BeamMP-Server`)
  - `src/TNetwork.cpp` — `Authentication()` no longer POSTs the player key to
    `auth.beammp.com/pkToUser`. The key the client sends is now simply treated as
    the player's **name**; identity (name / role `USER` / non-guest / identifiers)
    is assigned locally.
  - `src/TConfig.cpp` — an **AuthKey is no longer required**; the server starts
    with an empty key.
  - `src/THeartbeatThread.cpp` — the backend **heartbeat is disabled** (no server
    registration, no public listing). It still regenerates the local info payload
    so the `InformationPacket` (server name/players/map shown to direct-connect
    clients via the `'I'` query in `TNetwork.cpp`) keeps working — it's just never
    POSTed anywhere.
  - `src/Common.cpp` — `CheckForUpdates()` is a no-op (no version probe).
  - `src/Settings.cpp` — defaults: `MaxPlayers = 10`, `MaxCars = 4`,
    `Name = "LAN Server"`. (`Private` was already `true`.)
- **Launcher** (`BeamMP-Launcher`)
  - `src/Security/Login.cpp` — no contact with `auth.beammp.com`. A local identity
    is generated (see **Player names** below) and sent to the server as the key.
  - `src/Startup.cpp` — `CheckForUpdates()` is a no-op; `PreGame()` installs a
    **local `BeamMP.zip`** (placed next to the launcher) instead of downloading
    the mod from the backend.
  - `src/Network/Core.cpp` — the server-list request returns an **empty list**
    (Direct Connect only).
- **Mod** (`BeamMP`)
  - `lua/ge/extensions/MPCoreNetwork.lua` — the avatar/forum HTTP request is
    removed from `loginReceived` so the game never blocks reaching the internet.
    (Auto-login already happens via `onLauncherConnected → autoLogin`, which now
    always succeeds.)

### Aggressive netcode (LAN-tuned)
- `BeamMP/lua/ge/extensions/MPUpdatesGE.lua` — event-stream send rates (vs stock):

  | Stream      | Stock   | LAN    |
  |-------------|---------|--------|
  | position    | 50 Hz   | **30 Hz default (60 max)** |
  | nodes       | 15 Hz   | 30 Hz  |
  | inputs      | 30 Hz   | 60 Hz  |
  | electrics   | 15 Hz   | 30 Hz  |
  | powertrain  | 10 Hz   | 20 Hz  |
  | controller  | 15 Hz   | 30 Hz  |

> **The POSITION rate was reversed after hardware testing (p13h33–34).** Raising it to 100 Hz
> oversubscribed the single-path relay (~150 pkt/s ceiling; 2 players × 100 Hz ≈ 200) and remote
> tracking **degraded over the session** — worse than stock. The default is now **30 Hz**, the
> in-game select is **60 / 30 / 10** (the 100 Hz option was removed), and the host's in-memory
> position buffers were tightened **256 → 16** (latest-wins, ~0.27 s cap). The predictor interpolates
> between updates, so **lower is better** — see `LAN-TUNING.md`. The other (low-volume event) streams
> stay raised. Send rate is also capped by frame rate (`onUpdate()` is per-frame).

### `TCP_NODELAY` on every TCP hop (no Nagle batching)
Position and node data already travel over **UDP** (no Nagle). The remaining TCP
channels carry reliable events/spawns/resets, and the localhost game↔launcher hop
relays *all* outbound traffic — so Nagle's algorithm there could coalesce small
writes and add latency/jitter. Nagle is now disabled on all four TCP hops:

| Hop                                | File / change                                  |
|------------------------------------|------------------------------------------------|
| server ← player (per-client sock)  | `BeamMP-Server/src/TNetwork.cpp` (`no_delay`)  |
| launcher → server                  | `BeamMP-Launcher/src/Network/VehicleEvent.cpp` |
| game → launcher (localhost, native)| `BeamMP-Launcher/src/Network/GlobalHandler.cpp`|
| game → launcher (localhost, Lua)   | `BeamMP/lua/ge/extensions/MPGameNetwork.lua`   |

### Combined host (`--combined`) — server + launcher in one process

The launcher and server are merged into a **single binary** (`BeamMP-Combined.exe`) with
three runtime modes (`--help`): launcher-only (default), `--server-only` (headless server),
and **`--combined`** (host-and-play). In `--combined` the dedicated server runs **in-process**
and the host's own game is bridged to it over an **in-memory channel** (queues, in
`BeamMP-Launcher/src/Network/CombinedHost.cpp` + `BeamMP-Server` `TClient::InMemoryLink`)
instead of a loopback socket — removing a class of host self-disconnect and the loopback hop
entirely. Other players still connect over real network sockets, unchanged. The host's game
remains a separate child process (BeamNG's Lua only speaks sockets), so the game↔launcher hop
stays on localhost loopback. See **Running a LAN session → combined mode** and the `host/`
scripts.

### Robustness for mods in the wild (graceful failure ≥ stock)

A core goal of this fork is that a **broken or unmatched 3rd-party mod can't take down the
session** — at least as gracefully as stock BeamMP. The dangerous class is a Lua error inside a
per-vehicle **VE** module (or the **GE** receive loop), which kills that vehicle's whole sync
VM → one-way desync. Hardening (ongoing; see the mod patch notes):
- The top-level GE network dispatch and the controller-sync receive dispatch are **pcall-wrapped**
  — a bad packet / removed BeamNG API / broken mod is logged, not fatal.
- GE→VE command sites are guarded (`if XxxVE then …`), `jsonDecode` results are nil-checked, and
  removed BeamNG-0.3x APIs are guarded (`beamstate.beamDeformed`/`beamBroken`, capital-case typos).
- The combined host **logs-and-skips** a single missing/failed mod instead of aborting the join;
  the server's decompression buffer grows safely; a failed/partial vehicle spawn no longer FATALs.

---

## Building

The native components are C++/CMake using **vcpkg** for dependencies (the server
bundles vcpkg as a submodule and builds boost/lua/openssl/etc. from source on the
first configure, so the first build is slow). The mod needs no compilation.

> **The launcher IS the combined host exe.** `BeamMP-Launcher` statically embeds the
> dedicated server (the `embed-server` vcpkg feature); launched with `--combined` it
> runs the server in-process alongside the host's game. So **building the launcher
> produces the combined executable** — on Windows the build output is
> `BeamMP-Launcher.exe` (rename to `BeamMP-Combined.exe`); on Linux it's `BeamMP-Launcher`.
> The launcher build compiles the embedded server lib itself, so you do **not** need to
> build the standalone `BeamMP-Server` first — that separate binary is only needed if you
> run a *dedicated* server on its own machine. Because the launcher links the server
> **statically**, every native build below uses the **`x64-windows-static`** triplet (Windows)
> / default `x64-linux` static deps (Linux) so the server lib and launcher share one ABI.

> **Architecture matters.** Binaries match the build machine's architecture. A
> typical BeamNG/Linux host is **x86_64** — build there (or with an x86_64
> toolchain), not on an ARM machine.

Branches in use (the current, mutually-compatible lines):

| Repo            | Branch        | Notes                                              |
|-----------------|---------------|----------------------------------------------------|
| `BeamMP-Server` | `minor`       | server v3.9.x                                      |
| `BeamMP-Launcher` | `master`    | current launcher                                   |
| `BeamMP`        | `development` | newest mod line — best match for the latest BeamNG |

> The mod's `development` branch is the most up-to-date with current BeamNG game
> files. If you instead run the *last stable* BeamNG release, the `public` branch
> may match it better — but you'd need to re-apply the LAN edits onto it.

First, fetch submodules (the shallow clones in this workspace did **not** include
them):

```bash
cd BeamMP-Server   && git submodule update --init --recursive && cd ..
cd BeamMP-Launcher && git submodule update --init --recursive && cd ..
```

### Option A — Linux, natively (recommended for a Linux host)

Build deps (Debian/Ubuntu):
```bash
sudo apt-get install -y liblua5.3-0 liblua5.3-dev curl zip unzip tar \
    cmake make git g++ ninja-build pkg-config autoconf automake libtool python3 \
    bison flex perl build-essential
```
(`bison`/`flex`/`perl`/`build-essential` are required for vcpkg to build openssl
and other deps from source — leaving them out is the most common first-build
failure.)

Server:
```bash
cd BeamMP-Server
./vcpkg/bootstrap-vcpkg.sh                          # first time only
cmake . -B bin -DCMAKE_TOOLCHAIN_FILE=./vcpkg/scripts/buildsystems/vcpkg.cmake \
    -DCMAKE_BUILD_TYPE=Release -DBeamMP-Server_ENABLE_LTO=ON
cmake --build bin --parallel -t BeamMP-Server      # -> bin/BeamMP-Server
```
(`-DBeamMP-Server_ENABLE_LTO=ON` gives a faster binary but a slower build; drop it
for quicker iteration. The Docker script uses LTO=OFF for speed.)

Launcher — the launcher's `vcpkg.json` has **no builtin-baseline**, so (unlike the
server) its deps must be installed in vcpkg **classic mode** with manifest mode off.
The catch: vcpkg switches to *manifest* mode whenever the current directory holds a
`vcpkg.json` (and then rejects per-package args), so run the install from a directory
**without** a manifest (e.g. `/tmp`), reusing the server's already-bootstrapped vcpkg:
```bash
# build the server first (above); then, from the workspace root:
VCPKG="$PWD/BeamMP-Server/vcpkg/vcpkg"
( cd /tmp && "$VCPKG" install zlib nlohmann-json openssl "cpp-httplib[openssl]" curl --triplet x64-linux )
cd BeamMP-Launcher
cmake . -B bin-linux -DCMAKE_TOOLCHAIN_FILE=../BeamMP-Server/vcpkg/scripts/buildsystems/vcpkg.cmake \
    -DVCPKG_MANIFEST_MODE=OFF -DCMAKE_BUILD_TYPE=Release
cmake --build bin-linux --parallel                  # -> bin-linux/BeamMP-Launcher
```
This is exactly what `build-linux-docker.sh` does (the recipe verified by an actual
container build — both binaries land in `dist/linux/`). Use a dedicated `bin-linux`
build dir so a Linux build never collides with a Windows CMake cache in `bin/`.

Runtime dep on Linux: `liblua5.3-0` (server). Launch BeamNG's native Vulkan
build, then run the launcher.

### Option B — Linux, via Docker (build from any host)

`build-linux-docker.sh` builds **both** binaries from the local sources inside
`ubuntu:24.04` and drops them in `dist/linux/`:
```bash
./build-linux-docker.sh                    # native arch of the build host
TARGET_PLATFORM=linux/amd64 ./build-linux-docker.sh   # force x86_64 (QEMU, slower)
```
Outputs: **`dist/linux/BeamMP-Launcher`** is the combined host exe (run with `--combined`);
`dist/linux/BeamMP-Server` is the standalone dedicated server. Use
`TARGET_PLATFORM=linux/amd64` on an Apple-Silicon Mac to produce x86_64 binaries for a
normal Linux host. This is the easiest way to get the Linux combined exe.

### Option C — Windows (MSVC)

Cross-compiling Windows binaries from Linux/macOS is **not supported** (vcpkg +
Win32/WinSock/WinCrypt). Build on Windows, or use CI (below). You need **Visual Studio
2022** (Desktop C++ workload) and Git, with submodules fetched. Run these from a
**"x64 Native Tools Command Prompt for VS 2022"** (so `cmake`/`ninja`/the MSVC toolchain
are on `PATH`).

**Combined host exe** (this is the one hosts run — it builds the embedded server lib itself):
```bat
cd BeamMP-Launcher
cmake . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_TOOLCHAIN_FILE=..\BeamMP-Server\vcpkg\scripts\buildsystems\vcpkg.cmake ^
  -DVCPKG_TARGET_TRIPLET=x64-windows-static
cmake --build build --parallel --config Release
:: -> build\BeamMP-Launcher.exe   (rename to BeamMP-Combined.exe; run with --combined)
```

**Standalone dedicated server** (only for a separate server machine):
```bat
cd BeamMP-Server
cmake . -B bin -G Ninja -DCMAKE_BUILD_TYPE=Release -DBeamMP-Server_ENABLE_LTO=ON ^
  -DVCPKG_TARGET_TRIPLET=x64-windows-static
cmake --build bin --parallel -t BeamMP-Server --config Release
:: -> bin\BeamMP-Server.exe
```

The `x64-windows-static` triplet and Ninja generator are **required** — the launcher links
the server statically, so a default (dynamic) build won't produce a working combined exe.

> **Convenience scripts:** the repo root ships **`build-launcher.bat`** (combined exe) and
> **`build-server.bat`** (standalone server) wrapping exactly the above. They're **portable** —
> they auto-locate Visual Studio via `vswhere`, put the VS-bundled CMake/Ninja on `PATH`, and
> anchor every path to the script's own folder (`%~dp0`). Just double-click or run them from a
> plain `cmd` (no "x64 Native Tools" prompt and no editing needed); they call `vcvars64` themselves.

### Option D — CI (GitHub Actions, both platforms)

Each repo ships workflows that build on GitHub-hosted runners — this is the
easiest way to get **both** Windows and Linux x86_64 binaries without local
toolchains:
- `BeamMP-Server/.github/workflows/{linux,windows}.yml`
- `BeamMP-Launcher/.github/workflows/cmake-{linux,windows}.yml`

Push the fork to a GitHub repo (with submodules) and download the build artifacts
from the Actions run. The server's `release.yml` also references a private
`Beamlings` repo for cosmetic avatars — not needed; use `package_mod.sh` for the
LAN mod zip instead.

### Mod (`BeamMP`) — package, don't compile

```bash
./package_mod.sh        # produces ./BeamMP.zip in this folder
```
Copy `BeamMP.zip` next to each player's launcher executable.

---

## Running a LAN session

There are two ways to host. **Combined mode is the recommended one** if the host also
plays on the same PC; the separate-server setup (further below) is for a dedicated
server box.

### Host — combined mode (recommended: host *and* play on one PC)

The combined binary (`BeamMP-Combined.exe`) is one executable with three modes. In
`--combined` it runs the dedicated **server in-process** and bridges the host's own
game to it over an **in-memory channel** (no loopback launcher↔server socket); BeamNG
runs as a normal child process and other players join over the LAN as usual.

1. Put these together in your server folder (the one with `ServerConfig.toml` +
   `Resources/`): `BeamMP-Combined.exe`, `BeamMP.zip`, and the two scripts from the
   repo's [`host/`](host/) folder — `start-server.bat` and `pin-cores.ps1`.
2. Run **`start-server.bat`**. It launches `BeamMP-Combined.exe --combined` and a
   CPU-pinning helper (see below). The host's BeamNG starts automatically.
3. Other players: put `BeamMP.zip` next to *their* launcher, run it, and
   **Multiplayer → Direct Connect → `<host-LAN-IP>:30814`**.

> **CPU pinning matters here (it's the host-side drift lever).** `pin-cores.ps1`
> waits for the real `BeamNG.drive.x64` process, pins the **game** to the low cores,
> and **reserves the top core(s)** for the in-process relay/bridge so they stop
> time-slicing against the game's physics threads. Tune `$Reserve` in that script
> (default 2; 1 on a small CPU). See [`host/README.md`](host/README.md) and the
> **Combined host** section of [`LAN-TUNING.md`](LAN-TUNING.md). On Linux there's no
> `.bat`; run `./BeamMP-Launcher --combined` and pin with `taskset` (see `host/README.md`).

`BeamMP-Combined.exe --help` lists the modes: *(no flag)* = launcher-only (classic
client), `--combined` = combined host, `--server-only` = headless dedicated server.

### Host — separate dedicated server (alternative)

#### 1. Host the server (one machine)
Run the server once to generate `ServerConfig.toml`, then start it again.
With this fork the config needs **no AuthKey**. Useful keys:

```toml
[General]
Name = "LAN Server"
Port = 30814
MaxPlayers = 10
MaxCars = 4
Map = "/levels/gridmap_v2/info.json"
AuthKey = ""          # left empty on purpose — LAN build ignores it
```

Make sure the host's firewall allows **TCP and UDP on the port** (default 30814).
Note the host's LAN IP (e.g. `192.168.1.50`).

### 2. Each player
1. Put `BeamMP.zip` next to the launcher executable.
2. Start the launcher (no flags needed). It installs the mod, auto-logs-in with a
   local name, and launches BeamNG.
3. In game: **Multiplayer → Direct Connect → `192.168.1.50:30814`**.

No login screen appears; players land directly in the server browser / Direct
Connect view.

---

## Commands

Two places: typed in the in-game **chat box** (any player), or in the **server console**
(the combined-exe window, or a dedicated server's terminal).

### In-game chat commands (LAN-fork additions)

| Command | What it does |
|---|---|
| `/maps`  (or `/map`, `/map list`) | Opens the interactive **map picker** overlay — click a level to switch. |
| `/map <name>` | Requests a switch to that level directly (what the picker sends on click); the server performs it, admin-gated. |
| `/savelogs` | Bundles **all** logs (game + launcher + server) into one timestamped zip in the launcher folder — for a bug report. Also a button under **Options → Multiplayer → advanced → "Save all logs (zip)"**. |
| `/mpstate` | Dumps the current multiplayer state (role, session, players, vehicles, key settings) to the console/log. |
| `/netdebug [on\|off]` | Toggles verbose network-debug logging (`showDebugOutput`); no argument flips it. |

These are handled locally and are **never** sent to chat / seen by other players.

### Server console commands

Type these in the combined-exe window (or a dedicated server's terminal):

| Command | What it does |
|---|---|
| `map <level path>` | **Seamlessly** switches all clients to a new map — no reconnect, no Lua reload, no mod re-sync. e.g. `map /levels/italy/info.json`. |
| `savelogs` | Writes a server-state dump next to `Server.log` (the client `/savelogs` then bundles this in automatically). |
| `help` | Lists every console command — including the standard upstream set (`status`, `kick`, `say`, `list`, `settings`, `exit`, …). |

> `map` is the LAN fork's seamless level-switch (see [Keeping up with BeamNG updates](#keeping-up-with-beamng-updates) for VRAM notes); `savelogs` is the fork's support-bundle helper. Keep the combined-exe console window open while hosting.

---

## Player names

Names are handled in `BeamMP-Launcher/src/Security/Login.cpp`:

1. On first run a name like **`Player_3f9a`** is generated and saved to a file
   named `name` next to the launcher.
2. To choose your own name, either:
   - set the environment variable **`BEAMMP_NAME=Alice`**, or
   - edit the **`name`** file.

Names are sanitized (alphanumerics, space, `_ - .`) and capped at 32 chars. The
server trusts whatever name the client sends — fine for a trusted LAN.

---

## Linux host tips (LAVD, Vulkan, firewall)

**Native Vulkan BeamNG.** Launch BeamNG's native Linux build with the Vulkan
renderer. The mod and launcher are renderer-agnostic; higher/steadier FPS just
means your configured position send rate is actually reached (see the frame-rate
note above).

**sched_ext / scx_lavd.** LAVD is a latency-criticality–aware sched_ext
scheduler — a good fit for interactive gaming workloads. It auto-detects
latency-critical tasks from their runtime behavior, so the game, launcher, and
server benefit without per-process tuning. Rough setup:
- Kernel with `sched_ext` support (mainline 6.12+, or a distro shipping scx such
  as CachyOS / Fedora's `scx-scheds`).
- Install the scx schedulers package and start it, e.g. `sudo scx_lavd` (or via
  `scx_loader` / your distro's service). `scx_lavd --help` lists modes; the
  performance-oriented mode favors responsiveness on AC power.
- Verify it's active: `cat /sys/kernel/sched_ext/root/ops` should report the
  running scheduler.

LAVD only affects local scheduling, not the wire protocol — so it helps whether
the server runs on the same box as the game or a separate one.

**Firewall.** Open the server port (default 30814) for **both TCP and UDP**:
- ufw: `sudo ufw allow 30814/tcp && sudo ufw allow 30814/udp`
- firewalld: `sudo firewall-cmd --add-port=30814/tcp --add-port=30814/udp`

**Mod filename on Linux.** BeamNG's Linux build rejects uppercase mod names, so
the launcher installs the zip as `mods/multiplayer/beammp.zip` (lowercase). You
still keep the source file named **`BeamMP.zip`** next to the launcher —
`package_mod.sh` produces that name and the launcher renames it on copy.

## Tuning further

- **Send rates:** `BeamMP/lua/ge/extensions/MPUpdatesGE.lua` (top of file).
- **Receiver smoothing:** `BeamMP/lua/ge/extensions/positionGE.lua`
  (`smoothPosExec`, the 8 ms gate). Lower the gate / adjust the median seed for
  even snappier (but potentially jitterier) motion.
- **Player / car limits:** `BeamMP-Server` `ServerConfig.toml` (`MaxPlayers`,
  `MaxCars`).

After editing any Lua in `BeamMP/`, re-run `./package_mod.sh` and redistribute
`BeamMP.zip`.

## Performance & profiling

The mod's logic runs in two LuaJIT VMs:

- **GE** (game engine — one per session): `MPVehicleGE`, `positionGE`, `nodesGE`,
  `MPCoreNetwork`, the per-frame nametag/minimap loop in `MPVehicleGE.onPreRender`, etc.
- **VE** (one per vehicle): `positionVE`, `nodesVE`, `velocityVE`, `MPInputsVE`,
  `MPElectricsVE`, … — these run on the physics step and send your vehicle's state.

### Profile the position-sync hot path (built-in)

The position pipeline is the busiest per-vehicle path and it spans **both** VMs:
data arrives on the network handler (`positionGE.handle` → `applyPos`, GE) and is
applied every physics/graphics frame (`positionVE.setVehiclePosRot` / `updateGFX`,
VE). Because `handle`/`applyPos` fire from the **network event handler — not the
frame loop** — the per-frame profilers below can't see them. So the mod ships an
opt-in `hptimer` for exactly these three functions, gated by the `profilePosSync`
setting (default off).

Open the GE console (**`~`** / grave) and enable it:
```lua
settings.setValue("profilePosSync", true); positionGE.onSettingsChanged()
```
> `profilePosSync` is also a checkbox under **Options → Multiplayer** once
> **"show advanced options"** is ticked (in the "LAN — position sync &
> performance" section) — the console line is just the scriptable equivalent.

#### Settings for the test — set these on **every** machine in the session

The capture only makes sense if both ends are configured the same, because each
machine measures *its own* send rate and what it receives from the other. Set
these identically on all players (console one-liner below the table, or the
**Options → Multiplayer** checkboxes with "show advanced options" on):

| Setting | Value | Why |
|---|---|---|
| `profilePosSync` | **on** | emits the `posProf` timing/rate lines |
| `enablePosSmoother` | **off** (default) | keeps `applyPos` equal to the raw received-packet rate; the smoother re-routes applies through `onPreRender` and changes what the rate means |
| *"show advanced options"* (UI only) | on | just to reveal the experimental checkboxes — not a sync setting |

```lua
-- paste on each machine's GE console (~):
settings.setValue("profilePosSync", true)
settings.setValue("enablePosSmoother", false)
positionGE.onSettingsChanged()
```

Both players must be in the **same session** and **actively driving/crashing** for
the whole window. When done, set `profilePosSync` back to `false` (it's debug-only).

> **Auto log collection.** Turning `profilePosSync` **off** automatically zips the
> machine's `beamng.log` + its rotations into a bundle (gated by `autoCollectProfLogs`,
> default on) so a capture is never missed and is always zipped correctly. The zip lands
> in the **`profLogFolder`** subfolder of the BeamNG user folder (default `BeamMP_logs`,
> set it under **Options → Multiplayer → advanced → "Log-bundle folder"**), and a toast
> shows the exact full path. Collect this machine's profiling bundle on demand from the
> GE console with `MPConfig.collectProfilingLogs()`, or use the **"Save all logs (zip)"**
> button there for a full game + launcher + server bundle (`MPConfig.saveLogs()`). Do this on **each**
> machine — Lua can only reach its own logs. (The game sandboxes file writes to the user
> folder, so the bundle can't go straight to an arbitrary external drive; grab it from the
> path in the toast.) Then copy each machine's zip off manually (e.g. to a shared
> folder) when you want to compare LAN1 vs LAN2.
>
> **Upload-to-server was tried and removed.** An in-game "upload my log bundle to the
> server" button (chunked over the `TriggerServerEvent` channel to a `BeamMPLogReceiver`
> server plugin) was prototyped but **dropped**: BeamMP's client→launcher socket
> (`MPGameNetwork.sendData`) is built for tiny position packets and **retries a failed
> send indefinitely on the game thread**, so pushing a multi-MB log bundle through it —
> even paced at one small 8 KB chunk per frame — saturates the socket and **hangs the game**
> (`STATUS_APPLICATION_HANG`). It's not safely fixable without reworking the launcher's
> blocking send. Use the local zip above + a manual copy instead.

Drive/crash with **≥2 players** for ~20 s, then filter the `posProf` lines out of
`beamng.log`:

```powershell
# Windows (PowerShell):
Select-String posProf "$env:LOCALAPPDATA\BeamNG\BeamNG.drive\current\beamng.log"
```
```bash
# Linux:
grep posProf ~/.local/share/BeamNG.drive/current/beamng.log
```
(`current` is the active-version folder. If your user folder is elsewhere, it's
`<BeamNG userfolder>/current/beamng.log` — the path is printed near the top of the
log and in the launcher console.) You get one summary line per metric every ~5 s.
On each machine you'll see both the **send** side (its own car) and the **receive**
side (the other player's car):
```
VE getVehicleRotation n=600 rate=120/s avg=0.0102ms max=0.18ms   # SEND: how fast THIS machine emits its own car
GE applyPos           n=560 rate=112/s avg=0.0143ms max=0.21ms   # RECV: how fast it applies the other car (GE)
VE setVehiclePosRot   n=560 rate=112/s avg=0.0089ms max=0.15ms   # RECV: VE side of the same apply
VE updateGFX          n=300 rate=60/s  avg=0.0250ms max=0.40ms   # predictor work on remote car (fresh-data frames)
VE updateGFX.frames   n=300 rate=60/s                            # render FPS for the remote car
VE updateGFX.stale    n=5   rate=1/s                             # frames the predictor sat starved (no fresh packet)
```
`avg`/`max` are milliseconds, `rate` is calls/second (the count-only lines have no
avg/max). Disable with `profilePosSync=false`. (If the VE state exposes no high-perf
timer, `avg`/`max` read `0.0000` but every `rate` is still valid.)

**How to read it — where does the send rate collapse to ~10 Hz?**
- Compare **machine A's `getVehicleRotation` rate** with **machine B's `applyPos`
  rate** (B receiving A). Equal → no loss. A sends at its set rate but B applies ~10 → loss in
  **transit** (relay / UDP / launcher hop). A only *sends* ~10 → the sender is
  **FPS-capped or throttled** (the send tick is frame-gated, and a heavy crash tanks FPS).
- `updateGFX.frames` ≈ that machine's **render FPS** for the remote car. If it's low
  (~20), the limiter is overall frame rate (mods + crash physics), not the sync code.
- `updateGFX.stale` high → the predictor is **starving**: packets arrive slower than
  the 0.1 s timeout, so the remote car freezes/warps between updates.

> **`beamng.log` stops recording after 15000 entries.** The CEF UI debug spam
> fills it fast, so profile **promptly after launch** and grab the `posProf` lines
> before the cap — a long idle session may already have stopped logging by the time
> you crash.

### Other profilers (built into BeamNG)

1. **GE per-frame breakdown** — `requestGeluaProfile()` writes a one-frame timing of
   every GE `update()`/`onPreRender` extension hook to `beamng.log`. Good for the
   **`MPVehicleGE.onPreRender`** nametag/minimap loop and other per-frame GE work —
   but note it does **not** cover `positionGE.applyPos`/`handle` (event-driven; use
   `profilePosSync` above) or anything VE-side. Run it a few times while two players
   drive.
2. **JIT-trace check** — find code the JIT can't compile (a common hidden cost):
   ```lua
   jitprobe()    -- start
   -- drive / crash for a few seconds
   jitprobe()    -- stop
   ```
   This toggles LuaJIT's verbose trace log. Repeated `NYI`/trace-abort lines point
   at hot functions that fall back to the interpreter — prime optimization targets.

3. **World Editor profiler** — press **F11**, open the Profiler/Performance views
   for a visual per-frame CPU breakdown (GE + engine; not VE Lua internals).

### Profile the server / launcher (C++)

Both are native C++, so the Lua profilers above don't apply:

- **Server:** set `Debug = true` in `ServerConfig.toml` for verbose timing logs
  (it already prints per-mod hash times and per-download "Scoped timer" lines). For
  CPU profiling, run it under a sampling profiler — Visual Studio Profiler / VTune
  on Windows, `perf record` + a flame graph on Linux. Hot paths: `TNetwork`
  (TCP event + UDP position relay) and the Lua plugin engine (`TLuaEngine`).
- **Launcher:** run it with `-v` for debug logging. Its cost is almost all I/O
  (mod sync — now streamed to disk) and the localhost game↔server relay; CPU is
  negligible.

### What's already optimized, and what to measure next

- **Done:** the position sender (`positionVE.getVehicleRotation`) reuses a
  single send table instead of allocating one per send (less GC churn). Mod-sync
  downloads stream straight to disk (no multi-GB RAM spikes). `MPVehicleGE.onPreRender`
  now reads its frame-invariant settings (and `commands.isFreeCamera()`) **once per
  frame** instead of ~16× per remote vehicle per frame, so that loop's cost no longer
  scales with car count (ported in spirit from Olrosse #838).
- **`physicsRateSend`** (LAN **default-on**, A/B verified): the position *send* is
  normally driven once per render frame ([MPUpdatesGE.lua](BeamMP/lua/ge/extensions/MPUpdatesGE.lua), and the
  `(positionTimer - tickrate) % tickrate` line discards backlog), so the real send
  rate is **capped at your FPS** — a machine at 16 fps only emits ~16 updates/s no
  matter your send-rate target. With this on, the owned car emits from the **VE physics
  step** (`positionVE.update`, ~2000 Hz) at the configured rate (default 30 Hz) instead, so a low-FPS
  machine still sends fresh data. GE arms the self-send each frame (`armSelfSend`);
  the packet carries a physics-rate timestamp so the receiver doesn't dedupe the
  faster stream. It won't raise the *remote*'s frame rate, but it improves the
  positional accuracy others extrapolate from. Verify with `profilePosSync`:
  ```lua
  settings.setValue("physicsRateSend", true); positionGE.onSettingsChanged()
  ```
  `getVehicleRotation` rate should climb toward ~100/s even while `updateGFX.frames`
  (your FPS) stays low — that gap is exactly what this fixes. It's send-side only
  and doesn't change the wire format, so clients can run it independently.
- **`mailboxApplyPos`** (LAN **default-on**, A/B verified): delivers incoming positions on
  the **GE→VE apply hop** via the engine mailbox (`be:sendToMailbox("mpPos"..gameVehicleID,
  json)`) instead of compiling a `queueLuaCommand` string per packet. The VE polls
  `obj:getLastMailbox("mpPos"..obj:getID())` once per frame in `updateGFX` (latest-wins,
  exactly right for position). No Lua compile, no base64; **when off it falls back to the
  legacy base64 `queueLuaCommand` path**. Coexists with `physicsRateSend` (the *send* hop).
  Same engine mailbox API BeamNG itself uses (`map.lua`/`platooning.lua`); ported from
  Olrosse #838. Measured **~25–40% cheaper `GE applyPos`** on both machines and removes the
  per-packet VE Lua-command compile. Doesn't touch the wire format, so clients can flip it
  independently (toggle off via the options checkbox if ever needed).
- **View-distance freeze of far cars — tried twice, removed for good.** A `setActive(0)`-based
  freeze of distant remote cars (KISS-MP idea) was attempted twice. The first version computed the
  distance from the frozen mesh so cars never un-froze; the second fixed that (network position) but
  hit the **real blocker**: `setActive(0)` **deactivates the whole VE Lua state** of the frozen car,
  so **every** BeamMP VE sync module on it goes nil — `positionVE`, `MPInputsVE`, `MPElectricsVE`,
  `MPPowertrainVE`, `ControllerSyncVE`, `NodesVE`, `CouplerVE` — and the GE side kept pushing to it,
  producing `attempt to index global 'MPInputsVE' (a nil value)` **fatal errors** and total desync
  (the car stayed invisible until you toggled freeze off). KISS-MP gets away with `setActive(0)`
  because it syncs almost nothing (just a transform); BeamMP syncs **seven** VE modules, so a freeze
  would have to guard every GE→VE apply path — large, error-prone, and untestable here. Not worth it;
  removed. The per-car soft-body sim cost stays inherent — the levers are **car count + FPS**.
- **`optimizeMapMarkers`** (LAN, **default-on**, ported from Olrosse/BeamMP
  `minimap_lag_workaround`): BeamNG runs `gameplay_markerInteraction.onPreRender` **every
  frame** (mission/POI marker raycasts) — a documented FPS sink in MP that's useless for LAN
  driving (you can't start singleplayer missions in a session anyway). On MP join,
  [multiplayer.lua](BeamMP/lua/ge/extensions/multiplayer/multiplayer.lua) swaps that hook for
  `nop` and hides the mission markers; `onServerLeave` restores both. Every engine call is
  guarded (`if gameplay_markerInteraction then`), so it no-ops safely if a BeamNG API change
  renames it. Applied once at join — to A/B it, toggle and rejoin. Toggle off ("Optimize map
  markers") only if you specifically want vanilla freeroam markers in MP.
- **Electrics sync is already optimized** (checked against Olrosse `electrics_cleanup`): our
  [MPElectricsVE.lua](BeamMP/lua/vehicle/extensions/BeamMP/MPElectricsVE.lua) already rounds every
  numeric electric (`round2(val, 4)`), sends **only changed** values (diff), and excludes
  ESC/TCS/brake-glow/filament keys — so there was nothing to port. (Could round more aggressively
  than 4 dp to cut sends further, but that risks visible gauge quantization, so only with measurement.)
- **Still inherent (measure before touching the rest):** each synced packet still
  costs a JSON encode/decode on the wire. The **server wire format** (the `Zp:` JSON
  payload) is shared by every client and the relay, so don't change *that* without
  profiling proof and a both-ends + server plan. The apply-path toggle above
  (`mailboxApplyPos`) is safe precisely because it leaves the wire
  format alone — it only changes how a received packet is delivered/processed locally.
- **Candidate hotspots to profile first:** `positionVE.updateGFX` (the per-frame
  predictor/error-corrector — runs every graphics frame per remote vehicle; prime
  suspect at low player counts), `positionGE.applyPos`/`handle`, and the
  `MPVehicleGE.onPreRender` per-vehicle loop (engine calls like
  `getObjectOOBBCenterXYZ`/`getDirectionVector` for every vehicle every frame). (The
  experimental full-deformation sync was **removed entirely** in p13h57 — it was
  intrinsically too CPU-heavy on both the sender and every receiver.)
- **Safe wins if a profile points at them:** reuse send tables in
  `nodesVE`/`MPInputsVE`/`MPElectricsVE` (same pattern as `positionVE`); string-buffer
  packet construction on the send path (Olrosse #838 — modest at LAN vehicle counts, so
  deferred). Small; only worth doing if the profiler shows they matter. (The nametag-loop
  settings/`isFreeCamera` caching is now done — see "Done" above.)

The biggest real lever remains the **send rates** (above) — they trade CPU/bandwidth
for sync latency, and position is already capped by your frame rate.

## Keeping up with BeamNG updates

BeamNG.drive updates can change Lua/UI APIs and break the mod. When a new BeamNG
release lands:
1. In `BeamMP/`, `git fetch` and check out (or rebase onto) the branch that
   matches the new game — usually `development` first, then `public` once a stable
   release is tagged. Re-apply the LAN edits (they live in `MPUpdatesGE.lua`,
   `positionGE.lua`, `MPCoreNetwork.lua`, `MPGameNetwork.lua`).
2. Bump the launcher/server to matching tags if BeamMP ships a protocol change
   (watch the `new-protocol` work upstream). The current handshake is launcher
   v2.8.0 ↔ server min-client v2.7.0 — compatible.
3. Re-run `./package_mod.sh` and rebuild the launcher/server.

The LAN edits are small and localized, so re-applying them after an upstream pull
is quick (`git diff` against the upstream branch shows exactly what to port).

---

## Caveats

- The server's `nettest` console command still calls `check.beammp.com`; it's
  manual-only and irrelevant on a LAN (it just won't report anything useful).
- No anti-cheat / key verification — anyone on the LAN can pick any name. This is
  intentional for trusted local play.
- The cosmetic "Beamlings" avatars (a private upstream repo) are omitted from the
  packaged mod; they aren't needed for LAN play.
