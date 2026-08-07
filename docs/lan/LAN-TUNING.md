# BeamMP LAN fork — system & OS tuning

Tuning to stop remote-car drift and get the most out of the LAN fork. Ordered by impact for
*this* setup (2 machines; host runs game **and** server; positions sync over UDP via a
single-threaded server relay). Apply the **Tier 1** items first — they directly address the
"UDP buffer overflow → dropped position packets → drift" root cause.

> **Hosting with `--combined`?** Read the **Combined host** section immediately below first — it
> changes a couple of the assumptions here (the host↔server hop, the `SO_RCVBUF` item, and the
> Tier 2 CPU-affinity trick).

> **Sync send rate (updated p13h33–h35) — LOWER is better, not higher.** The in-game **Position
> send rate** now defaults to **30 Hz** (was 100); the dropdown is **60 / 30 / 10** — the 100 Hz
> option was *removed* because it oversubscribed the single-path relay (~150 packets/sec ceiling)
> and made remote tracking **degrade over the session** (hardware-confirmed worse than stock's
> 10 Hz). The host's in-memory position buffers are now tight (latest-wins, ~0.27 s cap, was ~4 s).
> The predictor interpolates between updates, so a higher rate doesn't look smoother: **30 Hz is the
> sweet spot, 60 Hz the practical 2-player ceiling, 10 Hz exactly stock BeamMP.** If a remote car
> drifts, go *down* (or cut AI/traffic count) — raising the rate makes it worse.
>
> **But don't go all the way to 10 Hz (p13h49):** 10 Hz packets arrive every 100 ms, which is
> exactly the fork predictor's `packetTimeout` (0.1 s) — the predictor regularly *idles* between
> packets (`updateGFX.stale` 2–4/s in a live log) and the ghost visibly steps instead of gliding.
> 10 Hz exists for stock-parity testing; for play, **30 Hz on every machine** is the floor.

---

## Combined host (`--combined`) — one process, in-memory host link

The recommended host setup is the **`--combined`** binary (run via `start-server.bat`): ONE process
runs the dedicated server **in-process** and bridges the host's own game to it over an **in-memory
channel** instead of a loopback socket. LAN2 is unchanged — it still connects to the server over
real network sockets. Several items below assume the old separate-server model; here's what differs
for a `--combined` host.

**What changes**
- **The host↔server loopback socket is gone.** The host's game still talks to the launcher over
  loopback TCP (ports 4444/4445 — unavoidable: BeamNG is a separate process and its Lua only does
  sockets), but the **launcher↔server** hop is now an in-memory queue, not loopback UDP/TCP.
- **No socket backpressure on the host's link.** A loopback socket throttles the sender when its
  buffer fills; an in-memory queue doesn't. So the queues are **bounded in code**: the position/UDP
  queues are **drop-oldest** (latest-wins — a dropped position self-corrects on the next one), and
  the event/TCP queues are **never dropped** but **log a backlog warning** past a generous cap (a
  backlog means the reader stalled). A runaway can't grow unbounded / OOM the host — but…
- **The send-rate throttles matter MORE here, not less.** With no loopback backpressure, an
  over-high position send rate floods the in-memory queue → the relay → LAN2 faster. Keep them sane.

**Per-setting verdict (`--combined` host)**

| Setting | In `--combined` |
|---|---|
| `physRateSendHz` / Physics-rate position send | **Keep** — still governs the LAN2 leg (matters *more* now) |
| `trafficTickrate` (AI/traffic throttle) | **Keep** — still throttles relay → LAN2 |
| `mailboxApplyPos` | **Keep** — receive/intra-game, transport-agnostic |
| Host launcher `SO_RCVBUF` (Tier 1) | **No-op / skipped** — there's no host↔server socket to buffer. The **server's** receive buffer (for LAN2) still matters; leave it. |
| Sync-stats overlay | **Keep** — as the host, read "relay starving" as the **LAN2 network leg**, not the in-memory hop (which has no buffer to overflow) |

**CPU pinning — this OVERRIDES Tier 2's `/affinity` advice.** The `--combined` binary *launches
BeamNG as a child*, and on Windows a child inherits the parent's CPU affinity — so `/affinity` at
launch would pin (and cripple) the game too. Instead, **`start-server.bat` runs `pin-cores.ps1`**,
which waits for BeamNG to start, then gives the game the low cores and **reserves the top core(s)
for the combined process's relay/bridge** — restoring the Tier 2 relay-vs-game core split while
keeping the in-memory transport. Tune `$Reserve` in `pin-cores.ps1` (default 2 logical processors;
1 on a small CPU). `/high` stays (BeamNG inherits it, fine for a foreground game). **This pin is the
direct lever for host-side ghost drift** — the relay no longer time-slices against the game's physics
threads. (Note: `/high` puts the combined process above background apps but *equal* to the game, so
without this core reservation the relay still gets squeezed under load — which is what drove the
host-side corrections seen in testing.)

---

## Remote / over-the-internet (point-to-point) — tuning

This fork is **LAN-first**, but because it's a **direct-connect** build (no BeamMP master
server / relay — the client connects straight to the host's `IP:port`), it also works for a
small **point-to-point** game over the internet. The netcode is tuned aggressively for a
<1 ms LAN, so over a real internet path (10–100 ms latency, some packet loss, a limited home
uplink) you must **dial it back** or you'll flood the link and see drift. Done right it can be
**as good as or better than** stock BeamMP for 2–4 friends, because you keep the fork's bigger
UDP buffers, per-client send mutex, the client-side latest-wins receive drain, and the **tunable send rate** — but it's
a direct peer link, so the quality of the two connections is the ceiling (there's no hosted relay
smoothing the route).

### 1. Get the peers connected (pick one)
- **Easiest — a mesh VPN (recommended): Tailscale / ZeroTier / WireGuard.** Install on both
  machines; they get private addresses (e.g. `100.x.x.x`) and the remote player Direct-Connects to
  the **host's VPN IP**:`<port>`. No router config, it's encrypted, and it makes the link behave
  like a LAN (so most LAN advice here still applies). This is the least-pain path and usually the
  best-behaved.
- **Port-forward** on the host's router: forward the server port (default **30814**) for **both
  TCP and UDP** to the host PC, and have the remote connect to the host's **public** IP. Also allow
  the port through the host firewall (already covered below). More fiddly and exposes the port.

### 2. Settings to change from the LAN defaults (in-game: Options → Multiplayer)
| Setting | LAN default | Remote | Why |
|---|---|---|---|
| **Position send rate** | **30 Hz** (max 60) | **30 Hz**, or **10 Hz** on a thin uplink | The single-path relay caps ~150 pkt/s total, so 30 Hz fits 2 players with headroom; the predictor interpolates between updates, so a higher rate doesn't look smoother. **100 Hz was removed (p13h34)** — it oversubscribed the relay and remote tracking *degraded over the session* (hardware-confirmed worse than stock's 10 Hz). Go *lower*, never higher, if the overlay shows "relay starving" or "ghost drifting". |
| **Enable vehicle position smoothing** (`enablePosSmoother`) | off | **on** | The internet has jitter (LAN has ~none); the smoother hides the uneven packet arrival that would otherwise look like micro-warping. |
| AI/traffic cars | as you like | **keep low** | Every owned car is its own stream; traffic multiplies the host's upload. The 12 Hz traffic throttle helps, but fewer cars = less to lose. |

### 3. OS / network items that matter MORE over the internet
- **UDP receive buffers (Tier 1 below) are still the #1 item** — on the *Linux* side raise
  `net.core.rmem_max` (a lossy/bursty internet path makes buffer overflow *more* likely, not less).
- **Both peers on a wired connection** if at all possible; Wi-Fi adds jitter and loss that the
  predictor can only partly hide.
- **The host's UPLOAD speed is the real limit.** Check it (e.g. a speed test) — if it's ~1 Mbps,
  stay at 20–30 Hz with 1–2 cars each. The download side is rarely the problem.
- Latency itself you can't tune away — it just means remote cars are extrapolated a little further
  ahead. The stock predictor handles that; the send-rate lever handles bandwidth.

### 4. Read the overlay to tune
Turn on **Show sync stats overlay** (Options → Multiplayer). If **"Pos applied"** collapses or the
**"Ghost drift"** row reddens, your send rate is above what the link carries — drop it a step. If
**FPS** is the thing dropping, that's CPU (cut cars / AI-traffic / heavy mods), not the network. A
sustained >1s FPS hitch on a machine freezes the *remote* ghosts it's drawing (the local engine stops
applying received positions) — so trimming load is the fix, not a netcode setting.

> **Versus stock BeamMP over the internet:** stock routes through BeamMP's hosted servers (someone
> else's relay/route); this fork is a *direct* link between you and your friend. Direct is lower
> latency when the two connections are good, and you control the tuning — but if one peer has a poor
> connection there's no relay to paper over it. For a handful of friends with decent connections
> (especially over a mesh VPN), tuned as above, it should feel as good or better.

---

## Position send rate vs your FPS — the 60 Hz sweet spot

The in-game **Position send rate** (Options → Multiplayer → advanced) and your **frame rate /
monitor refresh** are two different things, and confusing them leads to over-setting the rate.

- **Sending is decoupled from FPS.** With **Physics-rate send** on (the LAN default), your car's
  position is emitted from the **physics step** (~2000 Hz internally), gated to the rate you pick.
  So it genuinely sends e.g. 100/s **even if you render at 60 FPS** — that's the whole point of the
  setting. **Vsync / monitor refresh caps your *render* FPS, not the physics step**, so it does
  **not** throttle the send.
- **Receiving/showing is capped by the receiver's FPS.** A remote car's position is *applied and
  drawn* once per **rendered frame**, so you can only see it update at your render FPS (60 Hz if
  you're vsync-locked at 60). Between packets the predictor extrapolates.

**Consequence at a steady ~60 FPS on both machines:** a 100 Hz stream delivers ~100 packets/s, but
the other machine only draws the car ~60×/s, so ~40 packets/s are superseded before they're ever
shown (latest-wins). They're not *wasted* — a fresher packet is a slightly better base for the
predictor — but the **visual** update can't exceed the receiver's FPS.

**So a higher rate buys nothing past your FPS — and past the relay's budget it actively hurts.** One
fresh packet per rendered frame is the most you can ever *show*; beyond that you only add load. That's
why the **100 Hz option was removed** and the default is **30 Hz** (see the table up top), and why the
rule is **lower, never higher** when sync degrades. The reason "higher hurts" needs one more fact: the
relay has a hard throughput ceiling.

### Why the relay caps at ~150 pkt/s — and why raising the send rate backfires

The server (and the combined host's embedded server) relays every client's position stream on **a
single thread**. `UDPServerMain` (`BeamMP-Server/src/TNetwork.cpp`) loops: `recvfrom()` one
packet → linear-scan the client list under a read-lock to find the sender → hand it to `GlobalParser`,
which **fans the packet out to every *other* client** (one `send_to` each). So every inbound packet
costs one receive + an **O(players)** locked lookup + **O(players)** sends, all serialized on that one
thread. On typical host hardware that saturates at roughly **~150 packets/sec aggregate — across *all*
players combined** (not per player), and the budget *shrinks* as players join, since each packet then
fans out to more recipients.

**It's a wall, not a dial.** ~150 isn't a number you can raise in a setting — it's how fast that single
thread runs the receive→lookup→fan-out cycle. The 16 MB UDP receive buffer (raised for LAN) only
*delays* the wall: it absorbs short bursts, but a sustained overrate grows a backlog, so applied
positions arrive **progressively staler** → the predictor extrapolates further → **drift grows over the
session** (the exact "degrades over time" measured at 100 Hz, hardware-confirmed worse than stock's 10
Hz). When the buffer finally fills, the kernel **drops** packets and remote cars freeze.

**Trade-offs of raising it:**

| Approach | Effect | Cost / risk |
|---|---|---|
| **Send *more* (raise the rate)** | Oversubscribes the thread → backlog → latency → drift → kernel drops → freezes. **Worse, not better.** | Exactly why 100 Hz was pulled. Don't reach for this. |
| **Send *less* + coalesce** *(what the fork does)* | 30 Hz default + the client-side latest-wins drain + the 12 Hz traffic throttle keep the aggregate under the wall; the predictor interpolates, so it still looks smooth. | None — this is the chosen path. |
| **O(1) client lookup** (index clients by ID; drop the per-packet linear scan + lock) | Cheaper per packet → genuinely raises the wall. | A contained server-side refactor; safe-ish. The single biggest *safe* win if a busy host ever hits the wall. |
| **Multi-thread the relay** | Parallel fan-out → more throughput. | Real concurrency risk (the per-client send mutex + client-list locking); this is what **shelved** the adaptive-coalescing relay ("blind sync-socket concurrency"). High risk on a LAN-only build. |
| **Server-side coalescing** (drop superseded positions before fan-out) | Fewer outbound sends under load. | Same shelved adaptive-relay work; revisit only if a busy host needs it. |

> **Bottom line:** the cap is a property of the single-threaded relay, and the send-rate slider is the
> *wrong* tool against it — turning it up always loses. Each machine's rate is independent (no
> negotiation; **60 / 30 / 10** are the valid values, mix freely), but the guidance is the same for all:
> **stay at 30 unless you have headroom, and go lower — never higher — if the overlay shows "relay
> starving" or "ghost drifting."** The overlay's **"Pos applied/s"** sitting at your FPS (not your send
> rate) means you've hit the *viewer's* render ceiling and more Hz can't help. If you genuinely outgrow
> ~150 pkt/s, the safe fix is the **O(1) lookup**, not more Hz.

---

## Tier 0 — the map-load CRASH is a BeamNG ENGINE mod-limit, NOT RAM or the renderer (CONFIRMED 2026-06-27)

The host's map-load crashes are a **deterministic bug in BeamNG's own engine**. The Windows
Application event log (Event ID 1000) names the faulting module **`BeamNG.drive.x64.exe`**,
exception **0xc0000005 (access violation)**, at the **identical offset `0x152a07b` on every crash**.
Process memory is only **~6 GB with ~24 GB of free commit** at every crash — so it is **NOT** out of
memory — and the identical fault address means it's a **fixed internal limit**, hit when the
**mod/resource volume during map-load** crosses a threshold ("one more mod than it can handle"). The
**stock BeamMP mod crashes identically**, so it is NOT the LAN fork. This earlier looked like a
Vulkan problem — that was a correlation (the renderer happened to be Vulkan at the time); **DX11
crashes exactly the same way**, and so does any renderer.

**Fix: reduce the mod set.** Adding `LakeFarsoeV10.zip` (a 644 MB, texture-heavy map) is the straw
that tips this rig over. Remove it, or remove a comparable amount of other mods, to stay under
BeamNG's limit. Lowering BeamNG's texture/mesh quality can buy a little headroom. **No
RAM / page-file / renderer / OS setting fixes it** — it's a base-game engine limit (worth reporting
upstream to BeamNG). Keep DX11 anyway (it's marginally more stable on AMD), but understand it is
**not** the crash fix.

> Windows perf/network tuning below (Tiers 2/4) helps the position-sync side, not this crash. To
> apply the admin-only items (registry + NIC) in one shot, run **`apply-windows-tuning.ps1`**
> (from this repo) as Administrator.

---

## Tier 1 — UDP receive buffers (the direct fix for the drift)

The launcher and server now request large UDP receive buffers in code (8 MB launcher, 16 MB
server). **But the OS can silently cap that request** — and on Linux the default cap is tiny
(~208 KB), which would undo the bump. Raise the OS cap on each machine.

### Linux (the LAN2 client, and any Linux box running the launcher or server)
The default `net.core.rmem_max` is ~212992 bytes — far below our 8 MB request, so the kernel
clamps it and the buffer still overflows. Raise it:

```bash
sudo sysctl -w net.core.rmem_max=33554432        # 32 MB cap
sudo sysctl -w net.core.rmem_default=16777216     # 16 MB default
sudo sysctl -w net.core.netdev_max_backlog=5000   # deeper NIC->kernel queue (absorbs bursts)
```
Persist across reboots — add to `/etc/sysctl.d/99-beammp.conf`:
```
net.core.rmem_max=33554432
net.core.rmem_default=16777216
net.core.netdev_max_backlog=5000
```
then `sudo sysctl --system`. **This is the single most important Linux item** — without it the
launcher's 8 MB buffer is clamped to ~208 KB and the drift fix is mostly defeated.

### Windows (the LAN1 host running game + launcher + server)
Windows honors a large `SO_RCVBUF` without a low system-wide cap, so the in-code bump generally
takes effect as-is — no sysctl equivalent needed. Nothing required here for the buffer itself.

---

## Tier 2 — CPU: keep clocks up, and don't let the game starve the relay

BeamNG is **main-thread bound** and the server's UDP relay is a **single thread**. On the host
they compete; if either gets starved or downclocked, packets get consumed too slowly and drop.

### Both OSes — never let cores downclock under load
- **Windows:** Power Options → **High performance** (or Ultimate). Optionally disable core
  parking. This stops the CPU dropping to low clocks mid-session (a common cause of *intermittent*
  stutter that looks like network drift).
- **Linux:** set the governor to performance:
  ```bash
  sudo cpupower frequency-set -g performance     # or: echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
  ```

### The host running game **and** server (the most important case here)
The relay thread and the game's main thread should not fight over the same core.
- **Windows:** run the server with raised priority / pinned affinity so the relay always gets
  scheduled. Easiest is a launch shortcut:
  ```bat
  start "BeamMP" /high /affinity 0xC "BeamMP-Server.exe"
  ```
  `/affinity 0xC` pins it to cores 2–3 (a hex bitmask — pick cores the game leans on least).
  Or in Task Manager → Details → server exe → Set priority = High, Set affinity.
  > **`--combined` hosts: do NOT use `/affinity` here.** The combined binary launches BeamNG as a
  > child that inherits the affinity, so pinning to 2–3 would pin the game too. `start-server.bat`
  > keeps `/high` and drops `/affinity` for exactly this reason — see the **Combined host** section.
- **Linux (if hosting the server on Linux):**
  ```bash
  sudo nice -n -5 ./BeamMP-Server                 # higher priority
  taskset -c 2,3 ./BeamMP-Server                  # pin to cores 2-3
  ```
- If drift only ever shows on the **host**, that's the game/server contention; the rate lever plus
  this pinning are the fix. A truly dedicated server box removes it
  entirely, but isn't necessary for 2 players once buffers + pinning are set.

---

## Tier 3 — reduce the game main thread's load (the consumer side)

The drift ultimately appears when a machine can't drain its socket fast enough. Anything that
frees the BeamNG main thread helps it keep up:
- In-game (BeamMP options): use the **Position send rate** to dial down when the overlay shows the
  relay starving.
- **Fewer AI/traffic cars on the weaker machine** — BeamNG's traffic AI is heavy and runs on the
  main thread; spawn traffic on the stronger (host) box, or keep counts low.
- **Close overlays/hooks:** RivaTuner/RTSS, OBS, Discord/Steam/GeForce overlays. They inject into
  the game (extra main-thread/GPU work, and on this rig they previously caused Vulkan crashes).
  Use the DX11 renderer, not Vulkan (AMDVLK), per earlier crash testing.

---

## Tier 4 — NIC / link (smaller wins, but free)

- **Disable interrupt moderation** and **raise RX/TX ring buffers** on the network adapter — lowers
  latency and lets the NIC absorb bursts before the kernel queue.
  - Windows: Device Manager → adapter → Advanced → "Interrupt Moderation" = Disabled; "Receive
    Buffers"/"Transmit Buffers" → max.
  - Linux: `sudo ethtool -C eth0 rx-usecs 0` (off), `sudo ethtool -G eth0 rx 4096 tx 4096`.
- **Jumbo frames: skip them.** Position packets are tiny (<<1500 B); jumbo gives nothing here and
  only complicates the path.
- Wired, not Wi-Fi, for both machines (you almost certainly already are). Same switch, ideally.
- `NetworkThrottlingIndex` (Windows multimedia network throttle) caps non-multimedia packets to
  10/ms = 10,000/s *only while audio plays* — well above our ~200/s, so it's **not** the
  bottleneck here. Disabling it (`HKLM\...\Multimedia\SystemProfile\NetworkThrottlingIndex =
  0xffffffff`) is a harmless general gaming tweak but won't move this needle.

---

## Quick checklist
- [ ] **Linux box: raise `net.core.rmem_max` to 32 MB** (most important; persist it).
- [ ] Both: CPU at performance/high-performance power plan.
- [ ] Host (game+server): pin/prioritize the server process off the game's busy cores.
- [ ] In-game: use the send-rate lever + sync overlay to confirm.
- [ ] Spawn heavy AI traffic on the host, not the weak client.
- [ ] Kill RTSS/OBS/Discord overlays; DX11 renderer.
