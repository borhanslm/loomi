; Loomi for Windows — installer (Inno Setup 6). Built by .github/workflows/release.yml:
;   iscc /DAppVersion=0.1.0 /DSourceDir=<Release folder> loomi.iss
; Everything the app needs (Flutter engine, plugins, and the Visual C++ runtime DLLs)
; is inside, so nothing else has to be installed.
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{6D5BD0A1-4C6F-4F3B-9E1A-10A7B1E5C0DE}
AppName=Loomi
AppVersion={#AppVersion}
AppPublisher=Loomi
AppPublisherURL=https://github.com/borhanslm/loomi
AppSupportURL=https://github.com/borhanslm/loomi/issues
DefaultDirName={autopf}\Loomi
DefaultGroupName=Loomi
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputBaseFilename=Loomi-Setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\loomi.exe
LicenseFile=..\..\..\LICENSE
CloseApplications=yes

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "autostart"; Description: "Start Loomi when Windows starts"; GroupDescription: "Options:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Loomi"; Filename: "{app}\loomi.exe"
Name: "{group}\Uninstall Loomi"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Loomi"; Filename: "{app}\loomi.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Loomi"; ValueData: """{app}\loomi.exe"""; Flags: uninsdeletevalue; Tasks: autostart

[Run]
Filename: "{app}\loomi.exe"; Description: "{cm:LaunchProgram,Loomi}"; Flags: nowait postinstall skipifsilent
