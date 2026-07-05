# LAN fork — build & host scripts

These are the scripts the fork's docs ([`../docs/lan/`](../docs/lan/)) refer to. They are
**workspace-level**: the build scripts orchestrate across all three repos, so they expect this
checkout layout, with the scripts copied to the **workspace root** (they anchor paths to their
own folder via `%~dp0`):

```
<workspace>\
├─ BeamMP\                 this repo, branch lan   (the mod; these scripts live in its tools\)
├─ BeamMP-Launcher\        branch lan              (combined host / launcher)
├─ BeamMP-Server\          branch lan              (dedicated server; vcpkg submodule used by BOTH builds)
├─ build-server.bat        <- copy from BeamMP\tools\
├─ build-launcher.bat      <- copy from BeamMP\tools\
├─ devenv.bat              <- copy from BeamMP\tools\
└─ ...
```

```
git clone -b lan https://github.com/IrPgFKS0/BeamMP.git
git clone -b lan --recurse-submodules https://github.com/IrPgFKS0/BeamMP-Launcher.git
git clone -b lan --recurse-submodules https://github.com/IrPgFKS0/BeamMP-Server.git
copy BeamMP\tools\*.bat . && copy BeamMP\tools\*.sh . && copy BeamMP\tools\*.ps1 .
```

## The scripts

| Script | What it does |
|---|---|
| `build-server.bat` | Builds the standalone dedicated server (`BeamMP-Server\bin\BeamMP-Server.exe`). Windows: needs VS 2022 with the C++ x64 workload (found via vswhere); static vcpkg triplet. |
| `build-launcher.bat` | Builds the **combined** exe (`BeamMP-Launcher\build\BeamMP-Launcher.exe` — rename to `BeamMP-Combined.exe`, run with `--combined`). Statically embeds the server; uses `BeamMP-Server\vcpkg`. |
| `devenv.bat` | Wrapper that sets up the MSVC env + VS-bundled cmake/ninja and runs its arguments — for ad-hoc builds outside the two scripts above. |
| `build-linux-docker.sh` | Builds the Linux server + combined binaries in an `ubuntu:24.04` container → `dist/linux/`. First run compiles vcpkg deps (slow); reuses `./.vcpkg-cache` after. |
| `linux-build-inner.sh` | The container-side half of the Linux build. On Windows hosts, invoke it directly from PowerShell — `docker run --rm -v "<workspace>:/work" -w /work ubuntu:24.04 bash /work/linux-build-inner.sh` — because Git Bash mangles the `-w /work` container paths. |
| `package_mod.sh` | Reference packer for `BeamMP.zip` (needs `zip`; on Windows use the .NET packer snippet in the docs instead). |
| `apply-windows-tuning.ps1` | Optional Windows host network/OS tuning (see `docs/lan/LAN-TUNING.md`). |
| `host/` | Drop-in **hosting** scripts (`start-server.bat`, `pin-cores.ps1` + their README) — these go next to `BeamMP-Combined.exe` in your *server* folder, not the workspace. Also shipped inside the release zip (`../dist/`). |

Prebuilt binaries + the mod zip are in [`../dist/`](../dist/) — you only need the build
scripts if you're changing the C++ or want to reproduce the binaries from source
(tag `lan-release-p13h51` = the shipped build).
