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
  libavutil_rational,
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
    function OpenLimited(const ACodec: PAVCodec; const ACodecParameters: PAVCodecParameters;
      AMaxPixels, AMaxSamples: Int64): Integer; overload;
    function OpenLimited(const ACodec: PAVCodec; const ACodecParameters: PAVCodecParameters;
      AMaxPixels, AMaxSamples: Int64; const APacketTimeBase: TAVRational): Integer; overload;
    procedure Close;
    function SendPacket(const Packet: PAVPacket): Integer;
    function ReceiveFrame(Frame: PAVFrame): Integer;
    procedure Flush;
    // Discards buffered output after a successful seek; Flush still starts EOF drain.
    procedure Reset;

    property CodecContext: PAVCodecContext read FCodecContext;
    property Codec: PAVCodec read FCodec;
  end;

implementation

procedure TFFmpegDecoder.Close;
begin
  if Assigned(FCodecContext) then
    TFFmpegApi.FreeDecoderContext(FCodecContext);
  FCodec:=nil;
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
  Result:=OpenLimited(ACodec, ACodecParameters, 0, 0);
end;

procedure TFFmpegDecoder.Reset;
begin
  if Assigned(FCodecContext) then
    avcodec_flush_buffers(FCodecContext);
end;

function TFFmpegDecoder.OpenLimited(const ACodec: PAVCodec; const ACodecParameters: PAVCodecParameters;
  AMaxPixels, AMaxSamples: Int64): Integer;
begin
  Result:=OpenLimited(ACodec, ACodecParameters, AMaxPixels, AMaxSamples, Default(TAVRational));
end;

function TFFmpegDecoder.OpenLimited(const ACodec: PAVCodec; const ACodecParameters: PAVCodecParameters;
  AMaxPixels, AMaxSamples: Int64; const APacketTimeBase: TAVRational): Integer;
begin
  Close;
  Result:=AVERROR_EINVAL;
  if NOT Assigned(ACodecParameters) OR (AMaxPixels < 0) OR (AMaxSamples < 0) then
    Exit;

  FCodecContext:=TFFmpegApi.AllocDecoderContext(ACodec);
  if NOT Assigned(FCodecContext) then
    Exit(AVERROR_ENOMEM);
  FCodec:=ACodec;

  Result:=TFFmpegApi.CopyCodecParameters(FCodecContext, ACodecParameters);
  if Result >= 0 then
  begin
    if AMaxPixels > 0 then
      FCodecContext.max_pixels:=AMaxPixels;
    if AMaxSamples > 0 then
      FCodecContext.max_samples:=AMaxSamples;
    // Native skip-sample handling adjusts PTS/duration in this time base. Set it
    // before opening, so trimmed audio timestamps describe the retained samples.
    FCodecContext.pkt_timebase:=APacketTimeBase;
    Result:=TFFmpegApi.OpenDecoder(FCodecContext, ACodec);
  end;

  if Result < 0 then
    Close;
end;

function TFFmpegDecoder.ReceiveFrame(Frame: PAVFrame): Integer;
begin
  Result:=TFFmpegApi.ReceiveFrame(FCodecContext, Frame);
end;

function TFFmpegDecoder.SendPacket(const Packet: PAVPacket): Integer;
begin
  Result:=TFFmpegApi.SendPacket(FCodecContext, Packet);
end;

end.
