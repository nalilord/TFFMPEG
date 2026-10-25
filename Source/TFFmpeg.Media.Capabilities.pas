unit TFFmpeg.Media.Capabilities;

interface

type
  TMediaCapabilities = class sealed
  public
    // Names are concrete FFmpeg codec implementations, not filename extensions.
    class function HasEncoder(const AName: String): Boolean; static;
    class function HasDecoder(const AName: String): Boolean; static;
    class function HasMuxer(const AName: String): Boolean; static;
    class function HasDemuxer(const AName: String): Boolean; static;
    class function RuntimeVersion: String; static;
  end;

implementation

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  libavcodec_codec,
  libavformat,
  libavutil,
  TFFmpeg.Utils,
  TFFmpeg.Media.Errors;

function CapabilityName(const AName: String): UTF8String;
begin
  Result:='';
  if (AName = '') OR (Pos(#0, AName) > 0) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Capability query', 'A nonempty name without NUL is required');
  Result:=StringToUTF8String(AName);
end;

class function TMediaCapabilities.HasEncoder(const AName: String): Boolean;
begin
  Result:=Assigned(avcodec_find_encoder_by_name(PAnsiChar(CapabilityName(AName))));
end;

class function TMediaCapabilities.HasDecoder(const AName: String): Boolean;
begin
  Result:=Assigned(avcodec_find_decoder_by_name(PAnsiChar(CapabilityName(AName))));
end;

class function TMediaCapabilities.HasMuxer(const AName: String): Boolean;
var
  Name: UTF8String;
  Opaque: Pointer;
  Muxer: PAVOutputFormat;
begin
  Result:=False;
  Name:=CapabilityName(AName);
  Opaque:=nil;
  Muxer:=av_muxer_iterate(@Opaque);
  while Assigned(Muxer) do
  begin
    if String(Muxer.name) = String(Name) then
      Exit(True);
    Muxer:=av_muxer_iterate(@Opaque);
  end;
end;

class function TMediaCapabilities.HasDemuxer(const AName: String): Boolean;
begin
  Result:=Assigned(av_find_input_format(PAnsiChar(CapabilityName(AName))));
end;

class function TMediaCapabilities.RuntimeVersion: String;
begin
  Result:=String(AnsiString(av_version_info));
end;

end.
