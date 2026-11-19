; Loomi for Windows — installer (Inno Setup 6.5+). Built by .github/workflows/release.yml:
;   iscc /DAppVersion=0.1.0 /DSourceDir=<Release folder> loomi.iss
; Everything the app needs (Flutter engine, plugins, Visual C++ runtime) is inside —
; nothing else has to be installed. Dark "aurora" look matching the Loomi apps.
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
AppVerName=Loomi {#AppVersion}
AppPublisher=Loomi
AppPublisherURL=https://github.com/borhanslm/loomi
AppSupportURL=https://github.com/borhanslm/loomi/issues
AppCopyright=Copyright (C) 2026 Loomi — AGPL-3.0
VersionInfoDescription=Loomi installer
DefaultDirName={autopf}\Loomi
DefaultGroupName=Loomi
DisableProgramGroupPage=yes
DisableReadyPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputBaseFilename=Loomi-Setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\loomi.exe
UninstallDisplayName=Loomi
Compression=lzma2/ultra64
SolidCompression=yes
LicenseFile=..\..\..\LICENSE
CloseApplications=yes

; ── look: dark aurora ─────────────────────────────────────────────
WizardStyle=modern dark includetitlebar hidebevels
WizardSizePercent=110
WizardBackColor=#0B0A1C
WizardBackImageFile=back-596.png,back-994.png,back-1272.png
WizardImageFile=side-246.png,side-410.png
WizardImageBackColor=#0B0A1C
WizardSmallImageFile=small-58.png,small-116.png
WizardSmallImageBackColor=#0B0A1C

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"

[Messages]
WelcomeLabel1=Meet Loomi
WelcomeLabel2=Your second brain is a few clicks away.%n%nLoomi remembers your ideas, tasks and plans, reminds you at the right time, and helps you get things done — on your own server, with the AI you choose.%n%nEverything Loomi needs is included. Nothing else to install.
FinishedHeadingLabel=Loomi is ready ✦
FinishedLabel=Open Loomi and pair it with your server: in your Loomi admin panel, go to Devices → Pair a new device, then enter the code.%n%nNo server yet? One line installs it — see github.com/borhanslm/loomi
ClickFinish=Click Finish to start.
SelectTasksDesc=A couple of small choices.
StatusExtractFiles=Weaving the threads together…

[Tasks]
Name: "desktopicon"; Description: "Put Loomi on my desktop"; GroupDescription: "Shortcuts:"
Name: "autostart"; Description: "Start Loomi when I sign in to Windows (so reminders are always on)"; GroupDescription: "Startup:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Loomi"; Filename: "{app}\loomi.exe"; Comment: "Your second brain"
Name: "{group}\Uninstall Loomi"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Loomi"; Filename: "{app}\loomi.exe"; Comment: "Your second brain"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Loomi"; ValueData: """{app}\loomi.exe"""; Flags: uninsdeletevalue; Tasks: autostart

[Run]
Filename: "{app}\loomi.exe"; Description: "Open Loomi now"; Flags: nowait postinstall skipifsilent
; In-app updates run this installer silently — open Loomi again afterwards.
Filename: "{app}\loomi.exe"; Flags: nowait; Check: WizardSilent

[Code]
// Friendly notes that change as the installation progresses.
var
  Tips: array of String;

procedure InitializeWizard;
begin
  SetArrayLength(Tips, 5);
  Tips[0] := 'Loomi keeps your data on your own server — not ours.';
  Tips[1] := 'Pick any AI you like: Claude, ChatGPT, Gemini, DeepSeek, or a local model.';
  Tips[2] := 'Say it once. Loomi turns it into a task, a reminder, or an idea.';
  Tips[3] := 'Sensitive actions always wait for your approval.';
  Tips[4] := 'Loomi is free and open source (AGPL-3.0).';
end;

procedure CurInstallProgressChanged(CurProgress, MaxProgress: Integer);
var
  i: Integer;
begin
  if MaxProgress <= 0 then exit;
  i := (CurProgress * GetArrayLength(Tips)) div (MaxProgress + 1);
  WizardForm.StatusLabel.Caption := Tips[i];
end;
