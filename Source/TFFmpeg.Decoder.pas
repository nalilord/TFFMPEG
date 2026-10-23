unit TFFmpeg.Decoder;

interface

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  libavcodec,
  libavcodec_codec,
  libavcodec_codec_par,
  libavcodec_codec_id,
  libavcodec_packet,
  libavutil_error,
  libavutil_frame,
  TFFmpeg.Api,
  TFFmpeg.Utils;

type
  TFFmpegDecoder = class
  private
    FCodecContext: PAVCodecContext;
    FCodec: PAVCodec;
  public
    destructor Destroy; override;

    function Open(const ACodec: PAVCodec; const ACodecParameters: PAVCodecParameters): Integer;
    procedure Close;
    function SendPacket(const Packet: PAVPacket): Integer;
    function ReceiveFrame(Frame: PAVFrame): Integer;
    procedure Flush;

    property CodecContext: PAVCodecContext read FCodecContext;
    property Codec: PAVCodec read FCodec;
  end;

implementation

procedure TFFmpegDecoder.Close;
begin
  if Assigned(FCodecContext) then
    TFFmpegApi.FreeDecoderContext(FCodecContext);
  FCodec := nil;
end;

destructor TFFmpegDecoder.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TFFmpegDecoder.Flush;
begin
  if Assigned(FCodecContext) then
    TFFmpegApi.SendFlushPacket(FCodecContext);
end;

function TFFmpegDecoder.Open(const ACodec: PAVCodec; const ACodecParameters: PAVCodecParameters): Integer;
begin
  Close;
  FCodec := ACodec;
  FCodecContext := TFFmpegApi.AllocDecoderContext(ACodec);
  if not Assigned(FCodecContext) then
    Exit(AVERROR_ENOMEM);

  Result := TFFmpegApi.CopyCodecParameters(FCodecContext, ACodecParameters);
  if Result < 0 then
    Exit;

  Result := TFFmpegApi.OpenDecoder(FCodecContext, ACodec);
end;

function TFFmpegDecoder.ReceiveFrame(Frame: PAVFrame): Integer;
begin
  Result := TFFmpegApi.ReceiveFrame(FCodecContext, Frame);
end;

function TFFmpegDecoder.SendPacket(const Packet: PAVPacket): Integer;
begin
  Result := TFFmpegApi.SendPacket(FCodecContext, Packet);
end;

end.
