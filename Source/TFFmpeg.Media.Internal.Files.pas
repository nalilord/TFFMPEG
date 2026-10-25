unit TFFmpeg.Media.Internal.Files;

interface

type
  // Owns an exclusively reserved sibling until successful publication. Consumers
  // must close native/RTL output handles before Publish or destruction.
  TMediaLocalOutput = class
  private
    FDestination: String;
    FTemporary: String;
    FOverwrite: Boolean;
    FPublished: Boolean;
  public
    constructor Create(const ADestination: String; AOverwrite: Boolean);
    destructor Destroy; override;
    procedure Publish;
    property Temporary: String read FTemporary;
    property Destination: String read FDestination;
  end;

// Reject same path and existing hard-link/symlink aliases before conversion IO.
procedure RequireDifferentFiles(const ASource, ADestination: String);

implementation

uses
{$IFDEF FPC}
  SysUtils,
{$IFDEF MSWINDOWS}
  Windows,
{$ELSE}
  BaseUnix,
{$ENDIF}
{$ELSE}
  System.SysUtils,
{$IFDEF MSWINDOWS}
  Winapi.Windows,
{$ENDIF}
{$ENDIF}
  TFFmpeg.Media.Errors;

procedure RequireDifferentFiles(const ASource, ADestination: String);
var
  SourceName, DestinationName: String;
  Same: Boolean;
{$IFDEF MSWINDOWS}
  SourceHandle, DestinationHandle: THandle;
  SourceInfo, DestinationInfo: TByHandleFileInformation;
{$ELSE}
{$IFDEF FPC}
  SourceInfo, DestinationInfo: Stat;
{$ENDIF}
{$ENDIF}
begin
  if (ASource = '') OR (ADestination = '') OR (Pos(#0, ASource) > 0) OR (Pos(#0, ADestination) > 0) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Convert files', 'Source and destination filenames without NUL are required');
  SourceName:=ExpandFileName(ASource);
  DestinationName:=ExpandFileName(ADestination);
  if SameFileName(SourceName, DestinationName) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Convert files', 'Source and destination refer to the same file');
  if NOT FileExists(DestinationName) then
    Exit;
  Same:=False;
{$IFDEF MSWINDOWS}
  SourceHandle:=CreateFileW(PWideChar(UnicodeString(SourceName)), 0, FILE_SHARE_READ OR FILE_SHARE_WRITE OR FILE_SHARE_DELETE,
    nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0);
  if SourceHandle = INVALID_HANDLE_VALUE then
    raise EFFmpegMediaError.Create(mecInputOutput, 'Compare file identities', 'Cannot open source for identity comparison');
  try
    DestinationHandle:=CreateFileW(PWideChar(UnicodeString(DestinationName)), 0, FILE_SHARE_READ OR FILE_SHARE_WRITE OR FILE_SHARE_DELETE,
      nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0);
    if DestinationHandle = INVALID_HANDLE_VALUE then
      raise EFFmpegMediaError.Create(mecInputOutput, 'Compare file identities', 'Cannot open destination for identity comparison');
    try
      if NOT GetFileInformationByHandle(SourceHandle, SourceInfo) OR NOT GetFileInformationByHandle(DestinationHandle, DestinationInfo) then
        raise EFFmpegMediaError.Create(mecInputOutput, 'Compare file identities', 'Cannot compare file identities');
      Same:=(SourceInfo.dwVolumeSerialNumber = DestinationInfo.dwVolumeSerialNumber) AND
        (SourceInfo.nFileIndexHigh = DestinationInfo.nFileIndexHigh) AND (SourceInfo.nFileIndexLow = DestinationInfo.nFileIndexLow);
    finally
      CloseHandle(DestinationHandle);
    end;
  finally
    CloseHandle(SourceHandle);
  end;
{$ELSE}
{$IFDEF FPC}
  if (fpStat(PAnsiChar(UTF8String(SourceName)), SourceInfo) <> 0) OR (fpStat(PAnsiChar(UTF8String(DestinationName)), DestinationInfo) <> 0) then
    raise EFFmpegMediaError.Create(mecInputOutput, 'Compare file identities', 'Cannot compare file identities');
  Same:=(SourceInfo.st_dev = DestinationInfo.st_dev) AND (SourceInfo.st_ino = DestinationInfo.st_ino);
{$ELSE}
  raise EFFmpegMediaError.Create(mecUnsupported, 'Compare file identities', 'File identity comparison is not implemented on this platform');
{$ENDIF}
{$ENDIF}
  if Same then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Convert files', 'Source and destination are aliases of the same file');
end;

function ReserveFile(const AFilename: String): Boolean;
{$IFDEF MSWINDOWS}
var
  Handle: THandle;
{$ELSE}
{$IFDEF FPC}
var
  Handle: Integer;
{$ENDIF}
{$ENDIF}
begin
  Result:=False;
{$IFDEF MSWINDOWS}
  Handle:=CreateFileW(PWideChar(UnicodeString(AFilename)), GENERIC_WRITE, 0, nil, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
  if Handle <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(Handle);
    Result:=True;
  end;
{$ELSE}
{$IFDEF FPC}
  Handle:=fpOpen(PAnsiChar(UTF8String(AFilename)), O_WRONLY OR O_CREAT OR O_EXCL, &600);
  if Handle >= 0 then
  begin
    fpClose(Handle);
    Result:=True;
  end;
{$ELSE}
  raise EFFmpegMediaError.Create(mecUnsupported, 'Reserve output', 'File publication is not implemented on this platform');
{$ENDIF}
{$ENDIF}
end;

constructor TMediaLocalOutput.Create(const ADestination: String; AOverwrite: Boolean);
var
  Identifier: TGUID;
  Candidate: String;
  I: Integer;
begin
  inherited Create;
  if (ADestination = '') OR (Pos(#0, ADestination) > 0) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Create output', 'A local destination filename without NUL is required');
  FDestination:=ExpandFileName(ADestination);
  FOverwrite:=AOverwrite;
  if DirectoryExists(FDestination) OR NOT DirectoryExists(ExtractFileDir(FDestination)) then
    raise EFFmpegMediaError.Create(mecInputOutput, 'Create output', 'Destination directory is missing or destination is a directory');
  if NOT AOverwrite AND FileExists(FDestination) then
    raise EFFmpegMediaError.Create(mecInputOutput, 'Create output', 'Destination exists and overwrite is disabled');

  for I:=0 to 7 do
  begin
    if CreateGUID(Identifier) <> 0 then
      raise EFFmpegMediaError.Create(mecInputOutput, 'Create output', 'Cannot generate a temporary filename');
    Candidate:=FDestination + '.tffmpeg-' + GUIDToString(Identifier) + '.tmp';
    if ReserveFile(Candidate) then
    begin
      FTemporary:=Candidate;
      Exit;
    end;
  end;
  raise EFFmpegMediaError.Create(mecInputOutput, 'Create output', 'Cannot exclusively reserve a sibling temporary file');
end;

destructor TMediaLocalOutput.Destroy;
begin
  if FTemporary <> '' then
{$IFDEF FPC}
    SysUtils.DeleteFile(FTemporary);
{$ELSE}
    System.SysUtils.DeleteFile(FTemporary);
{$ENDIF}
  inherited Destroy;
end;

procedure TMediaLocalOutput.Publish;
var
  Published: Boolean;
{$IFDEF MSWINDOWS}
  Flags: Cardinal;
{$ENDIF}
begin
  if FPublished then
    Exit;
  if FTemporary = '' then
    raise EFFmpegMediaError.Create(mecInvalidState, 'Publish output', 'Temporary output is unavailable');

  Published:=False;
{$IFDEF MSWINDOWS}
  Flags:=0;
  if FOverwrite then
    Flags:=MOVEFILE_REPLACE_EXISTING;
  Published:=MoveFileExW(PWideChar(UnicodeString(FTemporary)), PWideChar(UnicodeString(FDestination)), Flags);
  if Published then
    FTemporary:='';
{$ELSE}
{$IFDEF FPC}
  if FOverwrite then
  begin
    Published:=fpRename(PAnsiChar(UTF8String(FTemporary)), PAnsiChar(UTF8String(FDestination))) = 0;
    if Published then
      FTemporary:='';
  end else
  begin
    // link creates the destination only if absent; rename alone would replace it.
    Published:=fpLink(PAnsiChar(UTF8String(FTemporary)), PAnsiChar(UTF8String(FDestination))) = 0;
    if Published AND (fpUnlink(PAnsiChar(UTF8String(FTemporary))) = 0) then
      FTemporary:='';
  end;
{$ENDIF}
{$ENDIF}
  if NOT Published then
    raise EFFmpegMediaError.Create(mecInputOutput, 'Publish output', 'Destination publication failed; existing destination was preserved');
  FPublished:=True;
end;

end.
