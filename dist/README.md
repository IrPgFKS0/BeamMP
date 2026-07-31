# BeamMP LAN fork — release downloads

**Current release: `BeamMP-LAN-p13h67.zip`** (mod `4.22.0-LAN p13h67`, combined host exe `p13h35`, **for BeamNG 0.39**,
Windows + Linux x86-64).

| File | sha256 |
|---|---|
| `BeamMP-LAN-p13h67.zip` | `A5F62FC672E85B2AB9E9F3202BA7FDE59760E59C6AA8F12F5B0B8DC659D65E34` |
| `BeamMP-LAN-p13h61.zip` (previous 0.39 build) | `35899644C593C619B06250B1EB1A2C2AC3E6EDBA11138919D9FC0ED673E6D08C` |
| `BeamMP-LAN-p13h57.zip` (0.38 ROLLBACK — tag `lan-0.38-last-good`) | `1B1673CEA703FECC5D5CEB1B594812916E15EEB03BFC8F9DE17F9DC7808B851B` |

The exes are **identical to p13h61's** (`p13h35`) — p13h62-67 are mod-only. An existing host can
drop in just the new `BeamMP.zip`. (p13h65/p13h66 were superseded same-day — their zips were
removed from this folder; the `lan-release-p13h65`/`-p13h66` tags remain for source reference.)

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
[BeamMP-Server](https://github.com/IrPgFKS0/BeamMP-Server)) at tag `lan-release-p13h67`
(AGPL-3.0-or-later — complete corresponding source at those tags).

> Note: each release adds a ~50 MB zip to this repo's history. If that ever gets heavy,
> move future zips to GitHub Releases and keep only this README + checksums here.
