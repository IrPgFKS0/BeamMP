# BeamMP LAN fork — release downloads

**Current release: `BeamMP-LAN-p13h98.zip`** (mod `4.22.2-LAN p13h98`, combined host exe `p13h42`, **for BeamNG 0.39.x**
(validated on 0.39.4), Windows + Linux x86-64).

Downloads moved to **[GitHub Releases](https://github.com/IrPgFKS0/BeamMP/releases)** — the zips
are no longer committed to this folder (each added ~20 MB to the repo's history forever; the
already-committed ones remain in history at their tags).

| Release | sha256 |
|---|---|
| [`BeamMP-LAN-p13h98.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h98) | `BFD01870CFA5A85163EB473C290BA5A2CF5FB01E9145CF4C8031E9C7C08A046D` |
| [`BeamMP-LAN-p13h96.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h96) (previous 0.39 build) | `629688AE7BE135ECD06BF75B872A02E53E422E04630A4983DC3082F6F15D3184` |
| [`BeamMP-LAN-p13h57.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-0.38-last-good) (0.38 ROLLBACK) | `1B1673CEA703FECC5D5CEB1B594812916E15EEB03BFC8F9DE17F9DC7808B851B` |

**Update BOTH files** — the exe changed (`p13h41` → `p13h42`). New mod `BeamMP.zip` sha256
`8D79DFA0AFF6648DD64837966810ABA95BA05F9215D476C5391564924291B0A8`.
This build removes the last big allocator in the position path: the predictor that smooths and
extrapolates every *other* player's car was building ~2.8 KB of garbage per frame per remote car,
a cost that grew with how many people were in the session. Measured on both machines in a
two-player session: 2830 → 588 and 710 bytes per frame, which is at or below what the packet
decode alone costs — so the predictor's own share is gone. The exe changes only shutdown
behaviour for the *standalone* Linux server (terminal restored and streams flushed before exit);
the combined host was never affected. If you ran any p13h82–p13h85 build: those reject every
remote position packet in multiplayer (remote cars frozen) — update now.
(Superseded zips and their `lan-release-*` tags are removed as releases roll; the only tags kept
are the three backing published releases -- `lan-release-p13h98`, `lan-release-p13h96` and
`lan-0.38-last-good` -- which is exactly the set the AGPL source promise needs.)

The zip contains:

```
BeamMP.zip                  the client mod (put next to the launcher exe on EVERY machine)
windows/BeamMP-Combined.exe one-process host: dedicated server + your own game bridge (--combined)
windows/BeamMP-Server.exe   plain dedicated server
windows/start-server.bat    host convenience launcher (+ pin-cores.ps1)
linux/BeamMP-Combined       same, Linux x86-64
linux/BeamMP-Server
RELEASE-NOTES.md            what's in this build (also in ../docs/lan/)
README-LAN.md               full setup / usage / profiling guide
LAN-TUNING.md               network + OS tuning, send-rate guidance
CachyOS_Install_LAVD.md     Linux client install + scheduler tuning
```

Quick start (host): unzip, run `windows/BeamMP-Combined.exe --combined` (or `start-server.bat`),
put `BeamMP.zip` next to the exe; players Direct-Connect to your IP on port `30814`.
Everyone in a session should run the matching `BeamMP.zip` **and** matching exe build.

Binaries are built from the `lan` branches of this repo and the companion repos
([BeamMP-Launcher](https://github.com/IrPgFKS0/BeamMP-Launcher),
[BeamMP-Server](https://github.com/IrPgFKS0/BeamMP-Server)) at tag `lan-release-p13h98`
(AGPL-3.0-or-later — complete corresponding source at those tags).

> Zips live on GitHub Releases as of 2026-08-13; this README stays the checksum ledger.
