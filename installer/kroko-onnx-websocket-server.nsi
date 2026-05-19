; =============================================================================
; NSIS installer for kroko-onnx-online-websocket-server.
;
; Driven by build_windows.sh — the host script does the heavy lifting
; (CMake build via Docker, gather DLLs into release_artifacts/windows/bin)
; and then invokes `makensis -DSTAGING=<dir> -DVERSION=<v> -DOUTFILE=<path>
; installer/kroko-onnx-websocket-server.nsi`.
;
; What this installer does:
;   - Drops kroko-onnx-online-websocket-server.exe + all bundled DLLs
;     into  %ProgramFiles%\Kroko ONNX WebSocket Server\
;   - Creates Start Menu shortcut "Kroko ONNX WebSocket Server"
;   - Writes an uninstaller and registry uninstall entry
;   - Optional firewall rule for the server's listen port (off by default)
;
; Built for x86_64 Windows. Signed in a separate pass by sign_windows.sh.
; =============================================================================

!ifndef VERSION
  !define VERSION "0.0.0"
!endif

!ifndef STAGING
  !error "STAGING not set. Pass -DSTAGING=path/to/bin to makensis."
!endif

!ifndef OUTFILE
  !define OUTFILE "kroko-onnx-websocket-server-${VERSION}-setup.exe"
!endif

Unicode true
SetCompressor /SOLID lzma

Name "Kroko ONNX WebSocket Server ${VERSION}"
OutFile "${OUTFILE}"
InstallDir "$PROGRAMFILES64\Kroko ONNX WebSocket Server"
InstallDirRegKey HKLM "Software\Kroko ONNX WebSocket Server" "InstallDir"
RequestExecutionLevel admin

VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "Kroko ONNX WebSocket Server"
VIAddVersionKey "FileDescription" "Kroko ONNX Online WebSocket Server"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "CompanyName" "Kroko AI"
VIAddVersionKey "LegalCopyright" "(c) Kroko AI. Licensed under Apache 2.0."

!include "MUI2.nsh"
!include "FileFunc.nsh"

!define MUI_ABORTWARNING
; A real .ico goes here once we have one. Until then NSIS ships a default.
; !define MUI_ICON   "icon.ico"
; !define MUI_UNICON "icon.ico"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "..\LICENSE"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_WELCOME
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH

!insertmacro MUI_LANGUAGE "English"

Section "Server (required)" SecServer
  SectionIn RO  ; required, cannot be unchecked

  SetOutPath "$INSTDIR"
  ; Pull every file the host build_windows.sh staged into release_artifacts/
  ; windows/bin (exe, sherpa DLLs, onnxruntime.dll, vc_redist.x64.exe, ...).
  File /r "${STAGING}\*.*"

  ; Chain-install Microsoft's Visual C++ Redistributable. Server is
  ; linked with /MD (dynamic CRT) and won't launch without vcruntime140 +
  ; msvcp140 present on the system. Microsoft's installer is the
  ; supported way to deploy these DLLs — modern vc_redist.x64.exe is a
  ; WiX/Burn bundle whose internal MSI can't be cleanly unpacked into
  ; loose DLLs at build time. Silent install, no reboot prompts; safe
  ; to run if a newer version is already present (Microsoft's installer
  ; is a no-op in that case). We don't fail the install if vc_redist
  ; returns non-zero because exit code 1638 ("a newer version is already
  ; installed") is common and harmless.
  DetailPrint "Installing Microsoft Visual C++ Redistributable (this may take a moment)..."
  ExecWait '"$INSTDIR\vc_redist.x64.exe" /install /quiet /norestart' $0
  DetailPrint "vc_redist exit code: $0"
  Delete "$INSTDIR\vc_redist.x64.exe"

  ; Registry entries (Add/Remove Programs)
  WriteRegStr HKLM "Software\Kroko ONNX WebSocket Server" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "Software\Kroko ONNX WebSocket Server" "Version" "${VERSION}"

  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\KrokoOnnxWebSocketServer" \
      "DisplayName" "Kroko ONNX WebSocket Server"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\KrokoOnnxWebSocketServer" \
      "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\KrokoOnnxWebSocketServer" \
      "Publisher" "Kroko AI"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\KrokoOnnxWebSocketServer" \
      "UninstallString" "$\"$INSTDIR\Uninstall.exe$\""
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\KrokoOnnxWebSocketServer" \
      "InstallLocation" "$\"$INSTDIR$\""
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\KrokoOnnxWebSocketServer" \
      "NoModify" 1
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\KrokoOnnxWebSocketServer" \
      "NoRepair" 1

  ; Report install size in Add/Remove Programs.
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\KrokoOnnxWebSocketServer" \
      "EstimatedSize" "$0"

  WriteUninstaller "$INSTDIR\Uninstall.exe"
SectionEnd

Section "Start Menu shortcut" SecShortcut
  CreateDirectory "$SMPROGRAMS\Kroko"
  CreateShortcut "$SMPROGRAMS\Kroko\Kroko ONNX WebSocket Server.lnk" \
      "$INSTDIR\kroko-onnx-online-websocket-server.exe" \
      "" "$INSTDIR\kroko-onnx-online-websocket-server.exe" 0
SectionEnd

Section /o "Allow inbound port 6006 (Windows Firewall)" SecFirewall
  ; Off by default — the user picks a port at runtime; this rule is for the
  ; common case but stays opt-in. Names the rule clearly so it's easy to
  ; remove via Windows settings.
  ExecWait 'netsh advfirewall firewall add rule name="Kroko ONNX WebSocket Server" dir=in action=allow protocol=TCP localport=6006 program="$INSTDIR\kroko-onnx-online-websocket-server.exe"'
SectionEnd

; MUI_DESCRIPTION_TEXT macros require a MUI_PAGE_COMPONENTS page in the
; page list to actually render. We don't include that page (the install
; is simple enough that listing components confuses more than it helps),
; so the descriptions would be dead code. Dropping them silences the
; "unknown variable mui.ComponentsPage.DescriptionText" warnings makensis
; emits when the macros are present without the page.

Section "Uninstall"
  ; Best-effort firewall rule cleanup; ignore errors if the rule wasn't created.
  ExecWait 'netsh advfirewall firewall delete rule name="Kroko ONNX WebSocket Server"'

  Delete "$SMPROGRAMS\Kroko\Kroko ONNX WebSocket Server.lnk"
  RMDir  "$SMPROGRAMS\Kroko"

  ; Nuke the install dir. SetOutPath up the tree first so we're not deleting
  ; our own CWD on Vista+.
  SetOutPath "$TEMP"
  RMDir /r "$INSTDIR"

  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\KrokoOnnxWebSocketServer"
  DeleteRegKey HKLM "Software\Kroko ONNX WebSocket Server"
SectionEnd
