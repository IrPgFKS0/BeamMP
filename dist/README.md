# BeamMP LAN fork — release downloads

**Current release: `BeamMP-LAN-p13h54.zip`** (mod `4.21.1-LAN p13h54`, combined host exe `p13h32`,
Windows + Linux x86-64).

| File | sha256 |
|---|---|
| `BeamMP-LAN-p13h54.zip` | `980230AEA4F92864C79376EF2E1655BD161FFB28EE252A068EB6AAE6DA89CAB9` |

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
[BeamMP-Server](https://github.com/IrPgFKS0/BeamMP-Server)) at tag `lan-release-p13h54`
(AGPL-3.0-or-later — complete corresponding source at those tags).

> Note: each release adds a ~50 MB zip to this repo's history. If that ever gets heavy,
> move future zips to GitHub Releases and keep only this README + checksums here.
