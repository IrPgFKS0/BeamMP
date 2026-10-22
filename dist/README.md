# BeamMP LAN fork — release downloads

**Local test candidate: `BeamMP-LAN-p13h108-windows.zip`**, mod `4.23.1-LAN p13h108`,
Windows combined host `p13h44`, for **BeamNG 0.40.1**. p13h107 (the upstream 4.23.1 merge, 0.40
compatibility) plus the raw-frame hitch diagnostics for the LAN2 stall investigation. Smoke gate
17/17 and a controlled-stall instrument check passed; p13h107 was played in a two-player session
(0 errors, both machines) but p13h108 itself has not been. No hosted release/tag exists for it.
Linux binaries are the p13h43 build (Docker is down on the build box); the Windows exe is p13h44.

| Local artifact | SHA256 |
|---|---|
| `BeamMP-LAN-p13h108-windows.zip` | `D51D96379D51CF9A3776BEEE8DC38A810D59D33CDD755EC8D0BB8CD1571A4F5D` |
| Inner `BeamMP.zip` (also workspace `dist/BeamMP-p13h108.zip`) | `528123E3FD3C1DB095F580894E6D04ECD2C2D1876677CA2D7645E1B05D71CE25` |
| Windows `BeamMP-Combined.exe` (p13h44) | `1197D8EF58D2BFCD706D9064CA6DE060709AEE8CBA8987BF785365E9F7B856CE` |

See [compatibility and verification record](../docs/lan/BEAMNG-0.40-UPGRADE.md).

**Current published release: `BeamMP-LAN-p13h106.zip`** (mod `4.22.2-LAN p13h106`, combined host exe `p13h43`, **for BeamNG 0.39.x**
(validated on 0.39.4), Windows + Linux x86-64).

Downloads moved to **[GitHub Releases](https://github.com/IrPgFKS0/BeamMP/releases)** — the zips
are no longer committed to this folder (each added ~20 MB to the repo's history forever; the
already-committed ones remain in history at their tags).

| Release | sha256 |
|---|---|
| [`BeamMP-LAN-p13h106.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h106) | `7E613F555CE46A56CDD5EE384A967659B2CEEB05EBDA7956BBBD5A140AE60B4D` |
| [`BeamMP-LAN-p13h104.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h104) (previous 0.39 build) | `E79D382A12EACF8EE68C44E5E792AD23FC55928505D0A07636B0070708A29961` |
| [`BeamMP-LAN-p13h101.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h101) | `16043A211623461DB4CCEE16AD9337174144B35DA1F2BE1A628B9D6C1BC96581` |
| [`BeamMP-LAN-p13h99.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h99) | `6C403345CF426868F1B4984D6CF559570CDCD2D6AF25A86E3014A67E680C7DF8` |
| [`BeamMP-LAN-p13h98.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h98) | `BFD01870CFA5A85163EB473C290BA5A2CF5FB01E9145CF4C8031E9C7C08A046D` |
| [`BeamMP-LAN-p13h57.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-0.38-last-good) (0.38 ROLLBACK) | `1B1673CEA703FECC5D5CEB1B594812916E15EEB03BFC8F9DE17F9DC7808B851B` |

**Mod-only drop-in over p13h104, p13h101 or p13h99** — the exe is unchanged (`p13h43`), so on any of
those only `BeamMP.zip` changes; coming from anything older, update both files. New mod `BeamMP.zip`
sha256 `C95A9E667CEAD36279124A4F553313C7C5A3FC1FE5088447A10B4A437F6A3A99`.
This build is for sessions with BeamNG's AI traffic: the host's traffic cars (and any other car the host
isn't driving) now send everything at 12 updates a second instead of streaming steering, lights and
powertrain at full rate, and traffic no longer crashes when a turret mod's missiles or bombs are in the
air (a BeamNG gap the mod now fills in during multiplayer). It also carries p13h104's Maps page in the
BeamMP menu. Packet format unchanged; mixed sessions with p13h104 keep working. Verified in a two-player
session (Windows host + Linux client) with 7 traffic cars and a missile turret firing — see the release
notes.
**Linux clients on anything older than p13h99:** the launcher could fail to find BeamNG (it searched
only the first Steam installation); p13h99 and later fix that. If you ran any p13h82–p13h85 build:
those reject every remote position packet in multiplayer (remote cars frozen) — update now.
(Superseded zips and their `lan-release-*` tags are removed as releases roll; the tags kept are
exactly the ones backing a published release -- currently `lan-release-p13h106`, `lan-release-p13h104`, `lan-release-p13h101`,
`lan-release-p13h99`, `lan-release-p13h98` and `lan-0.38-last-good` -- which is the set the AGPL
source promise needs. Every row in the table above must link a release that still exists, and the
source offer at the bottom must name a tag `git ls-remote --tags` actually shows.)

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
[BeamMP-Server](https://github.com/IrPgFKS0/BeamMP-Server)) at tag `lan-release-p13h106`
(AGPL-3.0-or-later — complete corresponding source at those tags).

> Zips live on GitHub Releases as of 2026-08-13; this README stays the checksum ledger.
