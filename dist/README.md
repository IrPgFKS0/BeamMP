# BeamMP LAN fork — release downloads

**Current published release: `BeamMP-LAN-p13h112.zip`** (mod `4.23.1-LAN p13h112`, combined host exe `p13h46`, **for BeamNG 0.40.3**,
Windows + Linux x86-64). On BeamNG 0.39.x stay on `BeamMP-LAN-p13h106.zip`.

Downloads moved to **[GitHub Releases](https://github.com/IrPgFKS0/BeamMP/releases)** — the zips
are no longer committed to this folder (each added ~20 MB to the repo's history forever; the
already-committed ones remain in history at their tags).

| Release | sha256 |
|---|---|
| [`BeamMP-LAN-p13h112.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h112) | `EC32695A572ABA159092004FDC1C049C1B7923F7ED5EAE6781E860609961429B` |
| [`BeamMP-LAN-p13h106.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h106) (last BeamNG 0.39 build) | `7E613F555CE46A56CDD5EE384A967659B2CEEB05EBDA7956BBBD5A140AE60B4D` |
| [`BeamMP-LAN-p13h104.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h104) (previous 0.39 build) | `E79D382A12EACF8EE68C44E5E792AD23FC55928505D0A07636B0070708A29961` |
| [`BeamMP-LAN-p13h101.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h101) | `16043A211623461DB4CCEE16AD9337174144B35DA1F2BE1A628B9D6C1BC96581` |
| [`BeamMP-LAN-p13h99.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h99) | `6C403345CF426868F1B4984D6CF559570CDCD2D6AF25A86E3014A67E680C7DF8` |
| [`BeamMP-LAN-p13h98.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h98) | `BFD01870CFA5A85163EB473C290BA5A2CF5FB01E9145CF4C8031E9C7C08A046D` |
| [`BeamMP-LAN-p13h57.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-0.38-last-good) (0.38 ROLLBACK) | `1B1673CEA703FECC5D5CEB1B594812916E15EEB03BFC8F9DE17F9DC7808B851B` |

**Update both files.** This is the first release for BeamNG 0.40: `BeamMP.zip` and the launcher/host exe both
changed since p13h106, so every machine runs the matching pair (the host `windows/BeamMP-Combined.exe`, a Linux
client `linux/BeamMP-Combined`). New mod `BeamMP.zip` sha256
`5C4B65A08A073B5986BED8D54BA7BAE888B9F48BED397A29AD6F8008532376B3`, Windows `BeamMP-Combined.exe` sha256
`3FB03432A0EBE893C326D4D795695FC4522292157CDB7D045B26D86642ADBD2F`.
It carries BeamNG 0.40.3 compatibility and upstream BeamMP 4.23.1 with every LAN feature kept, BeamNG.Earth 1.6.0's
own multiplayer support (dents between players on BeamMP's own snapshot code, the host's real address for Earth's
plugin, cars Earth hides left alone, your own Earth mod back after a session), late joiners seeing edited cars, and
the map switcher's icon. Verified with the 17-check smoke gate and a two-player BeamNG.Earth session (Windows host,
Linux client) on these exact files -- see the release notes and the
[BeamNG.Earth record](../docs/lan/BEAMNG-EARTH.md). Known with Earth: the host can freeze for 10-20 s at a time
while another player's car is a few kilometres away (BeamNG's collision rebuild, which Earth requests).
**Linux clients on anything older than p13h99:** the launcher could fail to find BeamNG (it searched
only the first Steam installation); p13h99 and later fix that. If you ran any p13h82–p13h85 build:
those reject every remote position packet in multiplayer (remote cars frozen) — update now.
(Superseded zips and their `lan-release-*` tags are removed as releases roll; the tags kept are
exactly the ones backing a published release -- currently `lan-release-p13h112`, `lan-release-p13h106`, `lan-release-p13h104`,
`lan-release-p13h101`,
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
[BeamMP-Server](https://github.com/IrPgFKS0/BeamMP-Server)) at tag `lan-release-p13h112`
(AGPL-3.0-or-later — complete corresponding source at those tags).

> Zips live on GitHub Releases as of 2026-08-13; this README stays the checksum ledger.
