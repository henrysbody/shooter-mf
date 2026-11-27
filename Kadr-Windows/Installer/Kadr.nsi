Unicode true
RequestExecutionLevel user
SetCompressor zlib

!include "MUI2.nsh"
!include "x64.nsh"

!ifndef APP_VERSION
  !error "Pass APP_VERSION to makensis."
!endif
!ifndef X64_EXE
  !error "Pass X64_EXE to makensis."
!endif
!ifndef ARM64_EXE
  !error "Pass ARM64_EXE to makensis."
!endif
!ifndef LICENSE_DIR
  !error "Pass LICENSE_DIR to makensis."
!endif
!ifndef SETUP_EXE
  !define SETUP_EXE "Shooter MF-Windows-Setup.exe"
!endif

!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Kadr"
!define DISPLAY_NAME "Shooter MF"
!define RUN_KEY "Software\Microsoft\Windows\CurrentVersion\Run"
!define STARTUP_VALUE "Kadr"
!define APP_COMMAND '$\"$INSTDIR\Shooter MF.exe$\"'
!define LEGACY_COMMAND '$\"$INSTDIR\Kadr.exe$\"'
!define APP_MUTEX "Local\Kadr.Screenshot.Editor"

Name "Shooter MF"
Caption "Установка Shooter MF"
OutFile "${SETUP_EXE}"
InstallDir "$LOCALAPPDATA\Programs\Shooter MF"
BrandingText "Shooter MF ${APP_VERSION}"

!define MUI_ICON "../Kadr.ico"
!define MUI_UNICON "../Kadr.ico"
!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TITLE "Установка Shooter MF"
!define MUI_WELCOMEPAGE_TEXT "Shooter MF устанавливается для текущего пользователя.$\r$\n$\r$\nДля захвата экрана нажмите Alt+Shift+S."
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES

!define MUI_FINISHPAGE_TITLE "Shooter MF установлен"
!define MUI_FINISHPAGE_TEXT "Выберите, когда запускать Shooter MF."
!define MUI_FINISHPAGE_NOREBOOTSUPPORT
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_TEXT "Запускать Shooter MF при входе в Windows"
!define MUI_FINISHPAGE_RUN_FUNCTION EnableStartup
!define MUI_FINISHPAGE_SHOWREADME
!define MUI_FINISHPAGE_SHOWREADME_TEXT "Запустить Shooter MF после установки"
!define MUI_FINISHPAGE_SHOWREADME_FUNCTION LaunchKadr
!define MUI_PAGE_CUSTOMFUNCTION_SHOW SetFinishDefaults
!define MUI_PAGE_CUSTOMFUNCTION_LEAVE ApplyStartupOptOut
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "Russian"

VIProductVersion "${APP_VERSION}.0"
VIAddVersionKey /LANG=${LANG_RUSSIAN} "FileDescription" "Установщик Shooter MF"
VIAddVersionKey /LANG=${LANG_RUSSIAN} "ProductName" "Shooter MF"
VIAddVersionKey /LANG=${LANG_RUSSIAN} "ProductVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=${LANG_RUSSIAN} "FileVersion" "${APP_VERSION}.0"
VIAddVersionKey /LANG=${LANG_RUSSIAN} "LegalCopyright" "© 2026 Shooter MF"

Var IsArm64
Var StartupDefault
Var PreviousInstallDir

Function .onInit
  SetShellVarContext current
  ${If} ${IsNativeARM64}
    StrCpy $IsArm64 1
  ${ElseIf} ${IsNativeAMD64}
    StrCpy $IsArm64 0
  ${Else}
    MessageBox MB_OK|MB_ICONSTOP "Эта версия Shooter MF предназначена для Windows x64 и ARM64." /SD IDOK
    SetErrorLevel 1
    Quit
  ${EndIf}
  SetRegView 64
  StrCpy $StartupDefault ${BST_CHECKED}
  ReadRegStr $PreviousInstallDir HKCU "${UNINSTALL_KEY}" "InstallLocation"
  ${If} $PreviousInstallDir != ""
    StrCpy $INSTDIR $PreviousInstallDir
    ReadRegStr $0 HKCU "${RUN_KEY}" "${STARTUP_VALUE}"
    ${If} $0 != "${APP_COMMAND}"
    ${AndIf} $0 != "${LEGACY_COMMAND}"
      StrCpy $StartupDefault ${BST_UNCHECKED}
    ${EndIf}
  ${EndIf}
FunctionEnd

Function SetFinishDefaults
  ${NSD_SetState} $mui.FinishPage.Run $StartupDefault
FunctionEnd

Function EnableStartup
  ClearErrors
  WriteRegStr HKCU "${RUN_KEY}" "${STARTUP_VALUE}" "${APP_COMMAND}"
  ${If} ${Errors}
    MessageBox MB_OK|MB_ICONEXCLAMATION "Не удалось включить запуск Shooter MF при входе в Windows." /SD IDOK
    SetErrorLevel 1
  ${EndIf}
FunctionEnd

Function ApplyStartupOptOut
  ${NSD_GetState} $mui.FinishPage.Run $0
  ${If} $0 == ${BST_UNCHECKED}
    ReadRegStr $0 HKCU "${RUN_KEY}" "${STARTUP_VALUE}"
    ${If} $0 == "${APP_COMMAND}"
      DeleteRegValue HKCU "${RUN_KEY}" "${STARTUP_VALUE}"
    ${EndIf}
  ${EndIf}
FunctionEnd

Function LaunchKadr
  ClearErrors
  Exec "${APP_COMMAND}"
  ${If} ${Errors}
    MessageBox MB_OK|MB_ICONEXCLAMATION "Не удалось запустить Shooter MF. Откройте его из меню «Пуск»." /SD IDOK
    SetErrorLevel 1
  ${EndIf}
FunctionEnd

!macro WaitForKadrToClose FUNCTION_NAME
  Function ${FUNCTION_NAME}
  retry:
    System::Call 'kernel32::OpenMutexW(i 0x00100000, i 0, w "${APP_MUTEX}") p.r0'
    ${If} $0 != 0
      System::Call 'kernel32::CloseHandle(p r0)'
      MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "Shooter MF уже запущен. Завершите его через значок в области уведомлений и нажмите «Повторить»." /SD IDCANCEL IDRETRY retry
      SetErrorLevel 2
      Quit
    ${EndIf}
  FunctionEnd
!macroend
!insertmacro WaitForKadrToClose EnsureKadrStopped
!insertmacro WaitForKadrToClose un.EnsureKadrStopped

Section "Shooter MF"
  Call EnsureKadrStopped
  SetOverwrite on
  ClearErrors
  SetOutPath "$INSTDIR"
  ${If} $IsArm64 == 1
    File "/oname=Shooter MF.exe" "${ARM64_EXE}"
  ${Else}
    File "/oname=Shooter MF.exe" "${X64_EXE}"
  ${EndIf}
  IfErrors install_failed
  SetOutPath "$INSTDIR\Licenses"
  File "${LICENSE_DIR}/dotnet-license.txt"
  File "${LICENSE_DIR}/dotnet-third-party-notices.txt"
  File "${LICENSE_DIR}/windowsdesktop-license.txt"
  File "${LICENSE_DIR}/Geologica-OFL.txt"
  IfErrors install_failed

  SetOutPath "$INSTDIR"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateShortCut "$SMPROGRAMS\Shooter MF.lnk" "$INSTDIR\Shooter MF.exe"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "${DISPLAY_NAME}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "${DISPLAY_NAME}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "${APP_COMMAND}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '$\"$INSTDIR\Uninstall.exe$\" /S'
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "SystemComponent" 0
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
  IfErrors install_failed
  ReadRegStr $0 HKCU "${UNINSTALL_KEY}" "DisplayName"
  ${If} $0 != "${DISPLAY_NAME}"
    Goto install_failed
  ${EndIf}

  ${If} $PreviousInstallDir != ""
    ReadRegStr $0 HKCU "${RUN_KEY}" "${STARTUP_VALUE}"
    ${If} $0 == "${LEGACY_COMMAND}"
      Call EnableStartup
    ${EndIf}
    Delete "$SMPROGRAMS\Кадр.lnk"
    Delete "$INSTDIR\Kadr.exe"
  ${EndIf}

  ${If} ${Silent}
  ${AndIf} $StartupDefault == ${BST_CHECKED}
    Call EnableStartup
  ${EndIf}
  Goto install_done

  install_failed:
    MessageBox MB_OK|MB_ICONSTOP "Не удалось завершить установку Shooter MF." /SD IDOK
    SetErrorLevel 1
    Quit
  install_done:
SectionEnd

Function un.onInit
  SetShellVarContext current
  SetRegView 64
FunctionEnd

Section "Uninstall"
  Call un.EnsureKadrStopped
  ClearErrors
  Delete "$INSTDIR\Shooter MF.exe"
  IfErrors remove_failed
  ReadRegStr $0 HKCU "${RUN_KEY}" "${STARTUP_VALUE}"
  ${If} $0 == "${APP_COMMAND}"
    DeleteRegValue HKCU "${RUN_KEY}" "${STARTUP_VALUE}"
  ${EndIf}
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
  Delete "$SMPROGRAMS\Shooter MF.lnk"
  Delete "$INSTDIR\Licenses\dotnet-license.txt"
  Delete "$INSTDIR\Licenses\dotnet-third-party-notices.txt"
  Delete "$INSTDIR\Licenses\windowsdesktop-license.txt"
  Delete "$INSTDIR\Licenses\Geologica-OFL.txt"
  RMDir "$INSTDIR\Licenses"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Goto remove_done

  remove_failed:
    MessageBox MB_OK|MB_ICONSTOP "Не удалось удалить Shooter MF." /SD IDOK
    SetErrorLevel 1
    Quit
  remove_done:
SectionEnd
