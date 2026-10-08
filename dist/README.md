# BeamMP LAN fork — release downloads

**Current release: `BeamMP-LAN-p13h104.zip`** (mod `4.22.2-LAN p13h104`, combined host exe `p13h43`, **for BeamNG 0.39.x**
(validated on 0.39.4), Windows + Linux x86-64).

Downloads moved to **[GitHub Releases](https://github.com/IrPgFKS0/BeamMP/releases)** — the zips
are no longer committed to this folder (each added ~20 MB to the repo's history forever; the
already-committed ones remain in history at their tags).

| Release | sha256 |
|---|---|
| [`BeamMP-LAN-p13h104.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h104) | `E79D382A12EACF8EE68C44E5E792AD23FC55928505D0A07636B0070708A29961` |
| [`BeamMP-LAN-p13h101.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h101) (previous 0.39 build) | `16043A211623461DB4CCEE16AD9337174144B35DA1F2BE1A628B9D6C1BC96581` |
| [`BeamMP-LAN-p13h99.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h99) | `6C403345CF426868F1B4984D6CF559570CDCD2D6AF25A86E3014A67E680C7DF8` |
| [`BeamMP-LAN-p13h98.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h98) | `BFD01870CFA5A85163EB473C290BA5A2CF5FB01E9145CF4C8031E9C7C08A046D` |
| [`BeamMP-LAN-p13h57.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-0.38-last-good) (0.38 ROLLBACK) | `1B1673CEA703FECC5D5CEB1B594812916E15EEB03BFC8F9DE17F9DC7808B851B` |

**Mod-only drop-in over p13h101 or p13h99** — the exe is unchanged (`p13h43`), so on either of
those only `BeamMP.zip` changes; coming from anything older, update both files. New mod `BeamMP.zip`
sha256 `8D40B9E4653071309EB45F03A99E9F4115F265470B515D50DE789DAF07662F40`.
This build gives the seamless map switch a proper page in the BeamMP menu (pause menu → BeamMP →
Maps, the menu sidebar while in a session, or `/maps` in chat): every loadable map with previews,
the current one marked, search, a confirmation, and live status through the switch — including a
clear message when the server refuses (only the host can switch) or the load fails. It also carries
the sync overlay's new frame-hitch row (longest frame, frames ≥ 50 ms) and a fix to the overlay's
per-second bookkeeping after a stall. Wire protocol unchanged; mixed sessions with p13h101/p13h99
keep working. Verified in two two-player sessions (Windows host + Linux client), including a live
LakeFaroe → Salada switch from the page; p13h104 fixes the one defect those sessions found (the page
bounced back to the server list when first opened from the pause menu or chat) — see the release notes.
**Linux clients on anything older than p13h99:** the launcher could fail to find BeamNG (it searched
only the first Steam installation); p13h99 and later fix that. If you ran any p13h82–p13h85 build:
those reject every remote position packet in multiplayer (remote cars frozen) — update now.
(Superseded zips and their `lan-release-*` tags are removed as releases roll; the tags kept are
exactly the ones backing a published release -- currently `lan-release-p13h104`, `lan-release-p13h101`,
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
[BeamMP-Server](https://github.com/IrPgFKS0/BeamMP-Server)) at tag `lan-release-p13h104`
(AGPL-3.0-or-later — complete corresponding source at those tags).

> Zips live on GitHub Releases as of 2026-08-13; this README stays the checksum ledger.
