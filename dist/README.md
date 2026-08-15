# BeamMP LAN fork — release downloads

**Current release: `BeamMP-LAN-p13h89.zip`** (mod `4.22.1-LAN p13h89`, combined host exe `p13h37`, **for BeamNG 0.39.x**
(validated on 0.39.4), Windows + Linux x86-64).

Downloads moved to **[GitHub Releases](https://github.com/IrPgFKS0/BeamMP/releases)** — the zips
are no longer committed to this folder (each added ~20 MB to the repo's history forever; the
already-committed ones remain in history at their tags).

| Release | sha256 |
|---|---|
| [`BeamMP-LAN-p13h89.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h89) | `7717A76A6E7665E1C10B0AEC291EDBD2B8F40BF1233124CBCC8CD0D98C07235A` |
| [`BeamMP-LAN-p13h88.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h88) (previous 0.39 build) | `EF54553D06D804EB1B9039A6892F5C2A54056573EAE2A8EE6854FFD27FDE0FDD` |
| [`BeamMP-LAN-p13h57.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-0.38-last-good) (0.38 ROLLBACK) | `1B1673CEA703FECC5D5CEB1B594812916E15EEB03BFC8F9DE17F9DC7808B851B` |

**Mod-only update from p13h88** (the exe is unchanged at `p13h37`): an existing p13h88 host can
drop in just the new `BeamMP.zip` (sha256
`2B03F4A01B36CBF58DBD207CC36D77E68E824D8D404AFECA078B131DD0F1C9A5`). Coming from p13h86 or
earlier, update **both** files. If you ran any p13h82–p13h85 build: those reject every remote
position packet in multiplayer (remote cars frozen) — update now. (Superseded zips and their `lan-release-*` tags were removed 2026-08-13; the only tags kept are
the three backing published releases -- `lan-release-p13h89`, `lan-release-p13h88` and
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
[BeamMP-Server](https://github.com/IrPgFKS0/BeamMP-Server)) at tag `lan-release-p13h89`
(AGPL-3.0-or-later — complete corresponding source at those tags).

> Zips live on GitHub Releases as of 2026-08-13; this README stays the checksum ledger.
