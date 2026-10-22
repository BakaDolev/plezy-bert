[Setup]
; Fork-only additions to the setup.iss that build-installer.ps1 generates.
; build-fork-installer.ps1 includes this file at the end of that script, so
; upstream's part stays as it is. Adds Plezy's look, a short wizard
; (Welcome, options, Install, Finish) and an offer to remove the official
; Plezy, after backing up the settings both apps share.
;
; The include lands right after upstream's [Code], so this file has to open
; with a section header: a ';' line there would be read as Pascal.
;
; Paths are relative to the generated script (the repo root). The defines
; below can be set before the include, which is how this file is tested
; against a stand-in "official" app.
;
; Compiled with ForkSilent defined (build-fork-installer.ps1 does both), it is
; the silent installer, made for unattended machines such as a test VM: no
; pages or questions; the same build installed already exits at once; a newer
; one is refused (exit code 10); a copy installed for all users is left alone
; (exit code 11: updating it needs an administrator); a running Plezy is closed
; and reopened, a closed one stays closed; the official Plezy is never touched;
; and every run leaves {localappdata}\Plezy Fork\install-status.json behind.
; /UPDATECHECKS=off|on (both installers) turns Plezy's own update checks off
; or on for this user.

#ifndef OfficialAppId
  #define OfficialAppId "{4213385e-f7be-4f2b-95f9-54082a28bb8f}"
#endif
#ifndef SettingsRoaming
  #define SettingsRoaming "{userappdata}\com.edde746\Plezy"
#endif
#ifndef SettingsLocal
  #define SettingsLocal "{localappdata}\com.edde746\Plezy"
#endif
#ifndef BackupRoot
  #define BackupRoot "{localappdata}\Plezy Fork backups"
#endif
; The update-checks switch and the silent installer's status file.
#ifndef ForkDataDir
  #define ForkDataDir "{localappdata}\Plezy Fork"
#endif
#ifndef ForkExeSource
  #define ForkExeSource AddBackslash(SourcePath) + "staging\x64\" + ExeName
#endif

; The build number sits in the exe's file version (Flutter writes x.y.z.<build>);
; the version people see is the fork's own, without it.
#define ExeMajor 0
#define ExeMinor 0
#define ExeRevision 0
#define ExeBuild 0
#if GetVersionComponents(ForkExeSource, ExeMajor, ExeMinor, ExeRevision, ExeBuild) == ""
  #error Could not read the build number from the file version of {#ForkExeSource}
#endif

SetupIconFile=windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#ExeName}
WizardImageFile=windows\installer\wizard-light-*.png
WizardImageFileDynamicDark=windows\installer\wizard-dark-*.png
WizardSmallImageFile=windows\installer\wizard-small-*.png
; Dynamic dark mode swaps in Inno's own small image unless told otherwise.
WizardSmallImageFileDynamicDark=windows\installer\wizard-small-*.png
#ifdef ForkSilent
; Double-clicked, only the progress bar shows. Plezy is closed by the script
; below, not by Setup's own question on the Preparing page.
DisableWelcomePage=yes
DisableFinishedPage=yes
CloseApplications=no
SetupLogging=yes
#else
DisableWelcomePage=no
#endif
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes

[Messages]
WelcomeLabel2=This will install [name/ver] on your computer.%n%nIf Plezy was used on this computer before, your sign-in and settings carry over.

#ifndef ForkSilent
[Tasks]
Name: "removeofficial"; Description: "Remove the official Plezy (your settings stay, and a copy is saved first)"; GroupDescription: "Official Plezy:"; Check: OfficialPlezyFound
#endif

; WinSparkle's own scheduler stays off: Plezy decides when to look for
; updates. The key is built from the exe's CompanyName + ProductName (shared
; with the official app, which leaves CheckForUpdates at "1"). WinSparkle only
; reads string values; DidRunOnce skips its "check automatically?" question.
[Registry]
Root: HKCU; Subkey: "Software\com.edde746\Plezy\WinSparkle"; ValueType: string; ValueName: "CheckForUpdates"; ValueData: "0"
Root: HKCU; Subkey: "Software\com.edde746\Plezy\WinSparkle"; ValueType: string; ValueName: "DidRunOnce"; ValueData: "1"

[Code]
const
  OfficialUninstallSubkey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{#OfficialAppId}_is1';

var
  SettingsBackupDir: String;
  OfficialRemoved: Boolean;

{ A value from the official Plezy's uninstall entry, or '' when it has none.
  Like this app, it can be registered per-user or machine-wide. }
function OfficialValue(const Name: String): String;
begin
  if not RegQueryStringValue(HKCU, OfficialUninstallSubkey, Name, Result) then
    if not RegQueryStringValue(HKLM, OfficialUninstallSubkey, Name, Result) then
      Result := '';
end;

function OfficialUninstaller: String;
begin
  Result := RemoveQuotes(OfficialValue('UninstallString'));
  if (Result <> '') and not FileExists(Result) then
    Result := '';
end;

function OfficialPlezyFound: Boolean;
begin
  Result := OfficialUninstaller <> '';
end;

{ A silent run (the updater) never removes anything unless its command line
  names the task, even when an earlier run left the task selected. The silent
  installer has no such task at all. }
function RemoveOfficialWanted: Boolean;
begin
#ifdef ForkSilent
  Result := False;
#else
  Result := WizardIsTaskSelected('removeofficial') and
    ((not WizardSilent) or (Pos('removeofficial', Lowercase(ExpandConstant('{param:TASKS|}'))) > 0));
#endif
end;

{ Plezy skips its own update checks while this file exists (a test VM gets
  its updates from the silent installer instead, and an offer must never pop
  up mid-test). Per user, like the install. }
function UpdateChecksMarker: String;
begin
  Result := ExpandConstant('{#ForkDataDir}\update-checks-off');
end;

procedure ApplyUpdateChecksParam;
var
  Wanted: String;
begin
  Wanted := Lowercase(ExpandConstant('{param:UPDATECHECKS|}'));
  if Wanted = 'off' then
  begin
    ForceDirectories(ExtractFileDir(UpdateChecksMarker));
    if SaveStringToFile(UpdateChecksMarker, 'Plezy''s own update checks are off for this user ' +
         '(installer /UPDATECHECKS=off; /UPDATECHECKS=on or deleting this file turns them back on).' + #13#10, False) then
      Log('Update checks turned off')
    else
      Log('Could not write ' + UpdateChecksMarker);
  end
  else if (Wanted = 'on') and DeleteFile(UpdateChecksMarker) then
    Log('Update checks turned on');
end;

function UpdateChecksState: String;
begin
  if FileExists(UpdateChecksMarker) then
    Result := 'off'
  else
    Result := 'on';
end;

{ The launch entry's extra condition (build-installer.ps1 -LaunchCheck): the
  silent installer reopens Plezy itself, and only when it was open. }
function ForkLaunchAfterInstall: Boolean;
begin
#ifdef ForkSilent
  Result := False;
#else
  Result := True;
#endif
end;

{ A value from the installed copy's uninstall entry ('' when there is none),
  per-user or machine-wide. }
function InstalledValue(const Name: String): String;
var
  Subkey: String;
begin
  Subkey := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' +
    ExpandConstant('{#SetupSetting("AppId")}') + '_is1';
  if not RegQueryStringValue(HKCU, Subkey, Name, Result) then
    if not RegQueryStringValue(HKLM, Subkey, Name, Result) then
      Result := '';
end;

{ The installed copy's build number, from its exe's file version, or -1 when
  there is no installed copy or it can't be read. }
function InstalledBuild: Integer;
var
  Dir: String;
  Major, Minor, Revision, Build: Word;
begin
  Result := -1;
  Dir := InstalledValue('Inno Setup: App Path');
  if (Dir <> '') and GetVersionComponents(AddBackslash(Dir) + '{#ExeName}', Major, Minor, Revision, Build) then
    Result := Build;
end;

#ifdef ForkSilent
{ The silent installer's record of each run, for whatever started it (a test
  VM's robot): install-status.json in %LOCALAPPDATA%\Plezy Fork, always
  written whole (a temp file renamed over it). result: running, then
  installed, current (this build was there already), refused (a newer one is)
  or failed. Exit codes: 0 installed or current, 10 refused, 11 needs an
  administrator, any other failed. }
const
  MOVEFILE_REPLACE_EXISTING = 1;
  MOVEFILE_WRITE_THROUGH = 8;
  ExitRefused = 10;
  ExitNeedsAdmin = 11;

function MoveFileEx(lpExistingFileName, lpNewFileName: String; dwFlags: Cardinal): Boolean;
  external 'MoveFileExW@kernel32 stdcall';
function GetCurrentProcessId: Cardinal;
  external 'GetCurrentProcessId@kernel32 stdcall';
procedure ExitProcess(uExitCode: Cardinal);
  external 'ExitProcess@kernel32 stdcall';

var
  RunId, StartedAt, FromVersion: String;
  FromBuild: Integer;
  PlezyWasOpen, PlezyReopened, StatusDone: Boolean;

function StatusPath: String;
begin
  Result := ExpandConstant('{#ForkDataDir}\install-status.json');
end;

function LocalNow: String;
begin
  Result := GetDateTimeString('yyyy/mm/dd"T"hh:nn:ss', '-', ':');
end;

function JsonText(const S: String): String;
var
  I: Integer;
begin
  Result := '"';
  for I := 1 to Length(S) do
    if (S[I] = '"') or (S[I] = '\') then
      Result := Result + '\' + S[I]
    else if Ord(S[I]) >= 32 then
      Result := Result + S[I];
  Result := Result + '"';
end;

function JsonTextOrNull(const S: String): String;
begin
  if S = '' then
    Result := 'null'
  else
    Result := JsonText(S);
end;

function JsonBool(B: Boolean): String;
begin
  if B then
    Result := 'true'
  else
    Result := 'false';
end;

procedure WriteStatus(const State, ExitCode, Finished: String);
var
  Lines: TArrayOfString;
  FromBuildText, Tmp: String;
begin
  if FromBuild < 0 then
    FromBuildText := 'null'
  else
    FromBuildText := IntToStr(FromBuild);
  SetArrayLength(Lines, 1);
  Lines[0] := '{' + #13#10 +
    '  "run_id": ' + JsonText(RunId) + ',' + #13#10 +
    '  "result": ' + JsonText(State) + ',' + #13#10 +
    '  "exit_code": ' + ExitCode + ',' + #13#10 +
    '  "started": ' + JsonText(StartedAt) + ',' + #13#10 +
    '  "finished": ' + Finished + ',' + #13#10 +
    '  "from_version": ' + JsonTextOrNull(FromVersion) + ',' + #13#10 +
    '  "from_build": ' + FromBuildText + ',' + #13#10 +
    '  "to_version": ' + JsonText('{#SetupSetting("AppVersion")}') + ',' + #13#10 +
    '  "to_build": ' + IntToStr({#ExeBuild}) + ',' + #13#10 +
    '  "plezy_was_open": ' + JsonBool(PlezyWasOpen) + ',' + #13#10 +
    '  "reopened": ' + JsonBool(PlezyReopened) + ',' + #13#10 +
    '  "update_checks": ' + JsonText(UpdateChecksState) + ',' + #13#10 +
    '  "installer_pid": ' + IntToStr(GetCurrentProcessId) + ',' + #13#10 +
    '  "log": ' + JsonTextOrNull(ExpandConstant('{log}')) + #13#10 +
    '}';
  ForceDirectories(ExtractFileDir(StatusPath));
  Tmp := StatusPath + '.tmp';
  if not SaveStringsToUTF8FileWithoutBOM(Tmp, Lines, False) or
     not MoveFileEx(Tmp, StatusPath, MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
    Log('Could not write ' + StatusPath);
end;

{ Nothing to install: record why and leave at once with this code (Setup's
  own exit codes have no "nothing to do"). ExitProcess skips Setup's cleanup,
  so its temporary folder goes first. }
procedure FinishEarly(const State: String; Code: Integer);
begin
  Log(Format('Silent install: %s (installed build %d, this build %d)', [State, FromBuild, {#ExeBuild}]));
  StatusDone := True;
  WriteStatus(State, IntToStr(Code), JsonText(LocalNow));
  DelTree(ExpandConstant('{tmp}'), True, True, True);
  ExitProcess(Code);
end;

{ A copy installed for all users can only be updated as an administrator,
  and upstream's InitializeSetup would raise the administrator prompt for it:
  on an unattended machine nobody answers it, so the silent installer stops
  instead (exit code 11). }
procedure SilentStart;
begin
  RunId := GetDateTimeString('yyyymmdd-hhnnss', #0, #0) + '-' + IntToStr(GetCurrentProcessId);
  StartedAt := LocalNow;
  FromBuild := InstalledBuild;
  if FromBuild >= 0 then
    FromVersion := InstalledValue('DisplayVersion');
  if FromBuild = {#ExeBuild} then
    FinishEarly('current', 0)
  else if FromBuild > {#ExeBuild} then
    FinishEarly('refused', ExitRefused)
  else if not IsAdminInstallMode and (PreviousInstallDir <> '') and not PathIsWritable(PreviousInstallDir) then
    FinishEarly('failed', ExitNeedsAdmin);
  WriteStatus('running', 'null', 'null');
end;

{ ' /PID n' for each running plezy.exe of this install (never the official
  Plezy's, which has the same file name). }
function PlezyPidArgs(const ExePath: String): String;
var
  Locator, Service, Found: Variant;
  Escaped: String;
  I: Integer;
begin
  Result := '';
  Escaped := ExePath;
  StringChangeEx(Escaped, '\', '\\', True);
  StringChangeEx(Escaped, '''', '\''', True);
  try
    Locator := CreateOleObject('WbemScripting.SWbemLocator');
    Service := Locator.ConnectServer('.', 'root\CIMV2');
    Found := Service.ExecQuery('SELECT ProcessId FROM Win32_Process WHERE ExecutablePath = ''' + Escaped + '''');
    for I := 0 to Found.Count - 1 do
      Result := Result + ' /PID ' + IntToStr(Found.ItemIndex(I).ProcessId);
  except
    Log('Could not list running Plezy processes: ' + GetExceptionMessage);
  end;
end;

function WaitForPlezyToExit(const ExePath: String; Ms: Integer): Boolean;
var
  Waited: Integer;
begin
  Waited := 0;
  while (PlezyPidArgs(ExePath) <> '') and (Waited < Ms) do
  begin
    Sleep(500);
    Waited := Waited + 500;
  end;
  Result := PlezyPidArgs(ExePath) = '';
end;

{ Asks a running Plezy to close (as its window's close button would), and
  ends it after 10 s if it is still there. Never asks anyone. }
function ClosePlezy(const ExePath: String): Boolean;
var
  Pids: String;
  Code: Integer;
begin
  Pids := PlezyPidArgs(ExePath);
  Result := True;
  if Pids = '' then
    Exit;
  PlezyWasOpen := True;
  Log('Closing Plezy:' + Pids);
  Exec(ExpandConstant('{sys}\taskkill.exe'), Trim(Pids), '', SW_HIDE, ewWaitUntilTerminated, Code);
  if WaitForPlezyToExit(ExePath, 10000) then
    Exit;
  Pids := PlezyPidArgs(ExePath);
  Log('Plezy did not close within 10 s; ending it:' + Pids);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F' + Pids, '', SW_HIDE, ewWaitUntilTerminated, Code);
  Result := WaitForPlezyToExit(ExePath, 5000);
end;

<event('PrepareToInstall')>
function ForkPrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not ClosePlezy(ExpandConstant('{app}\{#ExeName}')) then
    Result := 'Plezy could not be closed, so it was not updated.';
end;

{ No page asks anything: the tasks page takes its defaults (no desktop icon),
  and the Ready page, which DisableReadyPage leaves in when it would be the
  first page shown, goes too. }
<event('ShouldSkipPage')>
function ForkShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := (PageID = wpSelectTasks) or (PageID = wpReady);
end;

<event('CurStepChanged')>
procedure ForkSilentStepChanged(CurStep: TSetupStep);
var
  Code: Integer;
begin
  if CurStep <> ssDone then
    Exit;
  if PlezyWasOpen and not IsNoRun then
    PlezyReopened := ExecAsOriginalUser(ExpandConstant('{app}\{#ExeName}'), '', ExpandConstant('{app}'),
      SW_SHOWNORMAL, ewNoWait, Code);
  Log(Format('Silent install: installed build %d; Plezy reopened: %d', [{#ExeBuild}, Ord(PlezyReopened)]));
  StatusDone := True;
  WriteStatus('installed', '0', JsonText(LocalNow));
end;

{ Setup's own failures (exit codes 1-8) end here without a word to the
  script: record them as failed. }
<event('DeinitializeSetup')>
procedure ForkSilentDeinitializeSetup;
begin
  if (RunId <> '') and not StatusDone then
    WriteStatus('failed', 'null', JsonText(LocalNow));
end;
#endif

{ An older build over a newer one asks first, No by default, so a run with
  /SUPPRESSMSGBOXES (the updater's) never downgrades; the updater only ever
  offers a higher build anyway. The elevated copy upstream's InitializeSetup
  may start has already been through this. }
<event('InitializeSetup')>
function ForkInitializeSetup: Boolean;
var
  Installed: String;
  OldBuild: Integer;
begin
  Result := True;
  ApplyUpdateChecksParam;
#ifdef ForkSilent
  SilentStart;
  Exit;
#endif
  if ExpandConstant('{param:ELEVATED|0}') = '1' then
    Exit;
  OldBuild := InstalledBuild;
  if (OldBuild < 0) or ({#ExeBuild} >= OldBuild) then
    Exit;
  Installed := InstalledValue('DisplayVersion');
  Log(Format('Installed build %d is newer than this one (%d)', [OldBuild, {#ExeBuild}]));
  Result := SuppressibleMsgBox('A newer {#Title} (' + Installed + ') is installed. Install this older one (' +
    '{#SetupSetting("AppVersion")}) anyway?' + #13#10#13#10 +
    'Your settings are kept, but an older build can''t always read what a newer one saved.',
    mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDNO) = IDYES;
  if not Result then
    Log('Not installing an older build');
end;

function IsRunningFrom(const ExePath: String): Boolean;
var
  Locator, Service, Found: Variant;
  Escaped: String;
begin
  Result := False;
  Escaped := ExePath;
  StringChangeEx(Escaped, '\', '\\', True);
  StringChangeEx(Escaped, '''', '\''', True);
  try
    Locator := CreateOleObject('WbemScripting.SWbemLocator');
    Service := Locator.ConnectServer('.', 'root\CIMV2');
    Found := Service.ExecQuery('SELECT ProcessId FROM Win32_Process WHERE ExecutablePath = ''' + Escaped + '''');
    Result := Found.Count > 0;
  except
    Log('Could not check for a running official Plezy: ' + GetExceptionMessage);
  end;
end;

function CopyFolder(const Source, Dest: String): Boolean;
var
  Code: Integer;
begin
  Result := True;
  if not DirExists(Source) then
    Exit;
  { robocopy exit codes below 8 mean success. The poster cache is most of the
    local folder and worth nothing in a backup; lock files are held open by a
    running Plezy. }
  Result := Exec(ExpandConstant('{sys}\robocopy.exe'),
    '"' + RemoveBackslashUnlessRoot(Source) + '" "' + RemoveBackslashUnlessRoot(Dest) + '" /E /R:1 /W:1 /NP /NFL /NDL /NJH /NJS' +
    ' /XD cached_network_image_ce /XF *.lock',
    '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code < 8);
end;

function BackUpSettings: Boolean;
begin
  SettingsBackupDir := ExpandConstant('{#BackupRoot}') + '\' + GetDateTimeString('yyyy/mm/dd hh:nn:ss', '-', '.');
  Result := CopyFolder(ExpandConstant('{#SettingsRoaming}'), SettingsBackupDir + '\Roaming') and
    CopyFolder(ExpandConstant('{#SettingsLocal}'), SettingsBackupDir + '\Local');
  if Result then
    Log('Settings backed up to ' + SettingsBackupDir)
  else
    Log('Settings backup failed');
end;

procedure RemoveOfficial;
var
  Uninstaller: String;
  Code: Integer;
begin
  Uninstaller := OfficialUninstaller;
  { ShellExec rather than Exec: a machine-wide copy's uninstaller needs to
    raise the administrator prompt itself. }
  if ShellExec('', Uninstaller, '/VERYSILENT /NORESTART', '', SW_SHOW, ewWaitUntilTerminated, Code) then
    Log(Format('Official Plezy uninstaller exited with %d', [Code]))
  else
    Log(Format('Official Plezy uninstaller did not start: %d', [Code]));
  OfficialRemoved := not OfficialPlezyFound;
  if not OfficialRemoved then
    SuppressibleMsgBox('The official Plezy could not be removed. {#Title} will still be installed; ' +
      'you can remove the official one from Settings > Apps.', mbError, MB_OK, IDOK);
end;

<event('NextButtonClick')>
function ForkNextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
#ifndef ForkSilent
  { NextButtonClick runs in silent installs too, and False there makes Setup
    exit: an update must never stop on this check. }
  if WizardSilent then
    Exit;
  if (CurPageID = wpSelectTasks) and WizardIsTaskSelected('removeofficial') and
     IsRunningFrom(AddBackslash(OfficialValue('Inno Setup: App Path')) + '{#ExeName}') then
  begin
    MsgBox('The official Plezy is running. Close it, then click Install again.', mbInformation, MB_OK);
    Result := False;
  end;
#endif
end;

{ At ssInstall, Setup has already closed a running Plezy (the Preparing page),
  so its files are free to copy. A failed backup never blocks the install; it
  only keeps the official Plezy in place. }
<event('CurStepChanged')>
procedure ForkCurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep <> ssInstall) or not RemoveOfficialWanted then
    Exit;
  if BackUpSettings then
    RemoveOfficial
  else
    SuppressibleMsgBox('Your Plezy settings could not be backed up, so the official Plezy was left in place. ' +
      '{#Title} will still be installed; you can remove the official one from Settings > Apps.', mbError, MB_OK, IDOK);
end;

{ With the Ready page hidden, the options page is the last one before
  installing, so its button has to say so (Inno leaves that to the script). }
<event('CurPageChanged')>
procedure ForkCurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpSelectTasks then
    WizardForm.NextButton.Caption := SetupMessage(msgButtonInstall)
  else if CurPageID = wpFinished then
  begin
    WizardForm.NextButton.Caption := SetupMessage(msgButtonFinish);
    if OfficialRemoved then
      WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10#13#10 +
        'The official Plezy was removed. A copy of your settings is in ' + SettingsBackupDir + '.';
  end
  else
    WizardForm.NextButton.Caption := SetupMessage(msgButtonNext);
end;
