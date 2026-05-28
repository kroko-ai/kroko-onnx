#!/bin/bash
# =============================================================================
# Build kroko-onnx-online-websocket-server for Windows (x86_64) from macOS
# or Linux via Docker, then package into an NSIS installer.
#
# Builds a Docker image once, runs the container to cross-compile, extracts
# artefacts, runs NSIS — once per variant.
#
# Usage:
#   ./build_windows.sh                     # both variants
#   ./build_windows.sh --variant pro       # just pro
#   ./build_windows.sh --variant free      # just free
#
# Output:
#   release_artifacts/windows/bin-<variant>/                       raw artefacts
#   release_artifacts/windows/kroko-onnx-websocket-server-<version>-<variant>-setup.exe
#   release_artifacts/windows/kroko_onnx-<version>-1<variant>-cp312-cp312-win_amd64.whl
# =============================================================================
set -euo pipefail
# Without pipefail, `docker run ... | tee` masks docker's non-zero exit
# (tee always exits 0), so a failed in-container step looks like success
# from the caller's perspective. Enabling it surfaces real failures.

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

echo "=== Kroko ONNX WebSocket Server — Windows build (x86_64) ==="
echo "    Variants: ${VARIANTS[*]}"
echo

# Resolve project root and version (taken from CMakeLists.txt as setup.py does).
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

VERSION=$(grep -E 'set\(SHERPA_ONNX_VERSION' CMakeLists.txt \
    | head -1 \
    | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/')
if [ -z "$VERSION" ]; then
    echo "ERROR: failed to parse SHERPA_ONNX_VERSION from CMakeLists.txt" >&2
    exit 1
fi
echo "    Version: $VERSION"

OUT="$ROOT/release_artifacts/windows"
rm -rf "$OUT"
mkdir -p "$OUT"

# ── Step 1: build the Docker image (cached on subsequent runs) ───────────────
IMAGE=kroko-onnx-windows-builder
echo
echo "[1/N] Building Docker image: $IMAGE"
docker buildx build --platform linux/amd64 -t "$IMAGE" -f Dockerfile.windows .

# build_variant(): runs the docker container + NSIS for a single variant
# ("pro" or "free"). Writes artefacts to release_artifacts/windows/ with
# the variant baked into every filename so pro/free outputs sit side-by-
# side without clobbering each other.
build_variant() {
    local variant="$1"
    echo
    echo "──────────────────────────────────────────────────────────────"
    echo "  Variant: $variant"
    echo "──────────────────────────────────────────────────────────────"

    local staging="$OUT/bin-${variant}"
    local installer="$OUT/kroko-onnx-websocket-server-${VERSION}-${variant}-setup.exe"
    rm -rf "$staging"
    mkdir -p "$staging"

    # ── Step 2: cross-compile inside the container ──────────────────────────
    echo
    echo "[2/3] Cross-compiling kroko-onnx-online-websocket-server.exe ($variant)"
    local container="kroko-onnx-windows-build-${variant}-$(date +%s)"
    # Mount the source tree read-only so a bad in-container script can't
    # poison the host checkout; the container writes to a writable /out
    # volume which we then copy into release_artifacts/.
    local host_out
    host_out="$(mktemp -d -t kroko-onnx-out-${variant}-XXXXXX)"

    docker run --rm \
        --name "$container" \
        --platform linux/amd64 \
        -e BUILD_VARIANT="$variant" \
        -v "$ROOT:/src:ro" \
        -v "$host_out:/out" \
        "$IMAGE"

    cp -r "$host_out/bin/." "$staging/"
    echo "    Staged $(ls -1 "$staging" | wc -l | tr -d ' ') files in $staging"

    # Wheel — re-tag with a PEP 425 build tag so the pro/free filenames
    # don't collide. `wheel tags --build` rewrites both the filename and
    # the wheel's internal WHEEL metadata. The leading digit is required
    # by PEP 425.
    local wheel=""
    if [ -d "$host_out/wheel" ] && [ -n "$(ls "$host_out/wheel"/*.whl 2>/dev/null)" ]; then
        local src_whl
        src_whl="$(ls "$host_out/wheel"/*.whl | head -1)"
        # Use Docker python (host may not have `wheel`); same image as the build.
        docker run --rm --platform linux/amd64 \
            --entrypoint python3 \
            -v "$host_out/wheel:/wheel" \
            "$IMAGE" -m wheel tags --build "1${variant}" \
            --remove "/wheel/$(basename "$src_whl")"
        cp -v "$host_out/wheel"/*.whl "$OUT/"
        wheel="$(ls "$OUT"/*1${variant}*.whl 2>/dev/null | head -1)"
        echo "    Wheel: $wheel ($(du -h "$wheel" | cut -f1))"
    else
        echo "    (no wheel produced — skipping)"
    fi

    rm -rf "$host_out"

    # ── Step 3: build the NSIS installer ────────────────────────────────────
    echo
    echo "[3/3] Building NSIS installer ($variant)"
    if command -v makensis >/dev/null 2>&1; then
        makensis -V2 \
            "-DSTAGING=$staging" \
            "-DVERSION=$VERSION" \
            "-DOUTFILE=$installer" \
            installer/kroko-onnx-websocket-server.nsi
    else
        echo "    Local makensis not found — invoking NSIS inside the build image."
        docker run --rm \
            --platform linux/amd64 \
            --entrypoint makensis \
            -v "$ROOT:/src:ro" \
            -v "$OUT:/out_real" \
            "$IMAGE" \
            -V2 \
            "-DSTAGING=/src/release_artifacts/windows/bin-${variant}" \
            "-DVERSION=$VERSION" \
            "-DOUTFILE=/out_real/kroko-onnx-websocket-server-${VERSION}-${variant}-setup.exe" \
            /src/installer/kroko-onnx-websocket-server.nsi
    fi

    if [ ! -f "$installer" ]; then
        echo "ERROR: installer not produced at $installer" >&2
        exit 1
    fi
    echo "    Built: $installer ($(du -h "$installer" | cut -f1))"
}

for variant in "${VARIANTS[@]}"; do
    build_variant "$variant"
done

echo
echo "=== Done ==="
echo "    Output directory: $OUT"
for variant in "${VARIANTS[@]}"; do
    installer="$OUT/kroko-onnx-websocket-server-${VERSION}-${variant}-setup.exe"
    wheel="$(ls "$OUT"/*1${variant}*.whl 2>/dev/null | head -1)"
    echo "    [$variant] Installer:  $installer ($(du -h "$installer" 2>/dev/null | cut -f1))"
    if [ -n "$wheel" ]; then
        echo "    [$variant] Wheel:      $wheel ($(du -h "$wheel" 2>/dev/null | cut -f1))"
    fi
done
