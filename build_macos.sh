#!/bin/bash
# =============================================================================
# Build kroko-onnx Python wheel for macOS (native build, no Docker).
#
# Same shape as build_windows.sh: take --variant pro|free|both, produce
# one wheel per variant into release_artifacts/macos/ with a distinct
# build tag (1pro / 1free) so both can sit side-by-side.
#
# Unlike Windows, there's no installer here — macOS users install the
# wheel via pip directly. (No NSIS-equivalent ship pattern for the
# kroko-onnx websocket-server binary on macOS yet.)
#
# Usage:
#   ./build_macos.sh                        # both variants
#   ./build_macos.sh --variant pro          # just pro
#   ./build_macos.sh --variant free         # just free
# =============================================================================
set -euo pipefail

VARIANTS_RAW="both"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --variant) VARIANTS_RAW="$2"; shift 2 ;;
        --variant=*) VARIANTS_RAW="${1#--variant=}"; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

case "$VARIANTS_RAW" in
    pro)  VARIANTS=(pro) ;;
    free) VARIANTS=(free) ;;
    both) VARIANTS=(pro free) ;;
    *) echo "ERROR: --variant must be pro|free|both (got '$VARIANTS_RAW')" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

VERSION=$(grep -E 'set\(SHERPA_ONNX_VERSION' CMakeLists.txt | head -1 \
    | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/')
[ -n "$VERSION" ] || { echo "ERROR: could not parse version" >&2; exit 1; }

echo "=== Kroko ONNX — macOS wheel build ==="
echo "    Version:  $VERSION"
echo "    Variants: ${VARIANTS[*]}"
echo "    Host:     $(sw_vers -productName) $(sw_vers -productVersion) ($(uname -m))"
echo

# ── Tooling check ──────────────────────────────────────────────────────────
# Find a working Homebrew (arm64 prefix on Apple Silicon, x86_64 on Intel).
if [ -x /opt/homebrew/bin/brew ]; then
    BREW=/opt/homebrew/bin/brew
elif [ -x /usr/local/bin/brew ]; then
    BREW=/usr/local/bin/brew
else
    echo "ERROR: Homebrew not found (looked in /opt/homebrew/bin and /usr/local/bin)" >&2
    exit 1
fi

for pkg in cmake ninja openssl@3 python@3.11; do
    if ! $BREW list "$pkg" >/dev/null 2>&1; then
        echo "Installing missing dep: $pkg"
        $BREW install --quiet "$pkg"
    fi
done

OPENSSL_PREFIX=$($BREW --prefix openssl@3)
PYTHON_BIN=$($BREW --prefix python@3.11)/bin/python3.11

# ── Build venv with Python build tooling ──────────────────────────────────
BUILD_ROOT="${BUILD_ROOT:-/tmp/kroko-onnx-macos-build}"
VENV="$BUILD_ROOT/venv"
if [ ! -x "$VENV/bin/python" ]; then
    rm -rf "$BUILD_ROOT"
    mkdir -p "$BUILD_ROOT"
    "$PYTHON_BIN" -m venv "$VENV"
    "$VENV/bin/pip" install --quiet --upgrade pip
    "$VENV/bin/pip" install --quiet wheel setuptools pybind11 delocate
fi
source "$VENV/bin/activate"

OUT="$ROOT/release_artifacts/macos"
rm -rf "$OUT"
mkdir -p "$OUT"

# Empty bits/stdc++.h shim. online-recognizer.cc has a stray
# `#include <bits/stdc++.h>` (a GCC convenience header) that macOS libc++
# doesn't ship — the surrounding STL headers are already included
# individually so a no-op stub satisfies the include.
SHIM_DIR="$BUILD_ROOT/include-shims"
rm -rf "$SHIM_DIR"
mkdir -p "$SHIM_DIR/bits"
: > "$SHIM_DIR/bits/stdc++.h"

build_variant() {
    local variant="$1"
    local license_flag
    case "$variant" in
        pro)  license_flag=ON  ;;
        free) license_flag=OFF ;;
    esac

    echo
    echo "──────────────────────────────────────────────────────────────"
    echo "  Variant: $variant  (KROKO_LICENSE=$license_flag)"
    echo "──────────────────────────────────────────────────────────────"

    local src_rw="$BUILD_ROOT/src-$variant"
    local dist_raw="$BUILD_ROOT/dist-raw-$variant"
    rm -rf "$src_rw" "$dist_raw"
    mkdir -p "$dist_raw"
    cp -a "$ROOT/." "$src_rw/"
    cd "$src_rw"

    # Bake the host's macOS version into the wheel tag. Homebrew dylibs
    # are built against the running OS, so a "lower" deployment target
    # would make delocate refuse the bundled libssl/libcrypto. Users
    # needing wider compatibility should run this script on the oldest
    # macOS they support (or use cibuildwheel + GitHub Actions).
    export MACOSX_DEPLOYMENT_TARGET="$(sw_vers -productVersion | cut -d. -f1).0"

    export SHERPA_ONNX_CMAKE_ARGS=" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DSHERPA_ONNX_ENABLE_BINARY=OFF \
        -DSHERPA_ONNX_ENABLE_WEBSOCKET=ON \
        -DSHERPA_ONNX_ENABLE_TTS=OFF \
        -DSHERPA_ONNX_ENABLE_PYTHON=ON \
        -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
        -DSHERPA_ONNX_ENABLE_JNI=OFF \
        -DSHERPA_ONNX_ENABLE_GPU=OFF \
        -DKROKO_LICENSE=$license_flag \
        -DKROKO_MODEL=ON \
        -DOPENSSL_ROOT_DIR=$OPENSSL_PREFIX \
        -DOPENSSL_USE_STATIC_LIBS=OFF \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET \
        -DCMAKE_CXX_FLAGS=-I$SHIM_DIR \
    "

    python setup.py bdist_wheel -d "$dist_raw" 2>&1 | tail -3

    # delocate bundles non-system dylibs (OpenSSL + anything else the
    # .so links against absolutely) into kroko_onnx/.dylibs/ and
    # rewrites install names to @loader_path/... so the wheel is
    # standalone.
    local repaired="$BUILD_ROOT/wheel-repaired-$variant"
    rm -rf "$repaired"
    mkdir -p "$repaired"
    delocate-wheel -w "$repaired" "$dist_raw"/*.whl 2>&1 | tail -2

    # Re-tag the wheel with a PEP 425 build tag so pro/free filenames
    # don't collide. `wheel tags --build 1<variant>` rewrites both the
    # filename and the in-wheel WHEEL metadata.
    local src_whl
    src_whl="$(ls "$repaired"/*.whl | head -1)"
    python -m wheel tags --build "1${variant}" --remove "$src_whl"
    cp -v "$repaired"/*.whl "$OUT/"
    cd "$ROOT"
}

for variant in "${VARIANTS[@]}"; do
    build_variant "$variant"
done

echo
echo "=== Done ==="
echo "    Output directory: $OUT"
for variant in "${VARIANTS[@]}"; do
    wheel="$(ls "$OUT"/*1${variant}*.whl 2>/dev/null | head -1)"
    if [ -n "$wheel" ]; then
        echo "    [$variant] Wheel: $wheel ($(du -h "$wheel" | cut -f1))"
    fi
done
