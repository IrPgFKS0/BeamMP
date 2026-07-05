#!/usr/bin/env bash
#
# Packages the BeamMP LAN client mod into BeamMP.zip.
#
# The launcher (LAN build) installs this zip into the game's
# mods/multiplayer/ folder instead of downloading it from the BeamMP backend.
# Place the resulting BeamMP.zip next to the BeamMP-Launcher executable.
#
# Run from the workspace root (the folder containing BeamMP/, BeamMP-Launcher/,
# and BeamMP-Server/).
#
# Note: the cosmetic "Beamlings" avatars live in a private BeamMP repo and are
# intentionally omitted here. They are not needed for LAN play.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MOD_DIR="$HERE/BeamMP"
OUT="$HERE/BeamMP.zip"

if [ ! -d "$MOD_DIR" ]; then
    echo "error: $MOD_DIR not found" >&2
    exit 1
fi

cd "$MOD_DIR"
rm -f "$OUT"

# These are the same paths the upstream release workflow packages (minus the
# private Beamlings avatars and a couple of docs that don't exist in this tree).
zip -r "$OUT" \
    icons lua mp_locales scripts settings ui vehicles \
    CONTRIBUTING.md CODE_OF_CONDUCT.md LICENSE README.md NOTICES.md \
    -x '*/.git/*' -x '*/.idea/*' > /dev/null

echo "Built: $OUT"
if command -v shasum > /dev/null 2>&1; then
    ( cd "$HERE" && shasum -a 256 BeamMP.zip )
fi
