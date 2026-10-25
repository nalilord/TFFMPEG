unit TFFmpeg.Encoder;

interface

uses
  libavcodec,
  libavcodec_codec,
  libavcodec_codec_id,
  libavcodec_packet,
  libavutil_frame,
  libavutil_dict;

type
  // One instance per worker. Configure the borrowed context after Allocate and
  // before Open. Frames/packets/dictionaries remain caller-owned.
  TFFmpegEncoder = class
  private
    FCodecContext: PAVCodecContext;
    FCodec: PAVCodec;
    FOpened: Boolean;
    function AllocateCodec(ACodec: PAVCodec): Integer;
  public
    destructor Destroy; override;
    function Allocate(ACodecID: TAVCodecID): Integer;
    function AllocateByName(const AEncoderName: String): Integer;
    function Open(AOptions: PPAVDictionary = nil): Integer;
    procedure Close;
    // nil frame begins draining. EAGAIN requires receiving output before retry.
    function SendFrame(AFrame: PAVFrame): Integer;
    function ReceivePacket(APacket: PAVPacket): Integer;
    property CodecContext: PAVCodecContext read FCodecContext;
    property Codec: PAVCodec read FCodec;
    property Opened: Boolean read FOpened;
  end;

implementation

uses
  libavutil_error;

destructor TFFmpegEncoder.Destroy;
begin
  Close;
  inherited;
end;

procedure TFFmpegEncoder.Close;
begin
  FOpened:=False;
  avcodec_free_context(@FCodecContext);
  FCodec:=nil;
end;

function TFFmpegEncoder.AllocateCodec(ACodec: PAVCodec): Integer;
begin
  Result:=AVERROR_ENCODER_NOT_FOUND;
  Close;

  FCodec:=ACodec;
  if NOT Assigned(FCodec) then
    Exit;

  FCodecContext:=avcodec_alloc_context3(FCodec);
  if NOT Assigned(FCodecContext) then
  begin
    FCodec:=nil;
    Exit(AVERROR_ENOMEM);
  end;

  Result:=0;
end;

function TFFmpegEncoder.Allocate(ACodecID: TAVCodecID): Integer;
begin
  Result:=AllocateCodec(avcodec_find_encoder(ACodecID));
end;

function TFFmpegEncoder.AllocateByName(const AEncoderName: String): Integer;
var
  Name: UTF8String;
begin
  Result:=AVERROR_EINVAL;
  if (AEncoderName = '') OR (Pos(#0, AEncoderName) > 0) then
  begin
    Close;
    Exit;
  end;
  Name:=UTF8String(UTF8Encode(AEncoderName));
  Result:=AllocateCodec(avcodec_find_encoder_by_name(PAnsiChar(Name)));
end;

function TFFmpegEncoder.Open(AOptions: PPAVDictionary): Integer;
begin
  Result:=AVERROR_EINVAL;
  if NOT Assigned(FCodecContext) OR FOpened then
    Exit;

  Result:=avcodec_open2(FCodecContext, FCodec, AOptions);
  if Result < 0 then
    Close
  else
    FOpened:=True;
end;

function TFFmpegEncoder.SendFrame(AFrame: PAVFrame): Integer;
begin
  Result:=AVERROR_EINVAL;

  if FOpened then
    Result:=avcodec_send_frame(FCodecContext, AFrame);
end;

function TFFmpegEncoder.ReceivePacket(APacket: PAVPacket): Integer;
begin
  Result:=AVERROR_EINVAL;

  if FOpened AND Assigned(APacket) then
    Result:=avcodec_receive_packet(FCodecContext, APacket);
end;

end.
