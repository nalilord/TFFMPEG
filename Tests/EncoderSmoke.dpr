program EncoderSmoke;

{$APPTYPE CONSOLE}
{$POINTERMATH ON}

uses
  System.SysUtils,
  System.Math,
  FFTypes,
  libavcodec,
  libavcodec_codec,
  libavcodec_codec_id,
  libavcodec_packet,
  libavutil_frame,
  libavutil_samplefmt,
  libavutil_channel_layout,
  libavutil_error,
  TFFmpeg.Encoder;

procedure Check(ACondition: Boolean; const AMessage: string);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
  Writeln('PASS ', AMessage);
end;

procedure RequireSuccess(ACode: Integer);
begin
  if ACode < 0 then
    raise Exception.CreateFmt('Unexpected native error %d', [ACode]);
end;

procedure Run;
var
  Encoder: TFFmpegEncoder;
  Frame, Decoded: PAVFrame;
  Packet: PAVPacket;
  Decoder: PAVCodecContext;
  I, J, Cycle, Code, PacketCount, SampleCount, BackpressureCount: Integer;
  Samples: PSmallInt;
  Header: PByte;
  LastPTS: Int64;
  NonSilent: Boolean;

  procedure ReceiveEncoded(ADraining: Boolean);
  var
    Status, SampleIndex: Integer;
    PCM: PSmallInt;
  begin
    while True do
    begin
      Status:=Encoder.ReceivePacket(Packet);
      if Status = AVERROR_EOF then
        Exit;
      if Status = AVERROR_EAGAIN then
      begin
        if ADraining then
          raise Exception.Create('Encoder requested input after successful drain submission.');
        Exit;
      end;
      RequireSuccess(Status);
      try
        Header:=Packet.data;
        if (Packet.size < 4) OR (Header[0] <> $FF) OR ((Header[1] AND $FE) <> $FC) OR
          ((Header[2] SHR 4) <> 4) OR ((Header[2] AND $0C) <> 0) OR ((Header[3] SHR 6) <> 3) then
          raise Exception.Create('Independent MP2 header check failed: expected MPEG-1 Layer II, 64 kbit/s, 44100 Hz, mono.');
        if (PacketCount > 0) AND (Packet.pts <= LastPTS) then
          raise Exception.Create('Encoded packet timestamps did not advance.');
        LastPTS:=Packet.pts;
        Inc(PacketCount);
        RequireSuccess(avcodec_send_packet(Decoder, Packet));
        while True do
        begin
          Status:=avcodec_receive_frame(Decoder, Decoded);
          if (Status = AVERROR_EAGAIN) OR (Status = AVERROR_EOF) then
            Break;
          RequireSuccess(Status);
          try
            if (Decoded.sample_rate <> 44100) OR (Decoded.ch_layout.nb_channels <> 1) OR
              NOT (TAVSampleFormat(Decoded.format) IN [AV_SAMPLE_FMT_S16, AV_SAMPLE_FMT_S16P]) then
              raise Exception.Create('Decoded MP2 format differs from the requested profile.');
            Inc(SampleCount, Decoded.nb_samples);
            PCM:=PSmallInt(Decoded.data[0]);
            for SampleIndex:=0 to Decoded.nb_samples - 1 do
              if Abs(Integer(PCM[SampleIndex])) > 100 then
                NonSilent:=True;
          finally
            av_frame_unref(Decoded);
          end;
        end;
      finally
        av_packet_unref(Packet);
      end;
    end;
  end;

begin
  Encoder:=TFFmpegEncoder.Create;
  Frame:=av_frame_alloc;
  Decoded:=av_frame_alloc;
  Packet:=av_packet_alloc;
  Decoder:=nil;
  try
    Check(Assigned(Frame) AND Assigned(Decoded) AND Assigned(Packet), 'native test buffers allocated');
    Check((Encoder.Open = AVERROR_EINVAL) AND (Encoder.SendFrame(nil) = AVERROR_EINVAL) AND
      (Encoder.ReceivePacket(Packet) = AVERROR_EINVAL), 'closed encoder rejects operations');
    Check(Encoder.Allocate(AV_CODEC_ID_NONE) = AVERROR_ENCODER_NOT_FOUND, 'missing encoder fails without a context');
    RequireSuccess(Encoder.Allocate(AV_CODEC_ID_MP2));
    Check((Encoder.Open < 0) AND NOT Assigned(Encoder.CodecContext) AND NOT Encoder.Opened, 'failed open releases its native context');
    for Cycle:=1 to 20 do
    begin
      RequireSuccess(Encoder.Allocate(AV_CODEC_ID_MP2));
      Encoder.CodecContext.bit_rate:=64000;
      Encoder.CodecContext.sample_rate:=44100;
      Encoder.CodecContext.sample_fmt:=AV_SAMPLE_FMT_S16;
      Encoder.CodecContext.time_base.num:=1;
      Encoder.CodecContext.time_base.den:=44100;
      av_channel_layout_default(@Encoder.CodecContext.ch_layout, 1);
      RequireSuccess(Encoder.Open);
      Check((Encoder.CodecContext.frame_size = 1152) AND (Encoder.Open = AVERROR_EINVAL), 'MP2 frame size and duplicate-open guard');
      Decoder:=avcodec_alloc_context3(avcodec_find_decoder(AV_CODEC_ID_MP2));
      Check(Assigned(Decoder), 'native MP2 decoder allocated');
      RequireSuccess(avcodec_open2(Decoder, avcodec_find_decoder(AV_CODEC_ID_MP2), nil));
      Frame.format:=Ord(AV_SAMPLE_FMT_S16);
      Frame.sample_rate:=44100;
      Frame.nb_samples:=1152;
      RequireSuccess(av_channel_layout_copy(@Frame.ch_layout, @Encoder.CodecContext.ch_layout));
      RequireSuccess(av_frame_get_buffer(Frame, 0));
      PacketCount:=0;
      SampleCount:=0;
      BackpressureCount:=0;
      NonSilent:=False;
      LastPTS:=Low(Int64);
      for I:=0 to 7 do
      begin
        RequireSuccess(av_frame_make_writable(Frame));
        Samples:=PSmallInt(Frame.data[0]);
        for J:=0 to 1151 do
          Samples[J]:=Round(Sin((I * 1152 + J) * 2 * Pi * 440 / 44100) * 12000);
        Frame.pts:=Int64(I) * 1152;
        Code:=Encoder.SendFrame(Frame);
        if Code = AVERROR_EAGAIN then
        begin
          Inc(BackpressureCount);
          ReceiveEncoded(False);
          Code:=Encoder.SendFrame(Frame);
        end;
        RequireSuccess(Code);
        if (I MOD 3) = 2 then
          ReceiveEncoded(False);
      end;
      Code:=Encoder.SendFrame(nil);
      if Code = AVERROR_EAGAIN then
      begin
        ReceiveEncoded(False);
        Code:=Encoder.SendFrame(nil);
      end;
      RequireSuccess(Code);
      ReceiveEncoded(True);
      Check(BackpressureCount > 0, 'encoder backpressure drains output and retries the same unconsumed frame');
      Check((PacketCount = 8) AND (SampleCount = 8 * 1152) AND NonSilent,
        'real mono MP2 packets pass independent headers, advancing timestamps and non-silent decode');
      Check(Encoder.SendFrame(Frame) = AVERROR_EOF, 'drained encoder rejects further input');
      avcodec_free_context(@Decoder);
      av_frame_unref(Frame);
      Encoder.Close;
      Check(NOT Assigned(Encoder.CodecContext) AND NOT Encoder.Opened, 'close releases context and permits fresh encoding');
    end;
  finally
    avcodec_free_context(@Decoder);
    av_packet_free(@Packet);
    av_frame_free(@Decoded);
    av_frame_free(@Frame);
    Encoder.Free;
  end;
end;

begin
  try
    Run;
    Writeln('Shared encoder smoke passed.');
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.ClassName, ': ', E.Message);
      ExitCode:=1;
    end;
  end;
end.
