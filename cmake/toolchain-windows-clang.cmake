# =============================================================================
# CMake toolchain — cross-compile sherpa-onnx for Windows (x86_64-pc-windows-msvc)
# from Linux using clang + lld + the Microsoft MSVC SDK downloaded by xwin.
# =============================================================================
#
# Mirrors the cargo-xwin pattern voice-scribe uses for its Tauri/Rust builds —
# same SDK source (xwin → /opt/xwin), same clang version, same lld-link
# linker. The Docker image (Dockerfile.windows) sets up /opt/xwin and the
# clang-19 symlinks before invoking CMake with this toolchain file.

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

# Allow the Docker image to override paths if it stores xwin elsewhere.
if(NOT DEFINED XWIN_DIR)
    if(DEFINED ENV{XWIN_DIR})
        set(XWIN_DIR $ENV{XWIN_DIR})
    else()
        set(XWIN_DIR "/opt/xwin")
    endif()
endif()
message(STATUS "Using xwin SDK at: ${XWIN_DIR}")

# Use the clang-cl symlink (clang-19 invoked as clang-cl drives the MSVC
# frontend automatically; clang switches its arg parser based on argv[0]).
# CMake then derives CMAKE_<LANG>_COMPILER_FRONTEND_VARIANT=MSVC from the
# binary name, so MSVC-style flags (/MD, /libpath:, /imsvc, etc.) work
# end-to-end. Mixing `clang` + manual FRONTEND_VARIANT=MSVC fails at the
# CMakeDetermineCompilerABI try-compile (CMake 3.30 enforces consistency).
set(CMAKE_C_COMPILER   clang-cl)
set(CMAKE_CXX_COMPILER clang-cl)
set(CMAKE_RC_COMPILER  llvm-rc)
set(CMAKE_AR           llvm-lib)
set(CMAKE_LINKER       lld-link)

set(CMAKE_C_COMPILER_TARGET   x86_64-pc-windows-msvc)
set(CMAKE_CXX_COMPILER_TARGET x86_64-pc-windows-msvc)

# clang needs explicit include paths to the SDK; xwin splats them into
# crt/include (Visual C runtime) and sdk/include/{ucrt,um,shared}.
# We also prepend an "include shim" directory that the container script
# (in_windows_container.sh) populates with stubs for GCC-only headers
# (bits/stdc++.h, etc.) that some translation units still reference.
# Empty stubs make the #includes no-ops without us having to fork the
# source tree.
set(_xwin_includes
    "-imsvc /tmp/include-shims"
    "-imsvc ${XWIN_DIR}/crt/include"
    "-imsvc ${XWIN_DIR}/sdk/include/ucrt"
    "-imsvc ${XWIN_DIR}/sdk/include/um"
    "-imsvc ${XWIN_DIR}/sdk/include/shared"
    "-imsvc ${XWIN_DIR}/sdk/include/winrt"
)
string(JOIN " " _xwin_includes_flags ${_xwin_includes})

# Always link against the Release CRT. xwin splat ships only release import
# libraries (msvcrt.lib, vcruntime.lib, ucrt.lib) — there's no msvcrtd.lib
# in the SDK output. CMP0091 / CMAKE_MSVC_RUNTIME_LIBRARY only affects
# project targets, not CMake's own compiler-check try-compile (which still
# uses CMAKE_<LANG>_FLAGS_DEBUG verbatim and embeds /MDd). Override the
# per-config flags directly — both _INIT (first configure) and the plain
# variant (post-cache reload, and the value the try-compile actually sees).
foreach(_lang C CXX)
    foreach(_cfg DEBUG MINSIZEREL)
        set(CMAKE_${_lang}_FLAGS_${_cfg}_INIT "/MD /Zi /Ob0 /Od")
        set(CMAKE_${_lang}_FLAGS_${_cfg}      "/MD /Zi /Ob0 /Od" CACHE STRING "" FORCE)
    endforeach()
    foreach(_cfg RELEASE RELWITHDEBINFO)
        set(CMAKE_${_lang}_FLAGS_${_cfg}_INIT "/MD /O2 /Ob2 /DNDEBUG")
        set(CMAKE_${_lang}_FLAGS_${_cfg}      "/MD /O2 /Ob2 /DNDEBUG" CACHE STRING "" FORCE)
    endforeach()
endforeach()

cmake_policy(SET CMP0091 NEW)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreadedDLL" CACHE STRING "" FORCE)
set(CMAKE_POLICY_DEFAULT_CMP0091 NEW)

set(CMAKE_C_FLAGS_INIT   "${_xwin_includes_flags}")
set(CMAKE_CXX_FLAGS_INIT "${_xwin_includes_flags}")

# Linker flags. lld-link IS the linker — `-fuse-ld=lld-link` is a compiler-
# driver hint that gets passed through verbatim and warned about. Just
# point at the SDK lib paths and pass /manifest:no (the SDK doesn't ship
# the manifest tool and we have no need for embedded manifests in a CLI
# server binary).
set(_xwin_linker_flags
    "/manifest:no"
    "/libpath:${XWIN_DIR}/crt/lib/x86_64"
    "/libpath:${XWIN_DIR}/sdk/lib/um/x86_64"
    "/libpath:${XWIN_DIR}/sdk/lib/ucrt/x86_64"
)
string(JOIN " " _xwin_linker_flags_str ${_xwin_linker_flags})
set(CMAKE_EXE_LINKER_FLAGS_INIT    "${_xwin_linker_flags_str}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${_xwin_linker_flags_str}")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "${_xwin_linker_flags_str}")

# Search roots — Windows targets must NOT pick up host Linux libraries
# (those don't link), but we still need other Windows-native deps the
# Dockerfile installs separately (OpenSSL at /opt/openssl-win64/app).
# Add every Windows-target sysroot here; FindOpenSSL etc. will walk
# this list when looking for libraries / headers.
set(_extra_roots /opt/openssl-win64/app)
foreach(_extra_root IN LISTS _extra_roots)
    if(IS_DIRECTORY ${_extra_root})
        list(APPEND CMAKE_FIND_ROOT_PATH ${_extra_root})
    endif()
endforeach()
list(APPEND CMAKE_FIND_ROOT_PATH ${XWIN_DIR})

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
