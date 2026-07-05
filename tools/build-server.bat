@echo off
setlocal
REM ============================================================================
REM  Build the standalone dedicated server (BeamMP-Server.exe). Only needed if you
REM  run a separate server machine -- the combined exe (build-launcher.bat) already
REM  embeds the server. Portable: locates VS via vswhere, paths anchored to this
REM  script's folder. Just run it from a normal cmd:  build-server.bat
REM ============================================================================
set "ROOT=%~dp0"

REM --- find Visual Studio 2022+ with the C++ x64 toolset, via vswhere ---
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" goto :no_vswhere
set "VSPATH="
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
if not defined VSPATH goto :no_vs

call "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" >nul || goto :vcvars_fail
set "PATH=%VSPATH%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin;%VSPATH%\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;%PATH%"

cd /d "%ROOT%BeamMP-Server" || goto :no_dir
echo === CONFIGURE (server, LTO on, x64-windows-static) ===
cmake . -B bin -G Ninja -DCMAKE_BUILD_TYPE=Release -DBeamMP-Server_ENABLE_LTO=ON ^
  -DVCPKG_TARGET_TRIPLET=x64-windows-static || goto :build_fail
echo === BUILD ===
cmake --build bin --parallel -t BeamMP-Server --config Release || goto :build_fail
echo.
echo === SERVER BUILD OK  -^>  BeamMP-Server\bin\BeamMP-Server.exe ===
exit /b 0

:no_vswhere
echo ERROR: vswhere not found at "%VSWHERE%".
echo Install Visual Studio 2022 with the "Desktop development with C++" workload.
exit /b 1
:no_vs
echo ERROR: no Visual Studio with the C++ x64 toolset (VC.Tools.x86.x64) was found.
exit /b 1
:vcvars_fail
echo ERROR: vcvars64.bat failed under "%VSPATH%".
exit /b 1
:no_dir
echo ERROR: BeamMP-Server\ not found next to this script (%ROOT%).
exit /b 1
:build_fail
echo ERROR: build failed -- see the CMake/Ninja output above.
exit /b 1
