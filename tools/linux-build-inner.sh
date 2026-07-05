#!/usr/bin/env bash
# Inner container script for the Linux build -- extracted verbatim from
# build-linux-docker.sh so the host side can invoke it as a file (avoids both
# Git-Bash path mangling and host-shell quoting of the embedded script).
set -ux
export DEBIAN_FRONTEND=noninteractive
export VCPKG_FORCE_SYSTEM_BINARIES=1
export VCPKG_DEFAULT_BINARY_CACHE=/work/.vcpkg-cache
echo "Build architecture: $(uname -m)"

apt-get update -y
apt-get install -y \
  liblua5.3-0 liblua5.3-dev curl zip unzip tar cmake make git g++ ninja-build \
  pkg-config autoconf automake libtool python3 bison flex perl build-essential
git config --global --add safe.directory "*"

echo "============ BUILDING SERVER ============"
cd /work/BeamMP-Server
git submodule update --init --recursive
./vcpkg/bootstrap-vcpkg.sh
rm -rf bin-linux
cmake . -B bin-linux \
  -DCMAKE_TOOLCHAIN_FILE=./vcpkg/scripts/buildsystems/vcpkg.cmake \
  -DCMAKE_BUILD_TYPE=Release -DBeamMP-Server_ENABLE_LTO=OFF \
&& cmake --build bin-linux --parallel -t BeamMP-Server \
&& cp bin-linux/BeamMP-Server /work/dist/linux/BeamMP-Server \
&& echo "SERVER_BUILD_OK" || echo "SERVER_BUILD_FAILED"

echo "============ BUILDING LAUNCHER ============"
set +e
cd /work/BeamMP-Launcher
git submodule update --init --recursive
rm -rf bin-linux
cmake . -B bin-linux \
  -DCMAKE_TOOLCHAIN_FILE=/work/BeamMP-Server/vcpkg/scripts/buildsystems/vcpkg.cmake \
  -DCMAKE_BUILD_TYPE=Release \
&& cmake --build bin-linux --parallel \
&& cp bin-linux/BeamMP-Launcher /work/dist/linux/BeamMP-Launcher \
&& echo "LAUNCHER_BUILD_OK" || echo "LAUNCHER_BUILD_FAILED"
set -e

echo "============ ARTIFACTS ============"
ls -la /work/dist/linux/
