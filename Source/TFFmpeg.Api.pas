unit TFFmpeg.Api;

interface

uses
  libavcodec,
  libavcodec_codec,
  libavcodec_codec_par,
  libavcodec_packet,
  libavformat,
  libavutil,
  libavutil_dict,
  libavutil_frame,
  libavutil_samplefmt,
  TFFmpeg.Utils;

type
  TFFmpegApi = class sealed
  public
    class function AllocDecoderContext(Codec: PAVCodec): PAVCodecContext; static;
    class function AllocFrame: PAVFrame; static;
    class function AllocPacket: PAVPacket; static;
    class function CopyCodecParameters(CodecContext: PAVCodecContext;
      CodecParameters: PAVCodecParameters): Integer; static;
    class procedure CloseInput(var FormatContext: PAVFormatContext); static;
    class function FindBestAudioStream(FormatContext: PAVFormatContext;
      out Codec: PAVCodec): Integer; static;
    class function FindStreamInfo(FormatContext: PAVFormatContext): Integer; static;
    class procedure FreeDecoderContext(var CodecContext: PAVCodecContext); static;
    class procedure FreeFrame(var Frame: PAVFrame); static;
    class procedure FreePacket(var Packet: PAVPacket); static;
    class function OpenDecoder(CodecContext: PAVCodecContext; Codec: PAVCodec): Integer; static;
    class function OpenInput(var FormatContext: PAVFormatContext; const URL: UTF8String;
      var Options: PAVDictionary): Integer; static;
    class function ReadFrame(FormatContext: PAVFormatContext; Packet: PAVPacket): Integer; static;
    class function ReceiveFrame(CodecContext: PAVCodecContext; Frame: PAVFrame): Integer; static;
    class function SendPacket(CodecContext: PAVCodecContext; Packet: PAVPacket): Integer; static;
    class procedure SendFlushPacket(CodecContext: PAVCodecContext); static;
    class procedure UnrefFrame(Frame: PAVFrame); static;
    class procedure UnrefPacket(Packet: PAVPacket); static;
  end;

implementation

class function TFFmpegApi.AllocDecoderContext(Codec: PAVCodec): PAVCodecContext;
begin
  Result := avcodec_alloc_context3(Codec);
end;

class function TFFmpegApi.AllocFrame: PAVFrame;
begin
  Result := av_frame_alloc();
end;

class function TFFmpegApi.AllocPacket: PAVPacket;
begin
  Result := av_packet_alloc();
end;

class function TFFmpegApi.CopyCodecParameters(CodecContext: PAVCodecContext;
  CodecParameters: PAVCodecParameters): Integer;
begin
  Result := avcodec_parameters_to_context(CodecContext, CodecParameters);
end;

class procedure TFFmpegApi.CloseInput(var FormatContext: PAVFormatContext);
begin
  avformat_close_input(@FormatContext);
end;

class function TFFmpegApi.FindBestAudioStream(FormatContext: PAVFormatContext;
  out Codec: PAVCodec): Integer;
begin
  Codec := nil;
  Result := av_find_best_stream(FormatContext, AVMEDIA_TYPE_AUDIO, -1, -1, @Codec, 0);
end;

class function TFFmpegApi.FindStreamInfo(FormatContext: PAVFormatContext): Integer;
begin
  Result := avformat_find_stream_info(FormatContext, nil);
end;

class procedure TFFmpegApi.FreeDecoderContext(var CodecContext: PAVCodecContext);
begin
  avcodec_free_context(@CodecContext);
end;

class procedure TFFmpegApi.FreeFrame(var Frame: PAVFrame);
begin
  av_frame_free(@Frame);
end;

class procedure TFFmpegApi.FreePacket(var Packet: PAVPacket);
begin
  av_packet_free(@Packet);
end;

class function TFFmpegApi.OpenDecoder(CodecContext: PAVCodecContext; Codec: PAVCodec): Integer;
begin
  Result := avcodec_open2(CodecContext, Codec, nil);
end;

class function TFFmpegApi.OpenInput(var FormatContext: PAVFormatContext; const URL: UTF8String;
  var Options: PAVDictionary): Integer;
begin
  EnsureFFmpegNetworkInitialized;
  Result := avformat_open_input(@FormatContext, PAnsiChar(URL), nil, @Options);
end;

class function TFFmpegApi.ReadFrame(FormatContext: PAVFormatContext; Packet: PAVPacket): Integer;
begin
  Result := av_read_frame(FormatContext, Packet);
end;

class function TFFmpegApi.ReceiveFrame(CodecContext: PAVCodecContext; Frame: PAVFrame): Integer;
begin
  Result := avcodec_receive_frame(CodecContext, Frame);
end;

class function TFFmpegApi.SendPacket(CodecContext: PAVCodecContext; Packet: PAVPacket): Integer;
begin
  Result := avcodec_send_packet(CodecContext, Packet);
end;

class procedure TFFmpegApi.SendFlushPacket(CodecContext: PAVCodecContext);
begin
  avcodec_send_packet(CodecContext, nil);
end;

class procedure TFFmpegApi.UnrefFrame(Frame: PAVFrame);
begin
  av_frame_unref(Frame);
end;

class procedure TFFmpegApi.UnrefPacket(Packet: PAVPacket);
begin
  av_packet_unref(Packet);
end;

end.
