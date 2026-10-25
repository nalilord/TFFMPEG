unit TFFmpeg.Utils;

interface

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  FFTypes,
  libavformat,
  libavutil_dict,
  libavutil_error;

function StringToUTF8String(const S: String): UTF8String;
function UTF8PtrToString(const Value: PAnsiChar): String;
function FFmpegErrorText(ErrorCode: Integer): String;
function DictValue(const Dict: PAVDictionary; const Key: AnsiString): String;
procedure EnsureFFmpegNetworkInitialized;
function PPtrIdx(P: PPAVStream; I: Integer): PAVStream; overload;

implementation

var
  GNetworkInitialized: Boolean = False;

function StringToUTF8String(const S: String): UTF8String;
begin
  Result:=UTF8String(UTF8Encode(S));
end;

function UTF8PtrToString(const Value: PAnsiChar): String;
begin
  if Assigned(Value) then
    Result:=UTF8ToString(UTF8String(Value))
  else
    Result:='';
end;

function FFmpegErrorText(ErrorCode: Integer): String;
begin
  if ErrorCode < 0 then
    Result:=UTF8PtrToString(av_err2str(ErrorCode))
  else
    Result:='';
end;

function DictValue(const Dict: PAVDictionary; const Key: AnsiString): String;
var
  Entry: PAVDictionaryEntry;
begin
  Entry:=av_dict_get(Dict, PAnsiChar(Key), nil, 0);
  if Assigned(Entry) then
    Result:=UTF8PtrToString(Entry^.value)
  else
    Result:='';
end;

procedure EnsureFFmpegNetworkInitialized;
begin
  if NOT GNetworkInitialized then
  begin
    avformat_network_init();
    GNetworkInitialized:=True;
  end;
end;

function PPtrIdx(P: PPAVStream; I: Integer): PAVStream;
begin
  Inc(P, I);

  Result:=P^;
end;

initialization

finalization
  if GNetworkInitialized then
    avformat_network_deinit();

end.
