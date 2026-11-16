# BeamMP LAN fork — release downloads

**Current published release: `BeamMP-LAN-p13h124.zip`** (mod `4.23.1-LAN p13h124`, combined host exe `p13h48`, **for BeamNG 0.40.5**
and 0.40.4, Windows + Linux x86-64). On BeamNG 0.39.x stay on `BeamMP-LAN-p13h106.zip`.

Downloads moved to **[GitHub Releases](https://github.com/IrPgFKS0/BeamMP/releases)** — the zips
are no longer committed to this folder (each added ~20 MB to the repo's history forever; the
already-committed ones remain in history at their tags).

| Release | sha256 |
|---|---|
| [`BeamMP-LAN-p13h124.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h124) | `BEA48757E1959394DFFCFD496ED69F37244E5D468581A9B93B0590D3DA041AC8` |
| [`BeamMP-LAN-p13h123.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h123) (previous 0.40 build) | `3F87BF116C93482047AF0AE4BB10B33B100AF59CB7C4F858131F5CA2CCB7A040` |
| [`BeamMP-LAN-p13h120.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h120) (earlier 0.40 build) | `A8C88395ABE7A3B4A6948C7A916C834E8DBB84450EAED27D12BC462B0B2F7F89` |
| [`BeamMP-LAN-p13h119.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h119) (earlier 0.40 build) | `0849B3738B78F265D250E5271F814E7FAEB0256593035F1F754A8248FB5FA3F5` |
| [`BeamMP-LAN-p13h117.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h117) (earlier 0.40 build) | `9D58A4AE5618F446A00106BC519E9ABB7636BB5DECE7B0C32DCC2AC73A600947` |
| [`BeamMP-LAN-p13h114.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h114) (earlier 0.40 build) | `4C4EE7960131EE4BC86ED137E857C1EEE47C8FB2BCCFCCE7DB23D5906ADAD8F9` |
| [`BeamMP-LAN-p13h112.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h112) (earlier 0.40 build) | `EC32695A572ABA159092004FDC1C049C1B7923F7ED5EAE6781E860609961429B` |
| [`BeamMP-LAN-p13h106.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h106) (last BeamNG 0.39 build) | `7E613F555CE46A56CDD5EE384A967659B2CEEB05EBDA7956BBBD5A140AE60B4D` |
| [`BeamMP-LAN-p13h104.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h104) (previous 0.39 build) | `E79D382A12EACF8EE68C44E5E792AD23FC55928505D0A07636B0070708A29961` |
| [`BeamMP-LAN-p13h101.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h101) | `16043A211623461DB4CCEE16AD9337174144B35DA1F2BE1A628B9D6C1BC96581` |
| [`BeamMP-LAN-p13h99.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h99) | `6C403345CF426868F1B4984D6CF559570CDCD2D6AF25A86E3014A67E680C7DF8` |
| [`BeamMP-LAN-p13h98.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-release-p13h98) | `BFD01870CFA5A85163EB473C290BA5A2CF5FB01E9145CF4C8031E9C7C08A046D` |
| [`BeamMP-LAN-p13h57.zip`](https://github.com/IrPgFKS0/BeamMP/releases/tag/lan-0.38-last-good) (0.38 ROLLBACK) | `1B1673CEA703FECC5D5CEB1B594812916E15EEB03BFC8F9DE17F9DC7808B851B` |

**Update BOTH files on every machine: `BeamMP.zip` and the exe.** p13h124 has a new launcher/host exe (p13h48,
Windows `BeamMP-Combined.exe` sha256 `273FE668F3BC2E73EE2F78F9398CE1A77F7132625E5DC06A82518633AD31BD7E`, Linux `linux/BeamMP-Combined` sha256
`133927C120A5ED3D35DDF3DDC7C868B35FC016C6F95B7F7C086EA9B5C1F15A06`), so every machine runs the matching pair (the host `windows/BeamMP-Combined.exe`, a Linux
client `linux/BeamMP-Combined`). New mod `BeamMP.zip` sha256
`C1C560AAE0D5A756455C1C0880F4B18C4820781A2ED1A0DB59E57CF5AC133B25`.
New in p13h124: client mods can keep vehicles on one PC (`MPVehicleGE.runLocalOnly`, for a weather mod's debris or
a pedestrian mod's bodies, which used to be sent to the other PCs and dropped again); the launcher's crash warning
counts only new crash reports (the Linux client warned at every start); a combined host started outside its folder
uses its own folder; a clashing name from another machine is refused instead of kicking the player who is in.
From p13h123: other players' cars spawn one per frame instead of all in one frame when you join a busy
server; their burnouts and distance no longer go into your own stats; your own car with its driver seat removed can
be driven; the BeamMP page survives the game reloading UI mods during a join; the launcher reads whole packets from
the game (a cut-short read used to corrupt large vehicle data); a Windows host sends mods in 4 MB pieces (upstream
measured ~220 -> ~4950 Mbit/s on a LAN); a shorter mod sync at join. All from open upstream BeamMP pull requests
(#273, #507, #1028, #1027, #997, #1012, #1022), checked against this fork and adapted where needed. Verified with
the 17-check smoke gate and a two-player session (Windows host, Linux client, both on these exact files, BeamNG
0.40.5). See the release notes and the [BeamNG.Earth record](../docs/lan/BEAMNG-EARTH.md). With BeamNG.Earth: never
start the Earth app while you are in a session, and keep its *Start BeamMP with BeamNG.Earth* setting off
(README-LAN, "BeamNG.Earth").
**Linux clients on anything older than p13h99:** the launcher could fail to find BeamNG (it searched
only the first Steam installation); p13h99 and later fix that. If you ran any p13h82–p13h85 build:
those reject every remote position packet in multiplayer (remote cars frozen) — update now.
(Superseded zips and their `lan-release-*` tags are removed as releases roll; the tags kept are
exactly the ones backing a published release -- currently `lan-release-p13h124`, `lan-release-p13h123`, `lan-release-p13h120`, `lan-release-p13h119`, `lan-release-p13h117`, `lan-release-p13h114`, `lan-release-p13h112`,
`lan-release-p13h106`, `lan-release-p13h104`, `lan-release-p13h101`,
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
[BeamMP-Server](https://github.com/IrPgFKS0/BeamMP-Server)) at tag `lan-release-p13h124`
(AGPL-3.0-or-later — complete corresponding source at those tags).

> Zips live on GitHub Releases as of 2026-08-13; this README stays the checksum ledger.
