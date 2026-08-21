@echo off
setlocal
REM ============================================================================
REM  Build the COMBINED host executable (BeamMP-Launcher statically embeds the
REM  dedicated server; run the output with --combined).  Portable: locates VS via
REM  vswhere and anchors paths to this script's folder -- no hardcoded paths.
REM  Just run it from a normal cmd:  build-launcher.bat
REM ============================================================================
set "ROOT=%~dp0"

REM --- find Visual Studio 2022+ with the C++ x64 toolset, via vswhere ---
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" goto :no_vswhere
set "VSPATH="
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
if not defined VSPATH goto :no_vs

call "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" >nul || goto :vcvars_fail
REM --- put the VS-bundled CMake + Ninja on PATH (harmless if you also have your own) ---
set "PATH=%VSPATH%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin;%VSPATH%\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;%PATH%"

cd /d "%ROOT%BeamMP-Launcher" || goto :no_dir
echo === CONFIGURE (combined exe, x64-windows-static) ===
cmake . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_TOOLCHAIN_FILE="%ROOT%BeamMP-Server\vcpkg\scripts\buildsystems\vcpkg.cmake" ^
  -DVCPKG_TARGET_TRIPLET=x64-windows-static ^
  -DVCPKG_APPLOCAL_DEPS=OFF || goto :build_fail
REM APPLOCAL_DEPS=OFF: the static triplet ships no DLLs, and the post-link
REM applocal.ps1 step dies on the nonexistent vcpkg_installed\...\bin dir
REM ("The system cannot find the path specified"), failing an otherwise-good link.
echo === BUILD ===
cmake --build build --parallel --config Release || goto :build_fail
echo.
echo === LAUNCHER/COMBINED BUILD OK  -^>  BeamMP-Launcher\build\BeamMP-Launcher.exe ===
echo     (rename to BeamMP-Combined.exe and run with --combined)
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
echo ERROR: BeamMP-Launcher\ not found next to this script (%ROOT%).
exit /b 1
:build_fail
echo ERROR: build failed -- see the CMake/Ninja output above.
exit /b 1
