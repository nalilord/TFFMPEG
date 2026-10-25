unit MediaTestSupport;

interface

type
  TMediaTestDirectory = class
  private
    FPath: String;
  public
    constructor Create;
    destructor Destroy; override;
    function FileName(const AName: String): String;
    property Path: String read FPath;
  end;

implementation

uses
{$IFDEF FPC}
  SysUtils;
{$ELSE}
  System.SysUtils;
{$ENDIF}

constructor TMediaTestDirectory.Create;
var
  Identifier: TGUID;
  TempPath: String;
  Candidate: String;
begin
  inherited Create;
  if CreateGUID(Identifier) <> 0 then
    raise Exception.Create('Cannot generate a unique test directory');
{$IFDEF FPC}
  TempPath:=GetTempDir;
{$ELSE}
  TempPath:=GetEnvironmentVariable('TEMP');
{$ENDIF}
  if TempPath = '' then
    raise Exception.Create('Temporary directory is unavailable');
  Candidate:=IncludeTrailingPathDelimiter(TempPath) + 'tffmpeg-' + GUIDToString(Identifier);
  if NOT CreateDir(Candidate) then
    raise Exception.Create('Cannot create test directory: ' + Candidate);
  FPath:=Candidate;
end;

destructor TMediaTestDirectory.Destroy;
var
  Search: TSearchRec;
begin
  // Tests keep files flat. Never recursively traverse links or unrelated paths.
  if FPath <> '' then
  begin
    if FindFirst(IncludeTrailingPathDelimiter(FPath) + '*', faAnyFile, Search) = 0 then
    try
      repeat
        if (Search.Attr AND faDirectory) = 0 then
          DeleteFile(IncludeTrailingPathDelimiter(FPath) + Search.Name);
      until FindNext(Search) <> 0;
    finally
      FindClose(Search);
    end;
    RemoveDir(FPath);
  end;
  inherited Destroy;
end;

function TMediaTestDirectory.FileName(const AName: String): String;
begin
  Result:='';
  if (AName = '') OR (ExtractFileName(AName) <> AName) OR (AName = '.') OR (AName = '..') then
    raise Exception.Create('Test filename must be a single path component');
  Result:=IncludeTrailingPathDelimiter(FPath) + AName;
end;

end.
