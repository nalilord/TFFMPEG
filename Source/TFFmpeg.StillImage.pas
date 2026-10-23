unit TFFmpeg.StillImage;

interface

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  libavutil_frame,
  libavformat_avio;

type
  TFFmpegStillImage = class sealed
  public
    // Literal local BMP/PNG/JPEG only, exactly one decoded frame. Caller owns AFrame.
    class function DecodeFile(const AFilename: string; const AInterrupt: TAVIOInterruptCB;
      out AFrame: PAVFrame): Integer; static;
    // Caller owns returned bytes. Source is borrowed. Alpha is composited onto
    // ABackgroundRGB before encoding an opaque, uncompressed 24-bit BMP.
    class function EncodeBMP(ASource: PAVFrame; AWidth, AHeight: Integer; out ABytes: TBytes;
      ABackgroundRGB: Cardinal = 0): Integer; static;
  end;

implementation

uses
  libavutil_error,
  libavutil_pixfmt,
  libavutil,
  libavutil_dict,
  libavcodec_codec_id,
  libavcodec_packet,
  TFFmpeg.VideoScaler,
  TFFmpeg.Encoder,
  TFFmpeg.Input,
  TFFmpeg.Decoder;

class function TFFmpegStillImage.DecodeFile(const AFilename: string; const AInterrupt: TAVIOInterruptCB;
  out AFrame: PAVFrame): Integer;
var
  Input: TFFmpegInput;
  Decoder: TFFmpegDecoder;
  Packet: PAVPacket;
  Frame, Saved: PAVFrame;
  Options: PAVDictionary;
  Code, FrameCount: Integer;

  function ReceiveFrames: Integer;
  begin
    Result:=0;
    repeat
      Code:=Decoder.ReceiveFrame(Frame);
      if (Code = AVERROR_EAGAIN) OR (Code = AVERROR_EOF) then
        Exit;
      if Code < 0 then
        Exit(Code);
      Inc(FrameCount);
      if (FrameCount > 1) OR (Frame.width <= 0) OR (Frame.height <= 0) OR
        (Int64(Frame.width) * Frame.height > 67108864) then
        Exit(AVERROR_EINVAL);
      Saved:=av_frame_clone(Frame);
      if NOT Assigned(Saved) then
        Exit(AVERROR_ENOMEM);
      av_frame_unref(Frame);
    until False;
  end;

begin
  AFrame:=nil;
  Result:=AVERROR_EINVAL;
  Input:=TFFmpegInput.Create;
  Decoder:=TFFmpegDecoder.Create;
  Packet:=nil;
  Frame:=nil;
  Saved:=nil;
  Options:=nil;
  FrameCount:=0;
  try
    Result:=av_dict_set(@Options, 'format_whitelist', 'bmp_pipe,png_pipe,jpeg_pipe', 0);
    if Result < 0 then Exit;
    Result:=Input.OpenFile(AFilename, Options, AInterrupt, AVMEDIA_TYPE_VIDEO);
    if Result < 0 then Exit;
    if NOT (Input.CodecParameters.codec_id IN [AV_CODEC_ID_BMP, AV_CODEC_ID_PNG, AV_CODEC_ID_MJPEG]) then
      Exit(AVERROR_EINVAL);
    if (Input.CodecParameters.width <= 0) OR (Input.CodecParameters.height <= 0) OR
      (Int64(Input.CodecParameters.width) * Input.CodecParameters.height > 67108864) then
      Exit(AVERROR_EINVAL);
    Result:=Decoder.Open(Input.Codec, Input.CodecParameters);
    if Result < 0 then Exit;
    Decoder.CodecContext.max_pixels:=67108864;
    Packet:=av_packet_alloc;
    Frame:=av_frame_alloc;
    if NOT Assigned(Packet) OR NOT Assigned(Frame) then
      Exit(AVERROR_ENOMEM);
    repeat
      Code:=Input.ReadPacket(Packet);
      if Code = AVERROR_EOF then Break;
      if Code < 0 then Exit(Code);
      try
        if Packet.stream_index = Input.StreamIndex then
        begin
          Result:=Decoder.SendPacket(Packet);
          if Result < 0 then Exit;
          Result:=ReceiveFrames;
          if Result < 0 then Exit;
        end;
      finally
        av_packet_unref(Packet);
      end;
    until False;
    Result:=Decoder.SendPacket(nil);
    if Result < 0 then Exit;
    Result:=ReceiveFrames;
    if Result < 0 then Exit;
    if FrameCount <> 1 then Exit(AVERROR_EINVAL);
    AFrame:=Saved;
    Saved:=nil;
    Result:=0;
  finally
    av_dict_free(@Options);
    av_frame_free(@Saved);
    av_frame_free(@Frame);
    av_packet_free(@Packet);
    Decoder.Free;
    Input.Free;
  end;
end;

class function TFFmpegStillImage.EncodeBMP(ASource: PAVFrame; AWidth, AHeight: Integer; out ABytes: TBytes;
  ABackgroundRGB: Cardinal): Integer;
var
  Scaled, Opaque: PAVFrame;
  Encoder: TFFmpegEncoder;
  Packet: PAVPacket;
  Src, Dst: PByte;
  X, Y, C, Alpha, Background: Integer;
begin
  ABytes:=nil;
  Result:=AVERROR_EINVAL;
  if ABackgroundRGB > $FFFFFF then
    Exit;
  Scaled:=nil;
  Opaque:=nil;
  Packet:=nil;
  Encoder:=nil;
  try
    Result:=TFFmpegVideoScaler.Scale(ASource, AWidth, AHeight, AV_PIX_FMT_BGRA, Scaled);
    if Result < 0 then
      Exit;
    Opaque:=av_frame_alloc;
    Packet:=av_packet_alloc;
    if NOT Assigned(Opaque) OR NOT Assigned(Packet) then
      Exit(AVERROR_ENOMEM);
    Opaque.width:=AWidth;
    Opaque.height:=AHeight;
    Opaque.format:=Ord(AV_PIX_FMT_BGR24);
    Opaque.pts:=0;
    Result:=av_frame_get_buffer(Opaque, 32);
    if Result < 0 then
      Exit;
    for Y:=0 to AHeight - 1 do
    begin
      Src:=PByte(NativeUInt(Scaled.data[0]) + NativeUInt(Y * Scaled.linesize[0]));
      Dst:=PByte(NativeUInt(Opaque.data[0]) + NativeUInt(Y * Opaque.linesize[0]));
      for X:=0 to AWidth - 1 do
      begin
        Alpha:=PByte(NativeUInt(Src) + 3)^;
        for C:=0 to 2 do
        begin
          Background:=(ABackgroundRGB SHR (C * 8)) AND $FF;
          Dst^:=(Integer(Src^) * Alpha + Background * (255 - Alpha) + 127) DIV 255;
          Inc(Src);
          Inc(Dst);
        end;
        Inc(Src);
      end;
    end;
    Encoder:=TFFmpegEncoder.Create;
    Result:=Encoder.Allocate(AV_CODEC_ID_BMP);
    if Result < 0 then
      Exit;
    Encoder.CodecContext.width:=AWidth;
    Encoder.CodecContext.height:=AHeight;
    Encoder.CodecContext.pix_fmt:=AV_PIX_FMT_BGR24;
    Encoder.CodecContext.time_base.num:=1;
    Encoder.CodecContext.time_base.den:=1;
    Result:=Encoder.Open;
    if Result < 0 then
      Exit;
    Result:=Encoder.SendFrame(Opaque);
    if Result < 0 then
      Exit;
    Result:=Encoder.ReceivePacket(Packet);
    if Result < 0 then
      Exit;
    if (Packet.size <= 0) OR NOT Assigned(Packet.data) then
      Exit(AVERROR_EINVAL);
    SetLength(ABytes, Packet.size);
    Move(Packet.data^, ABytes[0], Packet.size);
    av_packet_unref(Packet);
    Result:=Encoder.SendFrame(nil);
    if Result < 0 then
    begin
      ABytes:=nil;
      Exit;
    end;
    Result:=Encoder.ReceivePacket(Packet);
    if Result <> AVERROR_EOF then
    begin
      ABytes:=nil;
      if Result >= 0 then
        Result:=AVERROR_EINVAL;
      Exit;
    end;
    Result:=0;
  finally
    Encoder.Free;
    av_packet_free(@Packet);
    av_frame_free(@Opaque);
    av_frame_free(@Scaled);
  end;
end;

end.
