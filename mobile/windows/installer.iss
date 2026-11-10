; Windows installer for UZARO (Inno Setup 6). Per-user install, no admin rights needed.
; Build: flutter build windows --release --dart-define=TG_API_ID=... --dart-define=TG_API_HASH=...
;        ISCC.exe windows\installer.iss   (run from mobile/)
; Output: build\windows\installer\UZARO-Setup-<version>.exe

#define AppName "UZARO"
; Pass the pubspec version: ISCC.exe /DAppVersion=1.1.6 windows\installer.iss
#ifndef AppVersion
  #define AppVersion "1.1.6"
#endif
#define AppExe "UZARO.exe"
#define BuildDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{6F1C2B9E-4A7D-4C3E-9B1A-5D2E8F0A7C31}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppName}
AppPublisherURL=https://uzaromessenger.uz/
AppSupportURL=https://uzaromessenger.uz/docs.html
AppUpdatesURL=https://uzaromessenger.uz/
VersionInfoVersion={#AppVersion}
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} Setup
; Windows 10 or later; a running UZARO is closed before files are replaced and restarted afterwards.
MinVersion=10.0
CloseApplications=yes
RestartApplications=yes
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\build\windows\installer
OutputBaseFilename=UZARO-Setup-{#AppVersion}
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[InstallDelete]
; Builds before 1.1.5 shipped the executable as sado.exe.
Type: files; Name: "{app}\sado.exe"

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
