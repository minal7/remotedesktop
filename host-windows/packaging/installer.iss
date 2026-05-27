; Inno Setup script for Remote Desktop Host (Windows).
;
; Build from this directory after `cargo build --release`:
;   iscc installer.iss                          ; uses default version
;   iscc /DMyAppVersion=1.2.3 installer.iss      ; override version (CI)
;
; Produces ..\dist\RemoteDesktopHost-Setup-<version>.exe
;
; Source paths are resolved relative to this .iss file.

#ifndef MyAppVersion
  #define MyAppVersion "0.1.0"
#endif

#define MyAppName "Remote Desktop Host"
#define MyAppPublisher "Threadmark"
#define MyAppURL "https://github.com/minal7/remotedesktop"
#define MyAppExeName "remote-desktop-host.exe"

[Setup]
; AppId uniquely identifies this app for upgrades/uninstall. Never change it.
AppId={{8F3A2C1E-5B4D-4E6F-9A1B-2C3D4E5F6A7B}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
; Per-user install by default (no UAC prompt); the user may elect an
; all-users install in the dialog. This matches the app's per-user
; (HKCU) launch-at-login registration.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\dist
OutputBaseFilename=RemoteDesktopHost-Setup-{#MyAppVersion}
SetupIconFile=..\assets\icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Close the app automatically if it's running during install/upgrade so
; the locked .exe can be replaced, then offer to relaunch it.
CloseApplications=yes
RestartApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\target\release\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Stop the host if it's still running so uninstall can remove the exe.
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM {#MyAppExeName}"; Flags: runhidden; RunOnceId: "StopHost"

[UninstallDelete]
; The app writes its log here; remove it on uninstall.
Type: filesandordirs; Name: "{localappdata}\RemoteDesktopHost"

[Registry]
; The app registers itself for launch-at-login under the per-user Run key
; (value "RemoteDesktopHost"). Remove that value on uninstall so Windows
; doesn't try to start a deleted executable.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "RemoteDesktopHost"; Flags: dontcreatekey uninsdeletevalue
