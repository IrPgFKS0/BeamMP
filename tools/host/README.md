# Host scripts — combined-mode (`--combined`)

Drop-in scripts for **hosting and playing on the same PC** with the combined
binary. Put these next to `BeamMP-Combined.exe` in your server folder (the one
that has `ServerConfig.toml` + `Resources/`):

```
<your server folder>\
├─ BeamMP-Combined.exe      (the combined launcher+server binary)
├─ ServerConfig.toml
├─ Resources\
├─ start-server.bat         (from here)
└─ pin-cores.ps1            (from here)
```

Then just run **`start-server.bat`**. Other players join over the LAN with
**Direct Connect → `<this-PC-LAN-IP>:<port>`** (default port 30814).

## What `--combined` is (and why it's one process + the game)

`BeamMP-Combined.exe --combined` runs the dedicated **server in-process** and
bridges **this PC's own game** to it over an **in-memory channel** (queues), not a
loopback socket. So on the host there are **two** processes that matter:

| Process | What it is | Pinned to |
|---|---|---|
| `BeamMP-Combined.exe` | server relay **+** in-memory bridge **+** launcher | the **reserved top core(s)** |
| `BeamNG.drive.x64.exe` | the game (physics + render) | the **low cores** |

They are deliberately **separate OS processes** so the relay/bridge doesn't
time-slice on the same cores as the game's physics threads — that contention is a
direct cause of host-side "ghost drift" (your own car looks fine, but remote
players see yours drift/correct). `pin-cores.ps1` enforces the split.

> The game **must** be a separate process for this — BeamNG is its own executable
> and its Lua only speaks sockets, so the game↔launcher hop stays on localhost
> loopback (ports 4444/4445). Only the launcher↔server hop is in-memory.

## CPU pinning — the host-drift lever

`start-server.bat` launches `pin-cores.ps1` minimized. It:

1. Waits for the **heavy** game process `BeamNG.drive.x64` (not the small
   `BeamNG.drive` loader — pinning the loader does nothing).
2. Pins **every** `BeamNG.drive*` process to the **low** cores.
3. Reserves the **top core(s)** for `BeamMP-Combined` (the relay/bridge).

Tune the split by editing **`$Reserve`** at the top of `pin-cores.ps1`:

| CPU | Suggested `$Reserve` |
|---|---|
| 8+ logical processors | `2` (default) |
| 4 logical processors | `1` (auto-applied) |
| ≤2 logical processors | pinning is skipped (not enough to split) |

Raise `$Reserve` if the relay still looks squeezed under load; lower it if the
game itself starves.

### Verify it worked

- **Task Manager → Details →** right-click `BeamNG.drive.x64.exe` → *Set affinity*:
  the low cores should be ticked and the top `$Reserve` core(s) **un**ticked;
  `BeamMP-Combined.exe` should show the mirror image.
- In game, the **sync-stats overlay** (Options → Multiplayer → *Show sync stats
  overlay*) "Ghost drift" row should stay low / stop reddening once pinned.

## Flags (combined binary)

`BeamMP-Combined.exe` is one binary with three modes — `--help` prints them:

| Invocation | Mode |
|---|---|
| `BeamMP-Combined.exe` | **Launcher only** — connect this PC's game to a *separate* server over the network (classic client). |
| `BeamMP-Combined.exe --combined` | **Combined host** — in-process server + this PC's game over the in-memory bridge (what `start-server.bat` runs). |
| `BeamMP-Combined.exe --server-only` | **Dedicated server only** — headless, no game launched; output to console + `Server.log`. |

Other options (`--port <n>`, `--verbose`, `--no-download`, `--no-update`,
`--no-launch`, `--full-mod-hash`, `--user-path <path>`, `--game <args...>`) are
listed by `BeamMP-Combined.exe --help`.

## Console commands (type in the combined-exe window)

| Command | What it does |
|---|---|
| `map <level path>` | **Seamlessly** switches everyone to a new map — no reconnect/reload. e.g. `map /levels/italy/info.json`. |
| `savelogs` | Writes a server-state dump next to `Server.log` (the client `/savelogs` bundles it in). |
| `help` | Lists all commands (`status`, `kick`, `say`, `list`, `settings`, `exit`, …). |

Players have matching in-game chat commands (`/maps` map picker, `/savelogs`, `/mpstate`,
`/netdebug`) — see the **Commands** section in `README-LAN.md`. Keep this console window open
while hosting.

## Linux host

There's no `.bat`/PowerShell on Linux. Run the combined binary directly and pin
with `taskset` instead:

```bash
cd /path/to/server                       # has ServerConfig.toml + Resources/
./BeamMP-Launcher --combined &           # the combined binary (server+bridge+launcher)
# after BeamNG is up, reserve the top 2 cores (example: 8 threads -> game on 0-5):
taskset -cp 0-5 "$(pgrep -f BeamNG.drive.x64 | head -1)"
taskset -cp 6-7 "$(pgrep -x BeamMP-Launcher)"
```

(See `LAN-TUNING.md` for the Linux scheduler/`rmem_max` items, which matter more
on the Linux side.)
