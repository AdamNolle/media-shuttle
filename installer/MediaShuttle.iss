#ifndef SourceDir
  #error SourceDir must point to the published application directory.
#endif
#ifndef OutputDir
  #error OutputDir must point to the artifact output directory.
#endif
#ifndef AppVersion
  #error AppVersion must contain the application version.
#endif

#define AppName "Media Shuttle"
#define AppExeName "MediaShuttle.exe"
#define AppPublisher "Media Shuttle"

[Setup]
AppId={{8BC1B22A-BBC3-4C4B-AB84-F23F4FA34E1A}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\Programs\Media Shuttle
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename=MediaShuttle-Setup-v{#AppVersion}-win-x64
SetupIconFile={#SourceDir}\Assets\MediaShuttle.ico
UninstallDisplayIcon={app}\{#AppExeName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
VersionInfoVersion={#AppVersion}.0
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} installer
VersionInfoCompany={#AppPublisher}

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"
Name: "startup"; Description: "Start Media Shuttle when I sign in"; GroupDescription: "Startup:"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Media Shuttle"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"
Name: "{autodesktop}\Media Shuttle"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon
Name: "{userstartup}\Media Shuttle"; Filename: "{app}\{#AppExeName}"; Parameters: "--background"; WorkingDir: "{app}"; Tasks: startup

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch Media Shuttle"; Flags: nowait postinstall skipifsilent
