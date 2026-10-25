program MediaOutputSmoke;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  libavcodec,
  libavcodec_codec_id,
  libavcodec_packet,
  libavformat,
  libavformat_avio,
  libavutil_channel_layout,
  libavutil_dict,
  libavutil_error,
  libavutil_frame,
  libavutil_pixfmt,
  libavutil_samplefmt,
  TFFmpeg.Encoder,
  TFFmpeg.Input,
  TFFmpeg.Output,
  TFFmpeg.Utils,
  TFFmpeg.Media.Reader,
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Internal.Files,
  MediaTestSupport;

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

procedure WriteWave(const AFilename: String; AFailTrailer: Boolean);
var
  Encoder: TFFmpegEncoder;
  Output: TFFmpegOutput;
  Frame: PAVFrame;
  Packet: PAVPacket;
  Options: PAVDictionary;
  StreamIndex, I, Code: Integer;
  PTS, DTS, Duration: Int64;
begin
  Encoder:=TFFmpegEncoder.Create;
  Output:=TFFmpegOutput.Create;
  Frame:=nil;
  Packet:=nil;
  Options:=nil;
  try
    Check(Output.Allocate('wav', AFilename) = 0, 'Allocate explicit WAV muxer');
    Check(NOT Output.RequiresGlobalHeader, 'WAV global-header policy');
    Check(Output.Finish = AVERROR_EINVAL, 'Cannot finish before header');
    Check(Encoder.AllocateByName('tffmpeg_missing_encoder') = AVERROR_ENCODER_NOT_FOUND, 'Missing named encoder is a capability failure');
    Check(NOT Assigned(Encoder.CodecContext), 'Missing named encoder leaves no context');
    Check(Encoder.AllocateByName('') = AVERROR_EINVAL, 'Empty encoder name is invalid settings');
    Check(Encoder.AllocateByName('pcm_s16le') = 0, 'Allocate concrete named PCM encoder');
    Encoder.CodecContext.sample_rate:=48000;
    Encoder.CodecContext.sample_fmt:=AV_SAMPLE_FMT_S16;
    av_channel_layout_default(@Encoder.CodecContext.ch_layout, 1);
    // Deliberately use milliseconds. WAV renegotiates stream time_base to 1/48000.
    Encoder.CodecContext.time_base.num:=1;
    Encoder.CodecContext.time_base.den:=1000;
    Check(Encoder.Open = 0, 'Open PCM encoder');
    Check(Output.AddStream(Encoder.CodecContext, StreamIndex) = 0, 'Copy opened codec parameters');
    Check(StreamIndex = 0, 'Stable output stream index');
    Check(Output.WriteHeader(Options, Default(TAVIOInterruptCB)) = 0, 'Write WAV header');
    Check(Output.HeaderWritten AND (PPtrIdx(Output.FormatContext.streams, 0).time_base.den = 48000), 'Use negotiated stream time base');
    Check(Output.WriteHeader(Options, Default(TAVIOInterruptCB)) = AVERROR_EINVAL, 'Header may be written once');
    Check(Output.AddStream(Encoder.CodecContext, I) = AVERROR_EINVAL, 'Stream setup freezes after header');
    Frame:=av_frame_alloc;
    Packet:=av_packet_alloc;
    Check(Assigned(Frame) AND Assigned(Packet), 'Allocate encoder buffers');
    Frame.nb_samples:=480;
    Frame.sample_rate:=48000;
    Frame.format:=Ord(AV_SAMPLE_FMT_S16);
    Frame.pts:=0;
    av_channel_layout_default(@Frame.ch_layout, 1);
    Check(av_frame_get_buffer(Frame, 0) = 0, 'Allocate PCM storage');
    for I:=0 to 479 do
      PSmallInt(NativeUInt(Frame.data[0]) + NativeUInt(I) * 2)^:=1000 - (I MOD 2) * 2000;
    PSmallInt(Frame.data[0])^:=1234;
    PSmallInt(NativeUInt(Frame.data[0]) + 479 * 2)^:=-2345;
    Check(Encoder.SendFrame(Frame) = 0, 'Send PCM frame');
    Check(Encoder.ReceivePacket(Packet) = 0, 'Receive PCM packet');
    PTS:=Packet.pts;
    DTS:=Packet.dts;
    Duration:=Packet.duration;
    Check(Duration = 10, 'PCM packet duration is in encoder milliseconds');
    Check(Output.WritePacket(Packet, StreamIndex) = 0, 'Interleaved packet write/rescale');
    Check((Packet.pts = PTS) AND (Packet.dts = DTS) AND (Packet.duration = Duration) AND (Packet.size > 0), 'Muxing must borrow/preserve caller packet');
    av_packet_unref(Packet);
    Check(Encoder.SendFrame(nil) = 0, 'Drain PCM encoder');
    Check(Encoder.ReceivePacket(Packet) = AVERROR_EOF, 'PCM encoder drain completes');
    if AFailTrailer then
      Output.FormatContext.pb.error:=AVERROR_EIO;
    Code:=Output.Finish;
    if AFailTrailer then
    begin
      Check((Code < 0) AND Output.Failed AND NOT Output.Finished, 'Trailer IO failure must be reported');
      Check(Output.Finish < 0, 'Failed finalization is not reported as success');
    end else
    begin
      Check((Code = 0) AND Output.Finished AND NOT Assigned(Output.FormatContext.pb), 'Successful trailer closes owned IO');
      Check(Output.Finish = 0, 'Successful Finish is idempotent');
      Check(Output.WritePacket(Packet, 0) = AVERROR_EINVAL, 'Finished muxer rejects further packets');
    end;
  finally
    av_dict_free(@Options);
    av_packet_free(@Packet);
    av_frame_free(@Frame);
    Output.Free;
    Encoder.Free;
  end;
end;

procedure TestReorderedPacketTimes(const AFilename: String);
var
  Encoder: TFFmpegEncoder;
  Output: TFFmpegOutput;
  Input: TFFmpegInput;
  Frame: PAVFrame;
  Packet: PAVPacket;
  Options: PAVDictionary;
  ExpectedPTS, ExpectedDTS: Array of Int64;
  StreamIndex, I, Plane, Y, Width, Height, Code, Count, Scale: Integer;
  HasDelay: Boolean;

  function Receive: Integer;
  var
    Index: Integer;
  begin
    Result:=AVERROR_EAGAIN;
    while True do
    begin
      Result:=Encoder.ReceivePacket(Packet);
      if (Result = AVERROR_EAGAIN) OR (Result = AVERROR_EOF) then
        Exit;
      Check(Result = 0, 'Receive reordered video packet');
      Index:=Length(ExpectedPTS);
      SetLength(ExpectedPTS, Index + 1);
      SetLength(ExpectedDTS, Index + 1);
      ExpectedPTS[Index]:=Packet.pts;
      ExpectedDTS[Index]:=Packet.dts;
      HasDelay:=HasDelay OR (Packet.pts <> Packet.dts);
      Check(Output.WritePacket(Packet, StreamIndex) = 0, 'Mux reordered video packet');
      Check((Packet.pts = ExpectedPTS[Index]) AND (Packet.dts = ExpectedDTS[Index]), 'Mux must preserve original distinct PTS/DTS');
      av_packet_unref(Packet);
    end;
  end;

begin
  Encoder:=TFFmpegEncoder.Create;
  Output:=TFFmpegOutput.Create;
  Input:=TFFmpegInput.Create;
  Frame:=nil;
  Packet:=nil;
  Options:=nil;
  HasDelay:=False;
  try
    Check(Output.Allocate('mp4', AFilename) = 0, 'Allocate timestamp-test MP4');
    Output.FormatContext.avoid_negative_ts:=AVFMT_AVOID_NEG_TS_DISABLED;
    // This is an explicit native muxer regression, not a fallback for the H.264 preset.
    Check(Encoder.AllocateByName('mpeg4') = 0, 'Allocate reordered MPEG-4 test encoder');
    Encoder.CodecContext.width:=32;
    Encoder.CodecContext.height:=24;
    Encoder.CodecContext.pix_fmt:=AV_PIX_FMT_YUV420P;
    Encoder.CodecContext.time_base.num:=1;
    Encoder.CodecContext.time_base.den:=25;
    Encoder.CodecContext.framerate.num:=25;
    Encoder.CodecContext.framerate.den:=1;
    Encoder.CodecContext.max_b_frames:=2;
    Encoder.CodecContext.gop_size:=12;
    Encoder.CodecContext.bit_rate:=200000;
    if Output.RequiresGlobalHeader then
      Encoder.CodecContext.flags:=Encoder.CodecContext.flags OR AV_CODEC_FLAG_GLOBAL_HEADER;
    Check(Encoder.Open = 0, 'Open reordered encoder with global headers');
    Check(Output.AddStream(Encoder.CodecContext, StreamIndex) = 0, 'Copy negotiated video codec parameters');
    Check(Output.WriteHeader(Options, Default(TAVIOInterruptCB)) = 0, 'Write reordered MP4 header');
    Frame:=av_frame_alloc;
    Packet:=av_packet_alloc;
    Check(Assigned(Frame) AND Assigned(Packet), 'Allocate reordered test buffers');
    Frame.width:=32;
    Frame.height:=24;
    Frame.format:=Ord(AV_PIX_FMT_YUV420P);
    Frame.duration:=1;
    Check(av_frame_get_buffer(Frame, 32) = 0, 'Allocate reordered YUV planes');
    for I:=0 to 11 do
    begin
      Check(av_frame_make_writable(Frame) = 0, 'Retained encoder input must be writable before reuse');
      for Plane:=0 to 2 do
      begin
        Width:=32;
        Height:=24;
        if Plane > 0 then
        begin
          Width:=16;
          Height:=12;
        end;
        for Y:=0 to Height - 1 do
          if Plane = 0 then
            FillChar(PByte(NativeUInt(Frame.data[Plane]) + NativeUInt(Y) * NativeUInt(Frame.linesize[Plane]))^, Width, 32 + I * 12)
          else
            FillChar(PByte(NativeUInt(Frame.data[Plane]) + NativeUInt(Y) * NativeUInt(Frame.linesize[Plane]))^, Width, 128);
      end;
      Frame.pts:=I;
      repeat
        Code:=Encoder.SendFrame(Frame);
        if Code = AVERROR_EAGAIN then
          Check(Receive <> AVERROR_EAGAIN, 'Reordered encoder backpressure must make progress');
      until Code <> AVERROR_EAGAIN;
      Check(Code = 0, 'Send reordered frame');
      Receive;
    end;
    repeat
      Code:=Encoder.SendFrame(nil);
      if Code = AVERROR_EAGAIN then
        Check(Receive <> AVERROR_EAGAIN, 'Drain backpressure must make progress');
    until Code <> AVERROR_EAGAIN;
    Check(Code = 0, 'Start reordered drain');
    Check(Receive = AVERROR_EOF, 'Complete reordered encoder drain');
    Check(HasDelay AND (Length(ExpectedPTS) = 12) AND (ExpectedDTS[0] < 0), 'Fixture must exercise distinct/reordered timestamps and negative initial DTS');
    Check(Output.Finish = 0, 'Finalize reordered MP4');
    Check(Input.ProbeFile(AFilename, Options, Default(TAVIOInterruptCB)) = 0, 'Reopen finalized reordered MP4');
    Check((PPtrIdx(Input.FormatContext.streams, 0).time_base.num = 1) AND
      (PPtrIdx(Input.FormatContext.streams, 0).time_base.den MOD 25 = 0), 'MP4 negotiated time base represents all encoder ticks');
    Scale:=PPtrIdx(Input.FormatContext.streams, 0).time_base.den DIV 25;
    Count:=0;
    Code:=Input.ReadPacket(Packet);
    while Code = 0 do
    begin
      Check(Count < Length(ExpectedPTS), 'No extra demuxed video packets');
      Check((Packet.pts = ExpectedPTS[Count] * Scale) AND (Packet.dts = ExpectedDTS[Count] * Scale), 'Muxed PTS/DTS must independently match encoder timestamps after rational rescale');
      Inc(Count);
      av_packet_unref(Packet);
      Code:=Input.ReadPacket(Packet);
    end;
    Check((Count = 12) AND (Code = AVERROR_EOF), 'All delayed packets must survive finalization with clean EOF');
  finally
    av_dict_free(@Options);
    av_frame_free(@Frame);
    av_packet_free(@Packet);
    Input.Free;
    Output.Free;
    Encoder.Free;
  end;
end;

procedure Run;
var
  Directory: TMediaTestDirectory;
  Output: TFFmpegOutput;
  Destination: TMediaLocalOutput;
  Reader: IMediaReader;
  Settings: TMediaReaderSettings;
  Sample: IMediaSample;
  Audio: IMediaAudioBuffer;
  Bytes: TBytes;
  Count: Integer;
  First, Last: SmallInt;
  Name: String;
begin
  Directory:=TMediaTestDirectory.Create;
  try
    Name:=Directory.FileName('samples.wav');
    Destination:=TMediaLocalOutput.Create(Name, False);
    try
      WriteWave(Destination.Temporary, False);
      Check(NOT FileExists(Name), 'Muxer finish does not itself publish high-level destination');
      Destination.Publish;
    finally
      Destination.Free;
    end;
    Settings:=TMediaReaderSettings.Default;
    Settings.Channels:=1;
    Settings.VideoStreamIndex:=-2;
    Reader:=TMediaReader.OpenFile(Name, Settings);
    Count:=0;
    First:=0;
    Last:=0;
    while Reader.ReadSample(Sample) = mrsSample do
    begin
      Audio:=Sample AS IMediaAudioBuffer;
      Bytes:=Audio.CopyBytes;
      if Count = 0 then
        First:=PSmallInt(@Bytes[0])^;
      Last:=PSmallInt(@Bytes[Length(Bytes) - 2])^;
      Inc(Count, Audio.SampleCount);
    end;
    Check((Count = 480) AND (First = 1234) AND (Last = -2345), 'Finalized WAV decodes exact samples/markers after negotiated time-base rescale');
    Reader.Close;
    Name:=Directory.FileName('failed.wav');
    Destination:=TMediaLocalOutput.Create(Name, False);
    try
      WriteWave(Destination.Temporary, True);
    finally
      Destination.Free;
    end;
    Check(NOT FileExists(Name), 'Failed muxer finalization remains unpublished');
    TestReorderedPacketTimes(Directory.FileName('reordered.mp4'));
    Output:=TFFmpegOutput.Create;
    try
      Check(Output.Allocate('mp4', Directory.FileName('header-only.mp4')) = 0, 'Allocate explicit MP4 muxer without creating output');
      Check(Output.RequiresGlobalHeader, 'MP4 exposes required encoder global headers before open');
      Output.Close;
      Check(NOT FileExists(Directory.FileName('header-only.mp4')), 'Allocation/close without header never creates output');
      Check(Output.Allocate('tffmpeg_missing_muxer', Directory.FileName('missing.bin')) < 0, 'Missing muxer reports native failure');
      Check(NOT Assigned(Output.FormatContext), 'Failed allocation releases format context');
    finally
      Output.Free;
    end;
  finally
    Directory.Free;
  end;
  WriteLn('PASS: file muxer lifecycle, codec parameter copy, negotiated packet rescale, borrowed timestamps, exact WAV samples and finalization failure');
end;

begin
  try
    Run;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
