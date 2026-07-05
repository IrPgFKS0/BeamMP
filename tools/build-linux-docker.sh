#!/usr/bin/env bash
#
# Builds the BeamMP LAN fork (server + launcher) for Linux x86_64 inside an
# ubuntu:24.04 container, using the LOCAL (modified) sources in this workspace.
# Artifacts land in ./dist/linux/.
#
# Requirements: Docker. The container needs network access (git submodules +
# vcpkg dependency builds). The first run is slow because vcpkg compiles boost,
# openssl, lua, etc. from source; subsequent runs reuse ./.vcpkg-cache.
#
# Usage:  ./build-linux-docker.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="ubuntu:24.04"

# Architecture of the produced binaries == the container platform. By default we
# build natively (fast). On an Apple-Silicon Mac that means ARM64 binaries, which
# will NOT run on an x86_64 Linux host. To produce x86_64 binaries set:
#   TARGET_PLATFORM=linux/amd64 ./build-linux-docker.sh
# (this uses QEMU emulation under Docker Desktop and is much slower).
PLATFORM_ARG=()
if [ -n "${TARGET_PLATFORM:-}" ]; then
    PLATFORM_ARG=(--platform "$TARGET_PLATFORM")
fi

# Public images need no credentials; avoid a hanging "credsStore" helper by
# pointing Docker at an empty config. (Does not touch your ~/.docker/config.json.)
export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/dkrcfg}"
mkdir -p "$DOCKER_CONFIG"
[ -f "$DOCKER_CONFIG/config.json" ] || printf '{}' > "$DOCKER_CONFIG/config.json"

# Using an empty DOCKER_CONFIG drops the saved context, so resolve the socket
# explicitly. Docker Desktop on macOS listens on ~/.docker/run/docker.sock.
if [ -z "${DOCKER_HOST:-}" ] && [ ! -S /var/run/docker.sock ] && [ -S "$HOME/.docker/run/docker.sock" ]; then
    export DOCKER_HOST="unix://$HOME/.docker/run/docker.sock"
fi

mkdir -p "$HERE/dist/linux" "$HERE/.vcpkg-cache"

docker run --rm "${PLATFORM_ARG[@]}" -v "$HERE":/work -w /work "$IMAGE" bash -uxc '
  set -u
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
  # Use a Linux-only build dir (bin-linux) so we never reuse a Windows CMake cache
  # left in ./bin by a host-side build -- that cache pins C:\ paths and the Windows
  # ninja.exe, which makes the container build fail with a cache/source mismatch.
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
  # The launcher is now the COMBINED binary (always embeds the server) and its vcpkg.json has a
  # builtin-baseline + an "embed-server" feature (boost/lua/sol2/fmt/libzip/rapidjson/doctest). So
  # build in vcpkg MANIFEST mode: the launcher CMakeLists requests the embed-server feature
  # (VCPKG_MANIFEST_FEATURES, before project()), and the overrides/baseline pin the SAME dep
  # versions the server lib was built against (ABI match for the static link). The old classic
  # /root install + -DVCPKG_MANIFEST_MODE=OFF are gone; manifest mode installs everything (base +
  # feature) into bin-linux/vcpkg_installed for the default x64-linux triplet.
  rm -rf bin-linux
  cmake . -B bin-linux \
    -DCMAKE_TOOLCHAIN_FILE=/work/BeamMP-Server/vcpkg/scripts/buildsystems/vcpkg.cmake \
    -DCMAKE_BUILD_TYPE=Release \
  && cmake --build bin-linux --parallel \
  && cp bin-linux/BeamMP-Launcher /work/dist/linux/BeamMP-Launcher \
  && echo "LAUNCHER_BUILD_OK" || echo "LAUNCHER_BUILD_FAILED"
  set -e

  echo "============ ARTIFACTS ============"
  ls -la /work/dist/linux/ || true
'
