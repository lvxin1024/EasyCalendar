#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef BuildDir
  #define BuildDir "..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{6A85E13C-36C8-49CE-A95D-ECA4A07C8D55}
AppName=EasyCalendar
AppVersion={#AppVersion}
AppPublisher=lvxin1024
AppPublisherURL=https://github.com/lvxin1024/EasyCalendar
DefaultDirName={localappdata}\Programs\EasyCalendar
DefaultGroupName=EasyCalendar
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=build\release
OutputBaseFilename=EasyCalendar-{#AppVersion}-windows-x64-setup
SetupIconFile=runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
UninstallDisplayIcon={app}\EasyCalendar.exe

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\EasyCalendar"; Filename: "{app}\EasyCalendar.exe"
Name: "{autodesktop}\EasyCalendar"; Filename: "{app}\EasyCalendar.exe"; Tasks: desktopicon

[InstallDelete]
Type: files; Name: "{app}\easy_calendar.exe"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Run]
Filename: "{app}\EasyCalendar.exe"; Description: "Launch EasyCalendar"; Flags: nowait postinstall skipifsilent
