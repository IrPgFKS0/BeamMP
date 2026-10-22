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
