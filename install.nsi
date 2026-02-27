# Include Modern UI
!include "MUI2.nsh"

# アプリケーション名
Name "Catellite V2F"
# 作成されるインストーラ
OutFile "CatelliteV2F_Installer.exe"
# インストールされるディレクトリ
InstallDir "$PROGRAMFILES64\CatelliteV2F"
# 圧縮メソッド
SetCompressor lzma
# ページ
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
# アンインストーラ ページ
!insertmacro MUI_UNPAGE_WELCOME
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH

# 日本語UI
!insertmacro MUI_LANGUAGE "Japanese"

# デフォルトセクション
Section 
    # 出力先を指定
    SetOutPath "$INSTDIR"
    # インストールされるファイル
    File "CatelliteV2F.exe"
    SetOutPath "$INSTDIR\python"
    File "python\get-pip.py"
    File "python\setup_library.bat"
    File "python\setup.bat"
    File "python\requirements.txt"
    SetOutPath "$INSTDIR\src"
    File "src\convert_process.py"
    File "src\main.py"
    File "src\utils.py"
    File "src\icon.ico"
    # アンインストーラを出力
    WriteUninstaller "$INSTDIR\Uninstall.exe"
    # Setup実行
    SetOutPath "$INSTDIR\python"
    ExecWait "$INSTDIR\python\setup.bat"
    ExecWait "$INSTDIR\python\setup_library.bat"
    Delete "$INSTDIR\python\setup.bat"
    Delete "$INSTDIR\python\setup_library.bat"
    # スタートメニューに登録
    CreateDirectory "$SMPROGRAMS\CatelliteV2F"
    SetOutPath "$INSTDIR"
    CreateShortCut "$SMPROGRAMS\CatelliteV2F\CatelliteV2F.lnk" "$INSTDIR\CatelliteV2F.exe" ""
    # デスクトップにショートカット作成
    CreateShortCut "$DESKTOP\CatelliteV2F.lnk" "$INSTDIR\CatelliteV2F.exe" ""
    # レジストリに登録
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\CatelliteV2F" "DisplayName" "Catellite V2F"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\CatelliteV2F" "UninstallString" '"$INSTDIR\Uninstall.exe"'
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\CatelliteV2F" "DisplayIcon" '"$INSTDIR\src\icon.ico"'
SectionEnd

# アンインストーラ
Section "Uninstall"
    # アンインストーラ削除
    RMDir /r "$INSTDIR\*"
    # スタートメニューから削除
    RMDir /r "$SMPROGRAMS\CatelliteV2F"
    # デスクトップからショートカット削除
    Delete "$DESKTOP\CatelliteV2F.lnk"
    # レジストリ削除
    DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\CatelliteV2F"
SectionEnd

