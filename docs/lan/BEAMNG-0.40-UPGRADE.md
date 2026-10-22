# BeamNG 0.40 / BeamMP 4.23.1 compatibility work

## Objective and baseline

Update the LAN fork from `4.22.2-LAN p13h106` to the BeamMP 4.23.1 compatibility
baseline, fix supported log findings, preserve LAN behavior, and prepare a local
package. Target game: installed BeamNG 0.40.1.0 (the launcher also retains a prior
0.40.0 session). New mod identity: `4.23.1-LAN p13h107`; existing combined host
`p13h44` fixes concurrent server TCP writes (upstream #271).

- Starting mod HEAD: `c40f5cf0` (clean).
- Original upstream baseline: `ca24814994005d17c0a62278814dad0af169d55e`.
- Target upstream tag `v4.23.1`: `d882321495ac78dc36442f915198a9e1c3ce176f`.
- Launcher/server existing submodule modifications predate this task and are retained.
- Original game/host logs and checksums: workspace
  `tools/artifacts/beamng-040-audit/prechange-logs/`.

## Strategy and design

Merge the tagged upstream release, preserving the fork-owned receive/predictor,
combined-host transport, reliable weapons, 12 Hz traffic scheduling, recovery,
settings, map switching, and LAN UI. Resolve conflicts from the fork implementation
and adopt only compatible upstream changes after reading their source. Rebuild
the two game UI overrides from installed 0.40.1 plus upstream BeamMP categories
and the existing LAN option injector. Do not adopt unrelated public-backend flows.

Classify changes as upstream FIX, compatibility EXTEND, or fork COMPENSATE in the
completion ledger below. No new wire protocol or performance-policy changes.

## Iterations and verification

1. Merge and resolve compatible Lua/UI changes. Check full UI shadow population,
   paired callers/listeners, GE-to-VE guards, duplicate definitions, and exports.
2. Reproduce and fix actionable retained-log issues. Regression guards must fail
   against pre-change source; retain third-party/game errors as evidence rather
   than attributing them to BeamMP.
3. Run Lua/JSON/JS/Vue checks, existing sandbox guards, predictor cross-check and
   focused behavioral tests. Independently review merge seams.
4. Build a local test mod, cold-stage it for the existing real-game smoke gate,
   preserve/restore settings, and verify exact tested bytes. Prepare bundle and
   checksum ledger. A real two-player run remains required for final release/tag
   approval under CLAUDE.md; local test packaging is not a published release.

Acceptance: compatible code and package, explicit evidence of checks, accurate
release notes, no unexplained loss of LAN features, and no claims of two-player
validation without an actual session.

## Progress

- Exploration: upstream target identified; all 21 merge conflicts resolved.
- Implementation: compatible upstream merge resolved; predictor and wire unchanged.
- Verification: Lua 42/42 and JSON/JSONC 93/93; compat040 5/5 (h106 fails 5),
  gameplay040 7/7 (h106 fails 6), traffic 81/81, spawn 9/9 with 68 exports,
  map shim 25/25, mapswitch 27/27 with 39 exports, predictor 84/84 math statements
  unchanged and VE exports 28/28. UI 27 syntax/SFC files, 6 behavioral groups
  (h106 fails 6), all 80 game condition functions and all 25 stock layout categories
  exact; 19 LAN items retained. Windows launcher built; partial-send concurrency
  test fails old source and passes new source.
- Runtime baseline: legacy `-tcom` crashes stock 0.40 before mods (missing
  `tech_techCore`); harness now uses game's loopback MCP, unchanged assertions.
  Baseline join aborted because configured `/levels/aj_jiza_12919_egypt/info.json`
  is unavailable; the final run used a copied config and stock Gridmap.
- Package finding: full h106 archive scan (467 entries) found 17 deflated entries
  with equal compressed/uncompressed sizes. Game `readFile('/icons/up.png')`
  returns the exact raw compressed bytes, while Python zipfile returns valid PNG.
  All eight icons compared; only up mismatches. The new packager stores entries
  that do not shrink, validates all source bytes and CRCs, checks source freshness,
  backs up the old archive, then replaces atomically. h106 fails its guard on all
  17 entries; h107 passes all 468 entries (163 stored).
- Linux rebuild: BLOCKED by Docker Desktop inference-manager startup error and
  docker-desktop WSL disk mount failure/read-only fallback. No system reset done.
  Package new Windows binaries separately; do not mislabel stale Linux artifacts.
- Publication/tags: not requested; none created.

## Change classification

| Classification | Change and rationale |
| --- | --- |
| Upstream FIX | v4.23.1 keybind migration, per-vehicle electrics cache, hydraulic smoothing, archive-name parsing, current save APIs, authoritative spawn/edit owner IDs, chat input handling. |
| Upstream FIX | Launcher #271 TCP framed-write serialization, adapted to the fork's actual concurrent TCP senders; existing combined queue already serialized. |
| Compatibility EXTEND | Rebase stock options layout/conditions onto installed 0.40.1, retain LAN injector, adapt walking cleanup to per-player unicycle IDs, recognize game minor 40 while retaining warn-only unknown versions. |
| Fork FIX | Optional direct-socket setup no longer reports expected unregistered single-player cars as errors; repeated map joins preserve the real marker callback. |
| Security FIX | Existing dialogs use literal text components to avoid compiling server text as Vue expressions; chat renders escaped text; connection commands use the existing Lua serializer. |
| Game COMPENSATE | Canonical ZIP packager avoids measured equal-size DEFLATE corruption; no image source changes. |
| Tooling COMPENSATE | Smoke automation uses the game's shipped loopback MCP because the old tech-core bridge is absent; run errors and incomplete runs cannot report success. |

Preserved: decoded-table receive and `mpPos` mailbox, predictor math, guarded GE/VE
calls, 12 Hz traffic aggregation, weapons transport, LAN routes/names/favorites/Maps,
instability recovery toggle, h106 traffic-AI shim and combined-host transport.
Not adopted: public-backend authentication/TOS routing, protected-editor restrictions,
MCP-port disabling, fork recovery deletion, or upstream changes that erase LAN settings.
Existing reverse-order velocity loops already implement the upstream correction.

## Final verification and artifacts

- Real BeamNG 0.40.1 run, 2026-10-21 14:31–14:33 Arizona time: **17/17 PASS**,
  no FAIL/MISS/SKIP. Join, spawn, AI drive, vehicle reload, direct position/input sends,
  launcher acknowledgement, socket re-registration, zero GE position sends in the
  confirmed steady-state window, and live VE modules all exercised.
- The harness restored `profilePosSync`/`logSyncStats`; preexisting direct-socket
  setting retained. Permanent ServerConfig SHA256 unchanged:
  `5FB35F3E2C02D00036620FDBA4DACFA2E582D1934B664F49D794A6C00D5F990C`.
- Full live VFS population: 467/468 archive entries match; sole difference is the
  preexisting user HUD layout override. All 17 formerly corrupt PNGs now match.
  CEF HTTP independently confirms exact packaged options layout/conditions and all
  seven BeamMP categories. The earlier h106 VFS shadow mismatch is absent after the
  final cold stage; its precise mount-timing cause was not established.
- Tested mod `BeamMP.zip` SHA256:
  `BB296BBFC33C0D49CBEB23AF78CD8182166512C1C73DFB74510C67A8BD4702B0`.
- Tested Windows combined host SHA256:
  `1197D8EF58D2BFCD706D9064CA6DE060709AEE8CBA8987BF785365E9F7B856CE`.
- Windows bundle `dist/BeamMP-LAN-p13h107-windows.zip`: 9 members, 9,212,960 bytes,
  SHA256 `6704D27FFDD2CE66045A88EB127C1663038F244A66F666938B07BB8DAEC5B6D8`.
  All members reread with CRC and compared with source before atomic replacement.
  Standalone mod copy: `dist/BeamMP-p13h107.zip` (same tested bytes).
- Fresh log population: 413 errors, all classified as third-party assets/metadata,
  stale input bindings, platform initialization or stock level references; no errors
  from BeamMP channels, native mod icons, or missing vehicle mappings. Server errors: 0.
  Launcher has only the expected game-closed message during test teardown.
- Receipts remain in workspace `tools/artifacts/beamng-040-audit/`: preserved old
  logs, runtime-log audit, source/guard checks, package verification, `smoke-h107*`,
  `h107-vfs-full.json`, and `h107-cef-http.json`.
- Local merge is resolved but uncommitted; all original uncommitted submodule state
  is preserved. No tags, pushes or hosted releases.

Remaining: real two-player receive/spawn/hydraulic validation and a rebuilt Linux
launcher. Neither is claimed by the Windows compatibility candidate. Options controls
and the alternative Chat2 app were compile/behavior checked but not interactively
exercised in-game; the default chat/player list did render in the live session.

## Follow-up multiplayer logs: LAN2 high-speed whole-view hitches

User supplied `BeamMP_logs_20261021-145103.zip` (host) and
`BeamMP_logs_20261021-215214_LAN2.zip` (client). User clarified the whole view hitches
at higher speed, including single-player and stock cars with all mods enabled.
This strongly narrows the reported symptom toward local game/rendering/global-mod
work, rather than requiring a multiplayer transport or remote-predictor failure.

Both machines loaded the exact h107 archive (`bb296bbf` prefix). Host uses h44;
Linux client still h43. Host's ten active sync-health samples show 29–32 applied
positions/s, no GE shape/vehicle-ID rejections and no watchdog heals. Only two cars
are recorded (vivace and sdd_tour); the previous seven-traffic-car mechanism is not
present. These metrics do not establish network packet loss or whole-screen pacing.

LAN2 current log has no frame-health/profiler records. All 625 error records are
within startup/catalogue/vehicle loading, ending at 143.826 s; no error records
thereafter through the live-copied tail at 364.621 s. It contains no Lua fatal or
log-cap notice. Tourbillon mesh/texture/CarPlay defects are real but do not explain
the confirmed stock-car symptom. Vulkan/GTX 1070/FSR3 are recorded; GPU frame times,
VRAM pressure and storage stalls are not. Do not assert a GPU-memory/driver cause
without measuring one. Older rotated logs belong to 0.39.4/h106 and an earlier
0.40.1 upgrade/settings session; their errors are not fresh h107 regressions.

**Confirmed diagnostic defect:** MPDebug.onUpdate accepts only `dtReal`; installed
0.40 `main.lua:998` dispatches `(dtReal, dtSim, dtRaw)`, and
`core/cameraUpdate.lua:141–142` identifies dtReal as smoothed and dtRaw as wall-clock
render delta. The hitch counter therefore does not reliably measure individual
raw spikes, contrary to its comment. The existing overlay guard also supplies
only one argument, reproducing that mistaken assumption. A read-only counterexample
using the real module plus existing guard gives h107 zero hitches / 16.67 ms worst
for a 250 ms raw spike with 16.67 ms smoothed delta; changing only the hook argument
in memory detects one hitch / 250 ms. No deployed/source diagnostic fix was made
during this log-only investigation. Existing smoothed-counter evidence must not
be used to dispute the user's observed freezes.

Next discriminating evidence: stock car on the same stock map/speed with all mods
disabled, followed by a raw-frame/GPU/VRAM capture if it persists. A future diagnostic
fix should use dtRaw, retain interval maxima rather than only the last one-second
sample, and test distinct raw/smoothed inputs. Do not change predictor/send rates
based on these local-view symptoms.

Archive manifests, complete populations, historical comparison and counterexample
receipts: workspace `tools/artifacts/mp-session-20261021/`. No source/game settings
or release archives changed during this investigation (this record is documentation).

## h108 iteration: raw-frame hitch capture (in progress)

User requested the counter correction, enough detail to diagnose high-speed LAN2
stalls, a hotfix bump and a test package. Target: `4.23.1-LAN p13h108`, unchanged
Windows h44 / existing Linux h43 launchers. This is a FIX to fork instrumentation
and an EXTEND of its existing optional capture; no predictor/transport changes.

Design: consume the third onUpdate argument (dtRaw) for frame/window accounting;
retain all-frame counts at 25/50/100/250 ms and full-interval maxima. Label invalid
or fallback clock use rather than silently treating smoothed time as raw. Compare
with the high-resolution wall clock when available. Keep logging default-off under
logSyncStats, preserve single-player support, reset disabled-time accounting, and
flush partial summaries before saveLogs or capture shutdown. Frame totals survive
send-rate adjustments.

Reuse the game's read-only performanceSpatialSnapshot capture for available
CPU/GPU/wait, frame phases and streaming context; add local vehicle speed/model,
session and memory context. Detailed hitch records have a configurable rate limit,
while every qualifying frame is counted and coalesced detail counts are explicit.
Snapshot reads are confined to detailed records, never healthy per-frame updates;
missing optional metrics remain labelled unavailable. Do not enable native profilers,
change graphics settings, submit telemetry, or claim these metrics identify a cause
without runtime evidence.

Verification: extend the existing real-module overlay guard with distinct smoothed,
simulation and raw inputs, full-interval retention, burst/coalescing, toggle/flush,
missing API and invalid-clock cases. Run against exact h107 archive as a negative
control. Parse changed Lua/JSON, independently review, build once, run the existing
real-game smoke gate plus live diagnostic checks, then verify the entire archive and
record exact tested bytes. Preserve the already-resolved uncommitted upstream merge.

### h108 completion (2026-10-22, second session)

The Codex session ended on credits before building. Picked up with the merge still uncommitted; reviewed
and committed it first (merge 9c16c1db, parents c40f5cf0 + d8823214; launcher p13h44 = 89dfe99), then h108:

- Review of the h108 diff: dtRaw consumption, wall-clock cross-check with labelled fallbacks, 25/50/100/250 ms
  buckets for every frame, 15-s interval maxima, rate-limited detail records with performanceSpatialSnapshot
  context (the API and its `capture(level, fps, frameMs, activeGpu, options)` signature confirmed in installed
  0.40.1), /savelogs flush into mp_state.txt with explicit write/close error handling. overlay_guard.py 56/56 on the
  tree; the exact h107 archive fails 14 raw-clock checks (negative control).
- Build 84435704 (package_mod.py, 468 entries) deployed cold; smoke gate 17/17 on 0.40.1; the real game logged the
  frame session, 6 summaries and 34 detail records with zero clock fallbacks and zero context warnings; the first
  load frame measured dtRaw 1000 ms against dtReal 266 ms -- the smoothing gap, live.
- Live instrument check (tools/mp-smoketest/hitch_stall_check.py against a --keep-running session): a controlled
  250 ms GE busy-loop was recorded as a 268 ms raw frame with dtReal 18 ms, h250 = 1, source dtRaw. The first run
  exposed a design gap: a 43 ms frame had taken the one-second detail slot and the stall's own record was
  coalesced, so the interval's worst frame had timing but no context. Reproduced deterministically
  (--prime-ms 40: FAIL 2/14 on the pre-fix build).
- Change (fork FIX of its own instrument): a frame that sets a new interval maximum always emits its detail
  record (`newIntervalMax = true`), bypassing the rate limit; equal or smaller frames inside the window stay
  coalesced. Cost: at most one extra record per interval start in a sustained-hitch stream. Guard updated with
  the deterministic counts (R5: the 750 ms new maximum is recorded; R10: 36 details / 964 coalesced over 1000
  sustained 30 fps frames, was 34 / 966; R11: 100/200/300 ms all recorded under a 0.5 s spacing) -- 58/58 on the
  tree, the pre-fix build fails R5/R10/R11.
- Build 75A23A93 (bypass only): gate 17/17 (42 detail records, 10 flagged as new maxima, 0 clock fallbacks). The live
  positive control then showed a retention gap: `getFrameDiagnosticsText` kept only the LATEST detail, and at the
  test machine's 30 fps a 33 ms frame qualifies every second, so the stall a /savelogs is taken for is displaced
  within a second. Change: the snapshot also keeps the session's worst detailed frame (`mpFrameHitchWorst`,
  reset per logging session); guard R12 extended (59 checks; the 75A23A93 build fails the two R12 checks).
- Build AB168481: gate 17/17 (101 detail records, 24 flagged as new maxima, 0 clock fallbacks); live check 16/16, BUT the
  retained worst was the 1000 ms level-load frame (dtRaw clamps there; no player vehicle yet), not the 283 ms driving
  stall, whose record WAS in the engine log with its context (74 km/h, dtReal 34 ms vs dtRaw 284 ms). A LAN2 /savelogs
  after a join would have carried the load frame as its worst. First change (build 52725035): also keep the worst
  detailed frame seen WITH a player vehicle. Gate 17/17, live check 17/18: the in-vehicle worst was the vehicle's own
  1000 ms SPAWN frame, present with `speedKph` 3912 (the vehicle is created at the origin and placed: a teleport
  artifact), and the gate's reload frame is 1000 ms with the vehicle at speed 0 -- a vehicle-presence or speed rule
  cannot separate load frames from driving hitches. Final change: the snapshot keeps, for each of the last 8
  intervals (two minutes), the exact emitted interval summary with the interval's worst detail record
  (`mpFrameInterval`, oldest first; the interval's worst frame >= threshold always has a record because new maxima
  bypass the rate limit; intervals without one carry `worstDetail: null`). 'Reproduce, then /savelogs' lands the
  driving hitch in one of them with its context whatever else the session loaded. Guard R12 extended (63 checks;
  52725035 fails the 4 ring checks, AB168481 and earlier fail more); hitch_stall_check.py identifies the stall by
  frame (summary.worstFrame.sessionSeconds == last ring entry's worstDetail.sessionSeconds) and requires a plausible
  vehicle speed on it.
- Final build 528123E3 (468 entries) deployed cold; gate and live positive control results: release notes.
