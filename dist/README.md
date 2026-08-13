# BeamMP LAN fork — release downloads

**Current release: `BeamMP-LAN-p13h88.zip`** (mod `4.22.1-LAN p13h88`, combined host exe `p13h37`, **for BeamNG 0.39.x**
(validated on 0.39.4), Windows + Linux x86-64).

Downloads moved to **[GitHub Releases](https://github.com/IrPgFKS0/BeamMP/releases)** — the zips
are no longer committed to this folder (each added ~20 MB to the repo's history forever; the
already-committed ones remain in history at their tags).

| Release | sha256 |
|---|---|
| [`BeamMP-LAN-p13h88.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h88) | `EF54553D06D804EB1B9039A6892F5C2A54056573EAE2A8EE6854FFD27FDE0FDD` |
| [`BeamMP-LAN-p13h86.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h86) (previous 0.39 build) | `E3FFFCC6ED3B934C19358A0D66004787C1BD458596E6E7E5D827CABD28C6C85D` |
| [`BeamMP-LAN-p13h57.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-0.38-last-good) (0.38 ROLLBACK) | `1B1673CEA703FECC5D5CEB1B594812916E15EEB03BFC8F9DE17F9DC7808B851B` |

**The exe CHANGED in this release** (`p13h36` → `p13h37`): update `BeamMP.zip` **and** the
`BeamMP-Combined` executable on every machine. p13h88's mod sha256 is
`0696F92769584C6C52EC58B328CE4627CACC20A96404F0F64347257AE353C284`.
If you ran any p13h82–p13h85 build: those reject every remote position packet in multiplayer
(remote cars frozen) — update now. (Superseded zips and their `lan-release-*` tags were removed 2026-08-13; the only tags kept are
the three backing published releases -- `lan-release-p13h86`, `lan-release-p13h80` and
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
[BeamMP-Server](https://github.com/IrPgFKS0/BeamMP-Server)) at tag `lan-release-p13h88`
(AGPL-3.0-or-later — complete corresponding source at those tags).

> Zips live on GitHub Releases as of 2026-08-13; this README stays the checksum ledger.
