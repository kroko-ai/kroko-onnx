@echo off
REM ===========================================================================
REM Build kroko-onnx-online-websocket-server for Windows (x86_64) on a
REM Windows host, via Docker Desktop. cmd.exe port of build_windows.sh.
REM
REM Identical output layout to the .sh: release_artifacts\windows\ holds
REM per-variant installers (and wheels) named with the variant suffix.
REM
REM Usage:
REM   build_windows.bat                       both variants
REM   build_windows.bat --variant pro         just the pro variant
REM   build_windows.bat --variant free        just the free variant
REM
REM Requirements on the Windows host:
REM   - Docker Desktop (WSL2 backend) — provides docker buildx, linux/amd64
REM   - PowerShell (ships with Windows 10/11) — used for the one place batch
REM     can't cleanly parse the CMakeLists version line
REM ===========================================================================
setlocal enabledelayedexpansion

REM ── Parse args ──────────────────────────────────────────────────────────────
set "VARIANTS_RAW=both"

:parse_args
if "%~1"=="" goto args_done
if /I "%~1"=="--variant" (
    set "VARIANTS_RAW=%~2"
    shift
    shift
    goto parse_args
)
REM Allow --variant=pro style too.
set "ARG=%~1"
if /I "!ARG:~0,10!"=="--variant=" (
    set "VARIANTS_RAW=!ARG:~10!"
    shift
    goto parse_args
)
echo Unknown option: %~1 >&2
exit /b 1
:args_done

REM Validate variant selector.
set "VARIANT_LIST="
if /I "%VARIANTS_RAW%"=="pro"  set "VARIANT_LIST=pro"
if /I "%VARIANTS_RAW%"=="free" set "VARIANT_LIST=free"
if /I "%VARIANTS_RAW%"=="both" set "VARIANT_LIST=pro free"
if "!VARIANT_LIST!"=="" (
    echo ERROR: --variant must be pro^|free^|both ^(got '%VARIANTS_RAW%'^) >&2
    exit /b 1
)

echo === Kroko ONNX WebSocket Server — Windows build ^(x86_64^) ===
echo     Variants: !VARIANT_LIST!
echo.

REM ── Resolve project root (directory containing this script) ────────────────
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
cd /d "%ROOT%"

REM ── Parse version from CMakeLists.txt ──────────────────────────────────────
REM CMakeLists has:  set(SHERPA_ONNX_VERSION "1.12.9")
REM PowerShell oneliner because batch's delimiter quoting around `"` is
REM unreadable and findstr+for /f works but trips on nested quotes.
set "VERSION="
for /f "usebackq delims=" %%v in (`powershell -NoProfile -Command "$m = Select-String -Path '%ROOT%\CMakeLists.txt' -Pattern 'set\(SHERPA_ONNX_VERSION\s+\"([0-9]+\.[0-9]+\.[0-9]+)\"' -List; if ($m) { $m.Matches[0].Groups[1].Value }"`) do set "VERSION=%%v"

if "%VERSION%"=="" (
    echo ERROR: failed to parse SHERPA_ONNX_VERSION from CMakeLists.txt >&2
    exit /b 1
)
echo     Version: %VERSION%

set "OUT=%ROOT%\release_artifacts\windows"
if exist "%OUT%" rmdir /S /Q "%OUT%"
mkdir "%OUT%"

REM ── Step 1: build the Docker image (cached on subsequent runs) ─────────────
set "IMAGE=kroko-onnx-windows-builder"
echo.
echo [1/N] Building Docker image: %IMAGE%
docker buildx build --platform linux/amd64 -t "%IMAGE%" -f Dockerfile.windows .
if errorlevel 1 (
    echo ERROR: docker image build failed >&2
    exit /b 1
)

REM ── Per-variant build ──────────────────────────────────────────────────────
for %%V in (!VARIANT_LIST!) do (
    call :build_variant %%V
    if errorlevel 1 exit /b 1
)

REM ── Final summary ──────────────────────────────────────────────────────────
echo.
echo === Done ===
echo     Output directory: %OUT%
for %%V in (!VARIANT_LIST!) do (
    set "_inst=%OUT%\kroko-onnx-websocket-server-%VERSION%-%%V-setup.exe"
    call :size_h "!_inst!" _sz
    echo     [%%V] Installer:  !_inst! ^(!_sz!^)
    for %%W in ("%OUT%\*1%%V*.whl") do (
        call :size_h "%%~fW" _sz
        echo     [%%V] Wheel:      %%~fW ^(!_sz!^)
    )
)

endlocal
exit /b 0

REM ===========================================================================
REM :build_variant <variant>
REM
REM Runs the docker container with BUILD_VARIANT=<variant>, then NSIS.
REM Mirrors the build_variant() shell function in build_windows.sh — same
REM step numbering and output naming.
REM ===========================================================================
:build_variant
set "VARIANT=%~1"
echo.
echo ──────────────────────────────────────────────────────────────
echo   Variant: %VARIANT%
echo ──────────────────────────────────────────────────────────────

set "STAGING=%OUT%\bin-%VARIANT%"
set "INSTALLER=%OUT%\kroko-onnx-websocket-server-%VERSION%-%VARIANT%-setup.exe"
if exist "%STAGING%" rmdir /S /Q "%STAGING%"
mkdir "%STAGING%"

REM ── Step 2: cross-compile inside the container ─────────────────────────────
echo.
echo [2/3] Cross-compiling kroko-onnx-online-websocket-server.exe ^(%VARIANT%^)

REM No mktemp on Windows — synthesise from %RANDOM% + time bits. Cleaned up
REM at the end of this function (best-effort; if the script is Ctrl-C'd the
REM temp dir is left behind under %TEMP% — minor and self-evident).
set "HOST_OUT=%TEMP%\kroko-onnx-out-%VARIANT%-%RANDOM%-%TIME:~6,2%%TIME:~9,2%"
set "HOST_OUT=%HOST_OUT: =0%"
mkdir "%HOST_OUT%"

set "CONTAINER=kroko-onnx-windows-build-%VARIANT%-%RANDOM%"
REM Mount source read-only so a bad container script can't poison the
REM checkout. Docker Desktop on Windows accepts native Windows paths
REM with backslashes; no path translation needed.
docker run --rm ^
    --name "%CONTAINER%" ^
    --platform linux/amd64 ^
    -e BUILD_VARIANT=%VARIANT% ^
    -v "%ROOT%:/src:ro" ^
    -v "%HOST_OUT%:/out" ^
    "%IMAGE%"
if errorlevel 1 (
    echo ERROR: container build failed for variant %VARIANT% >&2
    exit /b 1
)

REM Copy staged bin/ artefacts. xcopy /E /I /Y mirrors `cp -r` non-interactively.
xcopy /E /I /Y /Q "%HOST_OUT%\bin\*" "%STAGING%\" >nul
for /f %%C in ('dir /B "%STAGING%" 2^>nul ^| find /C /V ""') do set "STAGING_COUNT=%%C"
echo     Staged !STAGING_COUNT! files in %STAGING%

REM Wheel — rewrite with a PEP 425 build tag so the pro/free filenames
REM don't collide. `wheel tags --build` updates both the filename and the
REM internal WHEEL metadata. Run inside the build image so we don't depend
REM on the host having a Python wheel toolchain installed.
set "WHEEL="
if exist "%HOST_OUT%\wheel" (
    set "_WHL_NAME="
    for %%W in ("%HOST_OUT%\wheel\*.whl") do set "_WHL_NAME=%%~nxW"
    if defined _WHL_NAME (
        docker run --rm --platform linux/amd64 ^
            --entrypoint python3 ^
            -v "%HOST_OUT%\wheel:/wheel" ^
            "%IMAGE%" -m wheel tags --build "1%VARIANT%" ^
            --remove "/wheel/!_WHL_NAME!"
        if errorlevel 1 (
            echo ERROR: wheel re-tag failed for %VARIANT% >&2
            exit /b 1
        )
        copy /Y "%HOST_OUT%\wheel\*.whl" "%OUT%\" >nul
        for %%W in ("%OUT%\*1%VARIANT%*.whl") do set "WHEEL=%%~fW"
        call :size_h "!WHEEL!" _sz
        echo     Wheel: !WHEEL! ^(!_sz!^)
    ) else (
        echo     ^(no wheel produced — skipping^)
    )
) else (
    echo     ^(no wheel directory produced — skipping^)
)

REM Clean up temp dir.
rmdir /S /Q "%HOST_OUT%" 2>nul

REM ── Step 3: build the NSIS installer ───────────────────────────────────────
echo.
echo [3/3] Building NSIS installer ^(%VARIANT%^)
where makensis >nul 2>&1
if not errorlevel 1 (
    makensis -V2 ^
        "-DSTAGING=%STAGING%" ^
        "-DVERSION=%VERSION%" ^
        "-DOUTFILE=%INSTALLER%" ^
        installer\kroko-onnx-websocket-server.nsi
) else (
    echo     Local makensis not found — invoking NSIS inside the build image.
    docker run --rm ^
        --platform linux/amd64 ^
        --entrypoint makensis ^
        -v "%ROOT%:/src:ro" ^
        -v "%OUT%:/out_real" ^
        "%IMAGE%" ^
        -V2 ^
        "-DSTAGING=/src/release_artifacts/windows/bin-%VARIANT%" ^
        "-DVERSION=%VERSION%" ^
        "-DOUTFILE=/out_real/kroko-onnx-websocket-server-%VERSION%-%VARIANT%-setup.exe" ^
        /src/installer/kroko-onnx-websocket-server.nsi
)
if errorlevel 1 (
    echo ERROR: NSIS build failed for %VARIANT% >&2
    exit /b 1
)
if not exist "%INSTALLER%" (
    echo ERROR: installer not produced at %INSTALLER% >&2
    exit /b 1
)
call :size_h "%INSTALLER%" _sz
echo     Built: %INSTALLER% ^(!_sz!^)
exit /b 0

REM ===========================================================================
REM :size_h <path> <out_var>
REM
REM Human-readable size (KB/MB) for a single file. Sets the named variable
REM in the caller's scope. dir's right-justified byte count is what we have
REM available without PowerShell — divide via cmd /a math.
REM ===========================================================================
:size_h
set "_path=%~1"
set "_var=%~2"
set "_bytes=0"
for %%I in ("%_path%") do set "_bytes=%%~zI"
if "%_bytes%"=="0" (
    set "%_var%=0B"
    exit /b 0
)
if %_bytes% LSS 1024 (
    set "%_var%=%_bytes%B"
    exit /b 0
)
set /a "_kb=%_bytes%/1024"
if %_kb% LSS 1024 (
    set "%_var%=%_kb%K"
    exit /b 0
)
set /a "_mb=%_kb%/1024"
set "%_var%=%_mb%M"
exit /b 0
