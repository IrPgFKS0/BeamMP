#!/usr/bin/env bash
# Package BeamMP.zip using the canonical Python 3 packer (no zip CLI needed).
# Works at the workspace root or directly from the mod checkout's tools folder.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HERE/tools/package_mod.py" ]; then
    PACKER="$HERE/tools/package_mod.py"
elif [ -f "$HERE/package_mod.py" ]; then
    PACKER="$HERE/package_mod.py"
else
    PACKER="$HERE/BeamMP/tools/package_mod.py"
fi
if [ ! -f "$PACKER" ]; then
    echo "error: canonical package_mod.py not found beside this script or in BeamMP/tools" >&2
    exit 1
fi
if [ -z "${PYTHON:-}" ]; then
    if command -v python3 >/dev/null 2>&1; then
        PYTHON=python3
    else
        PYTHON=python
    fi
fi
exec "$PYTHON" "$PACKER" "$@"
