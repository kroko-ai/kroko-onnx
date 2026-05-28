#!/bin/bash
# =============================================================================
# In-container build script for the Windows cross-compile.
# Invoked by the Dockerfile.windows ENTRYPOINT after the user mounts the
# kroko-onnx checkout at /src and runs the container.
#
# Produces (in /out/bin/):
#   kroko-onnx-online-websocket-server.exe
#   sherpa-onnx-c-api.dll
#   sherpa-onnx-cxx-api.dll
#   onnxruntime.dll
#   (any other DLLs CMake installs via BUILD_SHARED_LIBS=ON)
#
# These are picked up by build_windows.sh on the host side to feed NSIS.
# =============================================================================
set -euo pipefail

echo "=== kroko-onnx Windows cross-compile ==="
echo "    CMake: $(cmake --version | head -1)"
echo "    clang: $(clang --version | head -1)"
echo "    xwin SDK at: ${XWIN_DIR:-/opt/xwin}"

# BUILD_VARIANT controls KROKO_LICENSE: "pro" → ON (license validation +
# metrics endpoint, libssl/libcrypto needed), "free" → OFF (community
# build, no OpenSSL deps). Default is pro since that's the shipping
# default for paid customers; build_windows.sh passes -e BUILD_VARIANT=…
# explicitly per invocation.
BUILD_VARIANT="${BUILD_VARIANT:-pro}"
case "$BUILD_VARIANT" in
    pro)  KROKO_LICENSE_FLAG=ON ;;
    free) KROKO_LICENSE_FLAG=OFF ;;
    *) echo "ERROR: unknown BUILD_VARIANT '$BUILD_VARIANT' (expected pro|free)" >&2; exit 1 ;;
esac
echo "    Variant: $BUILD_VARIANT (KROKO_LICENSE=$KROKO_LICENSE_FLAG)"
echo

cd /src

# /src is mounted read-only from the host so we can't drop build artefacts
# alongside the source. /out is the writable host volume (artefacts get
# copied there as the final step) but /out is a mount point so `rm -rf
# /out` itself fails — clear its contents instead.
BUILD_DIR=/tmp/build-windows
INSTALL_DIR=/out
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$INSTALL_DIR"
find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

# Pre-fetch + patch openfst once. Both the installer and wheel builds
# FetchContent it into separate build directories — we'd need to patch
# each independently. Instead grab it now into a shared location, run
# the `_MSC_VER` → `_MSC_VER && !__clang__` substitution once, and
# point both CMake invocations at this pre-patched copy via
# FETCHCONTENT_SOURCE_DIR_OPENFST.
OPENFST_DIR=/tmp/openfst-prepatched
if [ ! -d "$OPENFST_DIR/src" ]; then
    echo "Pre-fetching + patching openfst (shared across installer + wheel)"
    rm -rf "$OPENFST_DIR"
    mkdir -p "$OPENFST_DIR"
    curl -sLo /tmp/openfst.tgz \
        "https://github.com/csukuangfj/openfst/archive/refs/tags/sherpa-onnx-2024-06-19.tar.gz"
    tar -xzf /tmp/openfst.tgz -C /tmp/
    # mv * misses dotfiles so rmdir later fails — use rsync-style + rm -rf
    cp -a /tmp/openfst-sherpa-onnx-2024-06-19/. "$OPENFST_DIR/"
    rm -rf /tmp/openfst-sherpa-onnx-2024-06-19 /tmp/openfst.tgz
    # The same patch as before — exclude clang-cl from the _MSC_VER
    # __builtin_* fallback block so we don't collide with clang's
    # native builtins.
    sed -i 's|^#ifdef _MSC_VER$|#if defined(_MSC_VER) \&\& !defined(__clang__)|' \
        "$OPENFST_DIR/src/include/fst/compat.h"
fi

# Kroko's online-recognizer.cc has a stray `#include <bits/stdc++.h>` —
# that's a GCC convenience header (pulls in the whole STL) that doesn't
# exist with clang-cl / MSVC. The surrounding lines already include
# <map>/<functional>/<iostream>/<algorithm> individually so the catch-all
# is redundant. /src is mounted read-only so we can't sed the source.
# Drop an empty stub at <shims>/bits/stdc++.h and prepend that dir to the
# compiler include path — the offending #include resolves to a no-op and
# everything else uses the normal STL via the xwin SDK headers.
SHIM_DIR=/tmp/include-shims
mkdir -p "$SHIM_DIR/bits"
: > "$SHIM_DIR/bits/stdc++.h"

# Configure. The websocket server is gated by SHERPA_ONNX_ENABLE_WEBSOCKET
# (default ON) AND SHERPA_ONNX_ENABLE_BINARY. Build a minimal slice — we
# don't need TTS, the speaker-diarization CLI, the microphone CLIs, or any
# of the language bindings here. Just the online websocket server + its
# runtime DLLs.
cmake \
    -B "$BUILD_DIR" \
    -S /src \
    -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE=/src/cmake/toolchain-windows-clang.cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DBUILD_SHARED_LIBS=ON \
    -DFETCHCONTENT_SOURCE_DIR_OPENFST="$OPENFST_DIR" \
    `# Sherpa-onnx's cmake/onnxruntime-win-x64.cmake gates on` \
    `# CMAKE_VS_PLATFORM_NAME which only Visual Studio generators set —` \
    `# Ninja leaves it empty and the download script bails with` \
    `# "This file is for Windows x64 only. Given: ". Force it so the` \
    `# pre-built onnxruntime-win-x64 archive gets fetched.` \
    -DCMAKE_VS_PLATFORM_NAME=x64 \
    `# Explicit hint to CMake's FindOpenSSL — env var OPENSSL_ROOT_DIR is` \
    `# usually picked up automatically, but with the cross-compile` \
    `# toolchain restricting CMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY the` \
    `# safer thing is to pass it as a cache variable too.` \
    -DOPENSSL_ROOT_DIR=/opt/openssl-win64/app \
    -DOPENSSL_USE_STATIC_LIBS=OFF \
    `# The bits/stdc++.h shim's include path is added by the toolchain` \
    `# file (cmake/toolchain-windows-clang.cmake) as part of the` \
    `# system-header search list. Adding it here via -DCMAKE_*_FLAGS` \
    `# overrode the toolchain's xwin SDK paths and broke eigen's math` \
    `# library test, so we keep CMAKE_*_FLAGS untouched on the command` \
    `# line.` \
    -DSHERPA_ONNX_ENABLE_BINARY=ON \
    -DSHERPA_ONNX_ENABLE_WEBSOCKET=ON \
    -DSHERPA_ONNX_ENABLE_TTS=OFF \
    -DSHERPA_ONNX_ENABLE_C_API=ON \
    -DSHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF \
    -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
    -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
    -DSHERPA_ONNX_ENABLE_JNI=OFF \
    -DBUILD_PIPER_PHONMIZE_EXE=OFF \
    -DBUILD_PIPER_PHONMIZE_TESTS=OFF \
    -DBUILD_ESPEAK_NG_EXE=OFF \
    -DBUILD_ESPEAK_NG_TESTS=OFF \
    `# Kroko license + model gating. KROKO_LICENSE=ON pulls in the` \
    `# license.h wss:// client (asio::ssl::context → libssl/libcrypto)` \
    `# and the httplib::Server thread for /health /metrics /ready.` \
    `# KROKO_MODEL=ON swaps the help banner to the Kroko-branded text` \
    `# (kept ON for both variants — it's just the help text).` \
    -DKROKO_LICENSE=$KROKO_LICENSE_FLAG \
    -DKROKO_MODEL=ON \
    "$@"

# openfst (sherpa-onnx FetchContent dep) ships its own fallback __builtin_*
# helpers gated behind `#ifdef _MSC_VER`, intended for real MSVC which lacks
# GCC builtins. clang-cl defines _MSC_VER for ABI compat AND has the native
# GCC-style __builtin_ctzll / __builtin_popcountll — so both definitions
# fight: "functions that differ only in their return type cannot be
# overloaded". Patch the fetched copy in place so the fallback only kicks
# in for actual MSVC (cl.exe), not clang-cl. Cheaper than carrying a fork
# of openfst.
_compat_h=/tmp/build-windows/_deps/openfst-src/src/include/fst/compat.h
if [ -f "$_compat_h" ] && grep -q '^#ifdef _MSC_VER' "$_compat_h"; then
    echo "Patching openfst compat.h to exclude clang-cl from _MSC_VER fallback"
    sed -i.bak 's|^#ifdef _MSC_VER$|#if defined(_MSC_VER) \&\& !defined(__clang__)|' "$_compat_h"
fi

# Build only the online websocket server target; everything it links
# transitively (kroko-onnx-core, sherpa-onnx-c-api, sherpa-onnx-cxx-api,
# onnxruntime, etc.) is pulled in by Ninja automatically.
cmake --build "$BUILD_DIR" \
    --target kroko-onnx-online-websocket-server \
    --parallel "$(nproc)"

# `cmake --install` would copy the whole install set, but sherpa-onnx's
# install rules reference targets we deliberately didn't build
# (sherpa-onnx.exe, the offline server, the diarization CLI, etc.) and
# bail with "file INSTALL cannot find <not-built>.exe". Skip the install
# step and harvest artefacts directly from the build tree — Ninja drops
# the .exe and produced .dlls in $BUILD_DIR/bin/.
mkdir -p "$INSTALL_DIR/bin"

# Collect every .exe and .dll produced by the build. find walks both
# the per-target lib dirs (kroko-onnx-core.lib etc.) and the bin
# subtree where the linker writes finished executables. We skip the
# CUDA / TensorRT onnxruntime providers — they're bundled by the
# generic onnxruntime fetch but are useless for our CPU-only websocket
# server (no SHERPA_ONNX_ENABLE_GPU). The CUDA provider alone is
# ~370 MB; dropping it shrinks the installer from 58 MB to ~12 MB.
find "$BUILD_DIR" -type f \
    \( -iname '*.exe' -o -iname '*.dll' \) \
    -not -path '*/CMakeFiles/*' \
    -not -path '*/_deps/*-build/*test*' \
    -not -name 'onnxruntime_providers_cuda.dll' \
    -not -name 'onnxruntime_providers_tensorrt.dll' \
    -exec cp -v {} "$INSTALL_DIR/bin/" \;

# Ship Microsoft's VC++ Redistributable installer so the NSIS installer
# can chain-install it on the target machine before launching the
# server. Required because we link with /MD (dynamic CRT); without
# vcruntime/msvcp on the user's machine the .exe won't start.
cp -v /opt/vc_redist/vc_redist.x64.exe "$INSTALL_DIR/bin/"

# OpenSSL runtime DLLs. With KROKO_LICENSE=ON the server actually invokes
# the wss:// license-validation client (asio_tls → libssl) AND the
# httplib metrics endpoints — both of which import libcrypto-3-x64.dll +
# libssl-3-x64.dll at runtime. Without these alongside the .exe the
# launcher fails with "The code execution cannot proceed because
# libssl-3-x64.dll was not found."
#
# In the "free" variant the linker dead-strips the unused TLS code so
# the .exe has no OpenSSL imports — bundling the DLLs would just add
# 8 MB of dead weight to the installer.
if [ "$BUILD_VARIANT" = "pro" ]; then
    cp -v /opt/openssl-win64/app/bin/libcrypto-3-x64.dll "$INSTALL_DIR/bin/"
    cp -v /opt/openssl-win64/app/bin/libssl-3-x64.dll "$INSTALL_DIR/bin/"
fi

# Drop import libraries and CMake config files — installer doesn't need them.
rm -rf "$INSTALL_DIR/lib" "$INSTALL_DIR/include" "$INSTALL_DIR/share" 2>/dev/null || true

echo
echo "=== Build artefacts in $INSTALL_DIR/bin ==="
ls -lh "$INSTALL_DIR/bin"

# Sanity: the headline target must exist.
if [ ! -f "$INSTALL_DIR/bin/kroko-onnx-online-websocket-server.exe" ]; then
    echo "ERROR: kroko-onnx-online-websocket-server.exe missing from build output" >&2
    exit 1
fi

# ─── Python wheel (Linux → win_amd64 cross-compile) ─────────────────────────
# Non-fatal: if this fails the installer (already built above) still ships.
# Switch back to strict-fail with `set -e` enabled inside the subshell once
# the cross-compile is reliable.
(
set +e
echo
echo "=== Building Python wheel (cross-compile to win_amd64) ==="
WHEEL_BUILD=/tmp/wheel-build
WHEEL_OUT=$INSTALL_DIR/wheel
rm -rf "$WHEEL_BUILD" "$WHEEL_OUT"
mkdir -p "$WHEEL_BUILD" "$WHEEL_OUT"

# Mirror /src into /tmp/src-rw so setup.py can write build/ + dist/ scratch
# files. /src is mounted read-only from the host; copying out keeps the
# source tree pristine. Use -a to preserve perms and -l on tarballs would
# be faster but cp is fine for the size involved here.
SRC_RW=/tmp/src-rw
rm -rf "$SRC_RW"
cp -a /src "$SRC_RW"
cd "$SRC_RW"

# setup.py / cmake_extension.py drive CMake. Feed it the same toolchain
# + flags we used for the installer build, plus Python paths pointing at
# the Windows headers/libs in /opt/python-win64. SHERPA_ONNX_CMAKE_ARGS
# is the documented escape hatch — see kroko-onnx/cmake/cmake_extension.py.
export SHERPA_ONNX_CMAKE_ARGS=" \
    -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE=/src/cmake/toolchain-windows-clang.cmake \
    -DFETCHCONTENT_SOURCE_DIR_OPENFST=${OPENFST_DIR} \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_VS_PLATFORM_NAME=x64 \
    -DOPENSSL_ROOT_DIR=/opt/openssl-win64/app \
    -DOPENSSL_USE_STATIC_LIBS=OFF \
    -DSHERPA_ONNX_ENABLE_BINARY=OFF \
    `# WEBSOCKET=ON is required even though we don't build the server binary:` \
    `# sherpa-onnx's license.h hard-includes websocketpp/config/asio_client.hpp` \
    `# unconditionally and the websocketpp FetchContent is gated by the same` \
    `# flag. BINARY=OFF still prevents the server executables from being added.` \
    -DSHERPA_ONNX_ENABLE_WEBSOCKET=ON \
    -DSHERPA_ONNX_ENABLE_TTS=OFF \
    -DSHERPA_ONNX_ENABLE_PYTHON=ON \
    -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
    -DSHERPA_ONNX_ENABLE_JNI=OFF \
    `# Same Kroko license/model gating as the installer build. The wheel's` \
    `# _sherpa_onnx.pyd compiles online-transducer-model.cc, which under` \
    `# KROKO_LICENSE actually calls into the LicenseClient — so libssl /` \
    `# libcrypto become real imports (vs the linked-but-unused state of` \
    `# the no-license build). delvewheel below picks the DLLs up via` \
    `# --add-path /opt/openssl-win64/app/bin (pro only).` \
    -DKROKO_LICENSE=$KROKO_LICENSE_FLAG \
    -DKROKO_MODEL=ON \
    `# Force pybind11 v2.12 to use modern find_package(Python ...) instead of` \
    `# the legacy PythonInterp path that introspects the running` \
    `# interpreter (which would be Linux 3.12, wrong). pybind11NewTools` \
    `# specifically calls find_package(Python COMPONENTS Development.Module),` \
    `# NOT Python3 — so we have to set both naming families.` \
    -DPYBIND11_FINDPYTHON=ON \
    -DPYBIND11_NOPYTHON=OFF \
    `# Python (no 3 suffix) — used by pybind11NewTools.cmake` \
    -DPython_INCLUDE_DIR=${PYTHON_WIN_INCLUDE} \
    -DPython_LIBRARY=${PYTHON_WIN_LIB} \
    -DPython_EXECUTABLE=/usr/bin/python3 \
    `# Python3 — used by anything else that asks for Python3 specifically` \
    -DPython3_INCLUDE_DIR=${PYTHON_WIN_INCLUDE} \
    -DPython3_LIBRARY=${PYTHON_WIN_LIB} \
    -DPython3_EXECUTABLE=/usr/bin/python3"

# Force the wheel's platform tag. Without --plat-name, bdist_wheel picks
# the host platform (linux_x86_64) which is wrong — we're producing a
# Windows-targeted binary wheel.
python3 setup.py bdist_wheel --plat-name win_amd64 -d "$WHEEL_BUILD"

UNREPAIRED_WHEEL=$(ls "$WHEEL_BUILD"/*.whl 2>/dev/null | head -1)
if [ -z "$UNREPAIRED_WHEEL" ]; then
    echo "ERROR: setup.py bdist_wheel produced no .whl" >&2
    exit 1
fi
echo "Unrepaired wheel: $UNREPAIRED_WHEEL"

# Cross-compile naming fix. CMake produces a Windows PE binary but
# setup.py names it with the host-Linux EXT_SUFFIX
# (.cpython-312-x86_64-linux-gnu.so) because sysconfig.get_config_var()
# reflects the running interpreter, not the target. Windows Python
# only loads .pyd files matching .cp<ver>-win_amd64.pyd (PEP 425) or
# plain .pyd — the .so won't be found at import time, so the wheel
# installs cleanly but `import kroko_onnx` blows up.
#
# Side effect: delvewheel can't follow transitive DLL imports through
# a file it doesn't recognise as a Python extension, which is why
# libssl/libcrypto weren't being bundled before this rename.
#
# Fix: unpack the wheel, rename .cpython-*-linux-gnu.so to
# .cp${PYTHON_WIN_TAG#cp}-win_amd64.pyd, then repack — `wheel pack`
# rewrites RECORD with fresh hashes so pip won't reject the repack.
WIN_TAG="${PYTHON_WIN_TAG:-cp312}"
echo "Renaming extension to ${WIN_TAG}-win_amd64.pyd (cross-compile target)"
rm -rf /tmp/wheel-unpacked
mkdir -p /tmp/wheel-unpacked
python3 -m wheel unpack "$UNREPAIRED_WHEEL" -d /tmp/wheel-unpacked
UNPACKED_DIR=$(ls -d /tmp/wheel-unpacked/*/ | head -1)
find "$UNPACKED_DIR" -name "*.cpython-*-linux-gnu.so" | while read -r f; do
    new=$(echo "$f" | sed -E "s|\.cpython-[0-9]+-x86_64-linux-gnu\.so$|.${WIN_TAG}-win_amd64.pyd|")
    echo "  $(basename "$f") -> $(basename "$new")"
    mv "$f" "$new"
done
rm -f "$UNREPAIRED_WHEEL"
python3 -m wheel pack "$UNPACKED_DIR" --dest-dir "$WHEEL_BUILD"
UNREPAIRED_WHEEL=$(ls "$WHEEL_BUILD"/*.whl 2>/dev/null | head -1)
echo "Repacked wheel: $UNREPAIRED_WHEEL"

# Bundle every dependent DLL into the wheel so `pip install <whl>`
# yields a self-contained install — onnxruntime.dll + sherpa-onnx-c-api
# + everything the .pyd loads transitively, plus the vcruntime DLLs that
# would otherwise have to come from a separate vc_redist install. The
# wheel ends up larger but actually works offline / on machines without
# the VC++ Redistributable. delvewheel walks the import table itself,
# so we don't have to maintain an explicit DLL list.
# In the pro variant the .pyd has real libssl/libcrypto imports and
# delvewheel needs --add-path pointed at the OpenSSL bin dir to find
# them. The free .pyd doesn't import OpenSSL at all (no LicenseClient
# code emitted), so the flag is harmless either way — but skipping it
# for free keeps the wheel free of stale paths in case xwin OpenSSL
# isn't installed during a partial image build.
DELVEWHEEL_OPENSSL_ARGS=""
if [ "$BUILD_VARIANT" = "pro" ]; then
    DELVEWHEEL_OPENSSL_ARGS="--add-path /opt/openssl-win64/app/bin"
fi

python3 -m delvewheel repair \
    --add-path "$INSTALL_DIR/bin" \
    --add-path "$SRC_RW/build/sherpa_onnx/bin" \
    $DELVEWHEEL_OPENSSL_ARGS \
    `# Same filter as the installer harvest (build_windows.sh):` \
    `# onnxruntime_providers_cuda.dll is 370 MB and we're building a` \
    `# CPU-only wheel. delvewheel was bundling it because the wheel's` \
    `# build tree contains the full onnxruntime download. Exclude both` \
    `# GPU providers so the wheel stays in the ~12-15 MB range instead` \
    `# of 122 MB.` \
    --exclude onnxruntime_providers_cuda.dll \
    --exclude onnxruntime_providers_tensorrt.dll \
    `# Microsoft Visual C++ runtime DLLs. xwin SDK only ships the .lib` \
    `# import libraries, not the actual runtime DLLs — delvewheel walks` \
    `# the .pyd's imports, sees MSVCP140 / VCRUNTIME140 / VCRUNTIME140_1` \
    `# and bails with "Unable to find library". Standard Python wheel` \
    `# convention is to leave these to the user's system: python.org's` \
    `# Windows installer bundles vcruntime140.dll, and any modern Windows` \
    `# machine has msvcp140 from any installed app. End users running an` \
    `# odd minimal environment can grab vc_redist.x64.exe — same DLL the` \
    `# kroko-onnx installer chain-installs.` \
    --exclude msvcp140.dll \
    --exclude vcruntime140.dll \
    --exclude vcruntime140_1.dll \
    --wheel-dir "$WHEEL_OUT" \
    "$UNREPAIRED_WHEEL"

# Strip oversized GPU provider DLLs (CUDA, TensorRT). They ride into the
# wheel via setup.py's data_files chain from the onnxruntime-win-x64
# download regardless of our SHERPA_ONNX_ENABLE_GPU=OFF — roughly 370 MB
# combined, unused at runtime since nothing in the wheel links the GPU
# providers. The image doesn't have `zip` (only p7zip / unzip), so we
# use 7z's `d` (delete-from-archive) command which edits in place.
for whl in "$WHEEL_OUT"/*.whl; do
    [ -f "$whl" ] || continue
    echo "Stripping GPU providers from $(basename "$whl")"
    7z d -tzip "$whl" \
        onnxruntime_providers_cuda.dll \
        onnxruntime_providers_tensorrt.dll \
        >/dev/null
done

echo
echo "=== Repaired + slimmed wheel ==="
ls -lh "$WHEEL_OUT" 2>/dev/null || true
) || {
    echo "WARN: wheel build failed; installer is still good and was produced above."
    echo "      see https://github.com/.../actions/workflows/build-wheels-win64.yaml"
    echo "      for the GitHub-Actions wheel build path that's already wired up."
}
