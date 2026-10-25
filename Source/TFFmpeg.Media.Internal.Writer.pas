unit TFFmpeg.Media.Internal.Writer;

interface

uses
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Writer;

function OpenMediaOutput(const AFilename: String; const ASettings: TMediaWriterSettings;
  const AToken: IMediaCancellationToken): IMediaWriter;

implementation

uses
{$IFDEF FPC}
  SysUtils,
  Math,
{$ELSE}
  System.SysUtils,
  System.Math,
{$ENDIF}
  FFTypes,
  libavcodec,
  libavcodec_codec,
  libavcodec_codec_id,
  libavcodec_packet,
  libavformat,
  libavutil,
  libavutil_audio_fifo,
  libavutil_channel_layout,
  libavutil_dict,
  libavutil_error,
  libavutil_frame,
  libavutil_imgutils,
  libavutil_pixfmt,
  libavutil_rational,
  libavutil_samplefmt,
  libswresample,
  TFFmpeg.Encoder,
  TFFmpeg.Output,
  TFFmpeg.Utils,
  TFFmpeg.VideoScaler,
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Internal.Files,
  TFFmpeg.Media.Internal.Frames,
  TFFmpeg.Media.Internal.Native;

const
  MAX_AUDIO_SAMPLES = 1048576;
  AUDIO_INPUT_CHUNK = 4096;

type
  TMediaWriterSession = class(TInterfacedObject, IMediaWriter)
  private
    FSettings: TMediaWriterSettings;
    FState: TMediaWriterState;
    FOperation: TMediaOperation;
    FFile: TMediaLocalOutput;
    FOutput: TFFmpegOutput;
    FEncoders: Array[0..1] of TFFmpegEncoder;
    FStreamIndexes: Array[0..1] of Integer;
    FEncoderNames: Array[0..1] of String;
    FCodecNames: Array[0..1] of String;
    FPacket: PAVPacket;
    FVideoFrames: Int64;
    FLastVideoPTS: Int64;
    FAudioSamples: Int64;
    FAudioInputSamples: Int64;
    FAudioAnchor: TMediaTime;
    FAudioStartTicks: Int64;
    FResampler: PSwrContext;
    FFifo: PAVAudioFifo;
    FInputRate: Integer;
    FInputChannels: Integer;
    FInputFormat: TMediaSampleFormat;
    procedure CheckNative(ACode: Integer; ACategory: TMediaErrorCategory; const AOperation: String);
    procedure ConfigureVideo;
    procedure ConfigureAudio;
    procedure OpenEncoder(AIndex: Integer; const AOptions: TMediaOptions);
    procedure RequireActive(const AOperation: String);
    procedure Cleanup;
    procedure Fail;
    function ReceivePackets(AIndex: Integer; out ADone: Boolean): Integer;
    procedure SendFrame(AIndex: Integer; AFrame: PAVFrame);
    procedure DrainEncoder(AIndex: Integer);
    function AudioFrame(ASampleCount: Integer): PAVFrame;
    procedure ConvertAudio(AData: PByte; ASampleCount: Integer);
    procedure WriteAudioFrames(AFinal: Boolean);
    procedure SubmitVideoCore(const AFrame: IMediaVideoFrame; APTS, ADuration: Int64);
  public
    constructor Create(const AFilename: String; const ASettings: TMediaWriterSettings; const AToken: IMediaCancellationToken);
    destructor Destroy; override;
    function GetState: TMediaWriterState;
    function GetVideoEncoderName: String;
    function GetAudioEncoderName: String;
    function GetVideoCodecName: String;
    function GetAudioCodecName: String;
    procedure Start;
    procedure SubmitVideo(const AFrame: IMediaVideoFrame);
    procedure SubmitAudio(const ABuffer: IMediaAudioBuffer);
    procedure Finish;
    procedure Abort;
    procedure SubmitVideoAt(const AFrame: IMediaVideoFrame; const ATimestamp, ADuration: TMediaTime);
  end;

procedure MakeOptions(const AOptions: TMediaOptions; var ADictionary: PAVDictionary);
var
  I, Code: Integer;
  Key, Value: UTF8String;
begin
  for I:=0 to Length(AOptions) - 1 do
  begin
    Key:=StringToUTF8String(AOptions[I].Key);
    Value:=StringToUTF8String(AOptions[I].Value);
    Code:=av_dict_set(@ADictionary, PAnsiChar(Key), PAnsiChar(Value), 0);
    if Code < 0 then
      raise EFFmpegMediaError.Create(mecInvalidSettings, 'Writer options', FFmpegErrorText(Code), Code);
  end;
end;

procedure RequireConsumed(ADictionary: PAVDictionary; const AOperation: String);
var
  Entry: PAVDictionaryEntry;
begin
  Entry:=av_dict_get(ADictionary, '', nil, AV_DICT_IGNORE_SUFFIX);
  if Assigned(Entry) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, AOperation, 'Unrecognized option: ' + UTF8ToString(Entry.key));
end;

constructor TMediaWriterSession.Create(const AFilename: String; const ASettings: TMediaWriterSettings;
  const AToken: IMediaCancellationToken);
var
  Metadata: TMediaMetadata;
  I: Integer;
  Key, Value: UTF8String;
begin
  inherited Create;
  if (AFilename = '') OR (Pos(#0, AFilename) > 0) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Open writer', 'A local destination filename without NUL is required');
  ASettings.Validate;
  FSettings:=ASettings;
  FOperation:=TMediaOperation.Create(AToken, ASettings.TimeoutMilliseconds);
  FOperation.Check('Open writer');
  FOutput:=TFFmpegOutput.Create;
  // Allocate creates no file. Preflight codecs before reserving the sibling.
  CheckNative(FOutput.Allocate(ASettings.MuxerName, AFilename), mecUnsupported, 'Select muxer');
  FPacket:=av_packet_alloc;
  if NOT Assigned(FPacket) then
    raise EFFmpegMediaError.Create(mecEncode, 'Open writer', 'Cannot allocate packet');
  if ASettings.Video.Enabled then
    ConfigureVideo;
  if ASettings.Audio.Enabled then
    ConfigureAudio;
  if Assigned(FEncoders[0]) AND (avformat_query_codec(FOutput.FormatContext.oformat, FEncoders[0].CodecContext.codec_id, 0) <= 0) then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Preflight video container', 'Muxer does not declare support for the selected video codec');
  if Assigned(FEncoders[1]) AND (avformat_query_codec(FOutput.FormatContext.oformat, FEncoders[1].CodecContext.codec_id, 0) <= 0) then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Preflight audio container', 'Muxer does not declare support for the selected audio codec');
  if Assigned(FEncoders[0]) then
    CheckNative(FOutput.AddStream(FEncoders[0].CodecContext, FStreamIndexes[0]), mecUnsupported, 'Preflight video container');
  if Assigned(FEncoders[1]) then
    CheckNative(FOutput.AddStream(FEncoders[1].CodecContext, FStreamIndexes[1]), mecUnsupported, 'Preflight audio container');
  FOperation.Check('Open writer');
  FFile:=TMediaLocalOutput.Create(AFilename, ASettings.Overwrite);
  // Reallocate with the reserved sibling, retaining the opened encoders.
  CheckNative(FOutput.Allocate(ASettings.MuxerName, FFile.Temporary), mecUnsupported, 'Allocate output');
  if ASettings.Timing = mwtPreserve then
    FOutput.FormatContext.avoid_negative_ts:=AVFMT_AVOID_NEG_TS_DISABLED;
  Metadata:=ASettings.Metadata;
  for I:=0 to Length(Metadata) - 1 do
  begin
    Key:=StringToUTF8String(Metadata[I].Key);
    Value:=StringToUTF8String(Metadata[I].Value);
    CheckNative(av_dict_set(@FOutput.FormatContext.metadata, PAnsiChar(Key), PAnsiChar(Value), 0), mecEncode, 'Set output metadata');
  end;
  if Assigned(FEncoders[0]) then
  begin
    CheckNative(FOutput.AddStream(FEncoders[0].CodecContext, FStreamIndexes[0]), mecUnsupported, 'Add video stream');
    PPtrIdx(FOutput.FormatContext.streams, FStreamIndexes[0]).disposition:=AV_DISPOSITION_DEFAULT;
  end;
  if Assigned(FEncoders[1]) then
  begin
    CheckNative(FOutput.AddStream(FEncoders[1].CodecContext, FStreamIndexes[1]), mecUnsupported, 'Add audio stream');
    PPtrIdx(FOutput.FormatContext.streams, FStreamIndexes[1]).disposition:=AV_DISPOSITION_DEFAULT;
  end;
  FOperation.Check('Open writer');
end;

destructor TMediaWriterSession.Destroy;
begin
  Cleanup;
  FOperation.Free;
  inherited Destroy;
end;

procedure TMediaWriterSession.Cleanup;
begin
  // Close IO before releasing the interrupt bridge or deleting its sibling.
  FreeAndNil(FOutput);
  FreeAndNil(FEncoders[0]);
  FreeAndNil(FEncoders[1]);
  av_packet_free(@FPacket);
  swr_free(@FResampler);
  if Assigned(FFifo) then
    av_audio_fifo_free(FFifo);
  FFifo:=nil;
  FreeAndNil(FFile);
end;

procedure TMediaWriterSession.Fail;
begin
  FState:=mwsFailed;
  Cleanup;
end;

procedure TMediaWriterSession.CheckNative(ACode: Integer; ACategory: TMediaErrorCategory; const AOperation: String);
begin
  FOperation.Check(AOperation);
  if ACode < 0 then
    raise EFFmpegMediaError.Create(ACategory, AOperation, FFmpegErrorText(ACode), ACode);
end;

procedure TMediaWriterSession.OpenEncoder(AIndex: Integer; const AOptions: TMediaOptions);
var
  Options: PAVDictionary;
begin
  Options:=nil;
  try
    MakeOptions(AOptions, Options);
    if FOutput.RequiresGlobalHeader then
      FEncoders[AIndex].CodecContext.flags:=FEncoders[AIndex].CodecContext.flags OR AV_CODEC_FLAG_GLOBAL_HEADER;
    CheckNative(FEncoders[AIndex].Open(@Options), mecUnsupported, 'Open encoder ' + FEncoderNames[AIndex]);
    RequireConsumed(Options, 'Open encoder');
    FCodecNames[AIndex]:=UTF8ToString(avcodec_get_name(FEncoders[AIndex].CodecContext.codec_id));
  finally
    av_dict_free(@Options);
  end;
end;

procedure TMediaWriterSession.ConfigureVideo;
var
  Context: PAVCodecContext;
  Configs: Pointer;
  Count, I, Size: Integer;
  Supported: Boolean;
  Rate: PAVRational;
begin
  FEncoders[0]:=TFFmpegEncoder.Create;
  FEncoderNames[0]:=FSettings.Video.EncoderName;
  CheckNative(FEncoders[0].AllocateByName(FEncoderNames[0]), mecUnsupported, 'Select video encoder');
  FEncoderNames[0]:=UTF8ToString(FEncoders[0].Codec.name);
  Context:=FEncoders[0].CodecContext;
  if Context.codec_type <> AVMEDIA_TYPE_VIDEO then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Select video encoder', 'Encoder is not a video encoder');
  Configs:=nil;
  Count:=0;
  CheckNative(avcodec_get_supported_config(Context, nil, AV_CODEC_CONFIG_PIX_FORMAT, 0, @Configs, @Count), mecUnsupported, 'Query video formats');
  Supported:=NOT Assigned(Configs);
  for I:=0 to Count - 1 do
    Supported:=Supported OR (PInteger(NativeUInt(Configs) + NativeUInt(I) * SizeOf(Integer))^ = Ord(AV_PIX_FMT_YUV420P));
  if NOT Supported then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Select video encoder', 'Encoder does not support the writer YUV420P format');
  CheckNative(avcodec_get_supported_config(Context, nil, AV_CODEC_CONFIG_FRAME_RATE, 0, @Configs, @Count), mecUnsupported, 'Query video rates');
  Supported:=NOT Assigned(Configs);
  for I:=0 to Count - 1 do
  begin
    Rate:=PAVRational(NativeUInt(Configs) + NativeUInt(I) * SizeOf(TAVRational));
    Supported:=Supported OR (Int64(Rate.num) * FSettings.Video.FrameRate.Denominator = Int64(Rate.den) * FSettings.Video.FrameRate.Numerator);
  end;
  if NOT Supported then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Select video encoder', 'Encoder does not support the requested rational frame rate');
  Size:=av_image_get_buffer_size(AV_PIX_FMT_YUV420P, (FSettings.Video.Width + 31) AND NOT 31,
    (FSettings.Video.Height + 31) AND NOT 31, 32);
  if (Size < 0) OR (Size > MEDIA_MAX_BUFFER_BYTES - 4096) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Configure video', 'Aligned frame exceeds buffer limit');
  Context.width:=FSettings.Video.Width;
  Context.height:=FSettings.Video.Height;
  Context.pix_fmt:=AV_PIX_FMT_YUV420P;
  Context.time_base.num:=FSettings.Video.FrameRate.Denominator;
  Context.time_base.den:=FSettings.Video.FrameRate.Numerator;
  if FSettings.Timing = mwtPreserve then
  begin
    Context.time_base.num:=1;
    Context.time_base.den:=1000000;
  end;
  Context.framerate.num:=FSettings.Video.FrameRate.Numerator;
  Context.framerate.den:=FSettings.Video.FrameRate.Denominator;
  Context.sample_aspect_ratio.num:=1;
  Context.sample_aspect_ratio.den:=1;
  Context.bit_rate:=FSettings.Video.BitRate;
  // Frame.duration is expressed in this encoder's time base. Without this flag
  // native send discards it and muxing falls back to the nominal frame-rate hint.
  Context.flags:=Context.flags OR AV_CODEC_FLAG_FRAME_DURATION;
  Context.thread_count:=1;
  Context.colorspace:=AVCOL_SPC_SMPTE170M;
  Context.color_range:=AVCOL_RANGE_MPEG;
  if Context.codec_id = AV_CODEC_ID_H264 then
    Context.max_b_frames:=2;
  if FSettings.Timing = mwtPreserve then
    // Arbitrary VFR intervals plus reorder delay can shorten MP4's decode-time
    // duration even when its composition end is correct. Use the encoder's
    // no-reorder mode; never repair this by manufacturing packet DTS.
    Context.max_b_frames:=0;
  OpenEncoder(0, FSettings.Video.Options);
  if (Context.width <> FSettings.Video.Width) OR (Context.height <> FSettings.Video.Height) OR (Context.pix_fmt <> AV_PIX_FMT_YUV420P) then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Configure video', 'Encoder changed the fixed video dimensions/pixel format');
  if (FSettings.Timing = mwtPreserve) AND ((Context.max_b_frames > 0) OR (Context.has_b_frames > 0)) then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Configure timed video', 'Timestamp-preserving video requires an encoder configured without B-frame reordering');
end;

procedure TMediaWriterSession.ConfigureAudio;
var
  Context: PAVCodecContext;
  Configs: Pointer;
  Count, I: Integer;
  Supported: Boolean;
  Format: TAVSampleFormat;
begin
  FEncoders[1]:=TFFmpegEncoder.Create;
  FEncoderNames[1]:=FSettings.Audio.EncoderName;
  CheckNative(FEncoders[1].AllocateByName(FEncoderNames[1]), mecUnsupported, 'Select audio encoder');
  FEncoderNames[1]:=UTF8ToString(FEncoders[1].Codec.name);
  Context:=FEncoders[1].CodecContext;
  if Context.codec_type <> AVMEDIA_TYPE_AUDIO then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Select audio encoder', 'Encoder is not an audio encoder');
  Configs:=nil;
  Count:=0;
  CheckNative(avcodec_get_supported_config(Context, nil, AV_CODEC_CONFIG_SAMPLE_FORMAT, 0, @Configs, @Count), mecUnsupported, 'Query audio formats');
  Format:=AV_SAMPLE_FMT_S16;
  if Assigned(Configs) then
  begin
    if Count < 1 then
      raise EFFmpegMediaError.Create(mecUnsupported, 'Configure audio', 'Encoder has no supported sample format');
    Format:=TAVSampleFormat(PInteger(Configs)^);
    for I:=0 to Count - 1 do
      if PInteger(NativeUInt(Configs) + NativeUInt(I) * SizeOf(Integer))^ = Ord(AV_SAMPLE_FMT_S16) then
        Format:=AV_SAMPLE_FMT_S16;
  end;
  if NOT (Format IN [AV_SAMPLE_FMT_U8, AV_SAMPLE_FMT_S16, AV_SAMPLE_FMT_S32, AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_DBL,
    AV_SAMPLE_FMT_U8P, AV_SAMPLE_FMT_S16P, AV_SAMPLE_FMT_S32P, AV_SAMPLE_FMT_FLTP, AV_SAMPLE_FMT_DBLP, AV_SAMPLE_FMT_S64, AV_SAMPLE_FMT_S64P]) then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Configure audio', 'Unsupported encoder sample format');
  CheckNative(avcodec_get_supported_config(Context, nil, AV_CODEC_CONFIG_SAMPLE_RATE, 0, @Configs, @Count), mecUnsupported, 'Query audio rates');
  Supported:=NOT Assigned(Configs);
  for I:=0 to Count - 1 do
    Supported:=Supported OR (PInteger(NativeUInt(Configs) + NativeUInt(I) * SizeOf(Integer))^ = FSettings.Audio.SampleRate);
  if NOT Supported then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Configure audio', 'Encoder does not support the requested sample rate');
  Context.sample_fmt:=Format;
  Context.sample_rate:=FSettings.Audio.SampleRate;
  av_channel_layout_default(@Context.ch_layout, FSettings.Audio.Channels);
  CheckNative(avcodec_get_supported_config(Context, nil, AV_CODEC_CONFIG_CHANNEL_LAYOUT, 0, @Configs, @Count), mecUnsupported, 'Query audio layouts');
  Supported:=NOT Assigned(Configs);
  for I:=0 to Count - 1 do
    Supported:=Supported OR (av_channel_layout_compare(@Context.ch_layout,
      PAVChannelLayout(NativeUInt(Configs) + NativeUInt(I) * SizeOf(TAVChannelLayout))) = 0);
  if NOT Supported then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Configure audio', 'Encoder does not support the requested channel layout');
  Context.time_base.num:=1;
  Context.time_base.den:=Context.sample_rate;
  Context.bit_rate:=FSettings.Audio.BitRate;
  Context.thread_count:=1;
  OpenEncoder(1, FSettings.Audio.Options);
  if (Context.sample_rate <> FSettings.Audio.SampleRate) OR (Context.ch_layout.nb_channels <> FSettings.Audio.Channels) then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Configure audio', 'Encoder changed the fixed audio rate/channel count');
  if (Context.frame_size < 0) OR (Context.frame_size > MAX_AUDIO_SAMPLES) then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Configure audio', 'Encoder frame size exceeds the bounded FIFO');
  FFifo:=av_audio_fifo_alloc(Context.sample_fmt, Context.ch_layout.nb_channels, Max(Context.frame_size, 1024));
  if NOT Assigned(FFifo) then
    raise EFFmpegMediaError.Create(mecEncode, 'Configure audio', 'Cannot allocate audio FIFO');
end;

procedure TMediaWriterSession.RequireActive(const AOperation: String);
begin
  if NOT (FState IN [mwsConfiguring, mwsWriting]) then
    raise EFFmpegMediaError.Create(mecInvalidState, AOperation, 'Writer has finished, failed or been aborted');
end;

procedure TMediaWriterSession.Start;
var
  Options: PAVDictionary;
begin
  RequireActive('Start writer');
  if FState = mwsWriting then
    Exit;
  FOperation.RestartTimeout;
  Options:=nil;
  try
    try
      FOperation.Check('Start writer');
      MakeOptions(FSettings.Options, Options);
      CheckNative(FOutput.WriteHeader(Options, FOperation.Interrupt), mecInputOutput, 'Write header');
      RequireConsumed(Options, 'Write header');
      FState:=mwsWriting;
    except
      Fail;
      raise;
    end;
  finally
    av_dict_free(@Options);
  end;
end;

function TMediaWriterSession.ReceivePackets(AIndex: Integer; out ADone: Boolean): Integer;
var
  Code: Integer;
begin
  Result:=0;
  ADone:=False;
  while True do
  begin
    FOperation.Check('Receive encoded packet');
    Code:=FEncoders[AIndex].ReceivePacket(FPacket);
    if Code = AVERROR_EAGAIN then
      Exit;
    if Code = AVERROR_EOF then
    begin
      ADone:=True;
      Exit;
    end;
    CheckNative(Code, mecEncode, 'Receive encoded packet');
    try
      if (FPacket.size < 0) OR (FPacket.size > 64 * 1024 * 1024) then
        raise EFFmpegMediaError.Create(mecEncode, 'Write packet', 'Encoded packet exceeds 64 MiB');
      CheckNative(FOutput.WritePacket(FPacket, FStreamIndexes[AIndex]), mecInputOutput, 'Write packet');
      Inc(Result);
    finally
      av_packet_unref(FPacket);
    end;
  end;
end;

procedure TMediaWriterSession.SendFrame(AIndex: Integer; AFrame: PAVFrame);
var
  Code, Count: Integer;
  Done: Boolean;
begin
  while True do
  begin
    FOperation.Check('Send encoder frame');
    Code:=FEncoders[AIndex].SendFrame(AFrame);
    if Code <> AVERROR_EAGAIN then
      Break;
    // Retain this exact frame until send accepts it. Receive must make progress.
    Count:=ReceivePackets(AIndex, Done);
    if (Count = 0) OR Done then
      raise EFFmpegMediaError.Create(mecEncode, 'Send encoder frame', 'Encoder made no progress after EAGAIN');
  end;
  CheckNative(Code, mecEncode, 'Send encoder frame');
  ReceivePackets(AIndex, Done);
end;

procedure TMediaWriterSession.DrainEncoder(AIndex: Integer);
var
  Code, Count: Integer;
  Done: Boolean;
begin
  while True do
  begin
    FOperation.Check('Drain encoder');
    Code:=FEncoders[AIndex].SendFrame(nil);
    if Code <> AVERROR_EAGAIN then
      Break;
    Count:=ReceivePackets(AIndex, Done);
    if Done then
      Exit;
    if Count = 0 then
      raise EFFmpegMediaError.Create(mecEncode, 'Drain encoder', 'Encoder made no progress after EAGAIN');
  end;
  if Code <> AVERROR_EOF then
    CheckNative(Code, mecEncode, 'Drain encoder');
  ReceivePackets(AIndex, Done);
  if NOT Done then
    raise EFFmpegMediaError.Create(mecEncode, 'Drain encoder', 'Encoder did not reach EOF after draining');
end;

procedure TMediaWriterSession.SubmitVideo(const AFrame: IMediaVideoFrame);
begin
  RequireActive('Submit video');
  if NOT Assigned(AFrame) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Submit video', 'A video frame is required');
  if FSettings.Timing = mwtPreserve then
    SubmitVideoAt(AFrame, AFrame.Timestamp, AFrame.Duration)
  else
    SubmitVideoCore(AFrame, FVideoFrames, 1);
end;

procedure TMediaWriterSession.SubmitVideoAt(const AFrame: IMediaVideoFrame; const ATimestamp, ADuration: TMediaTime);
var
  EndTime: TMediaTime;
begin
  RequireActive('Submit timed video');
  if FSettings.Timing <> mwtPreserve then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Submit timed video', 'Explicit timing requires the preserve timestamp policy');
  if NOT ATimestamp.Valid OR (ATimestamp.Microseconds < 0) OR NOT ADuration.Valid OR (ADuration.Microseconds < 1) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Submit timed video', 'Known nonnegative timestamp and positive duration are required');
  EndTime:=ATimestamp.Add(ADuration);
  if EndTime.Compare(ATimestamp) <= 0 then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Submit timed video', 'Video interval must advance');
  if (FVideoFrames > 0) AND (ATimestamp.Microseconds <= FLastVideoPTS) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Submit timed video', 'Video timestamps must increase strictly');
  SubmitVideoCore(AFrame, ATimestamp.Microseconds, ADuration.Microseconds);
end;

procedure TMediaWriterSession.SubmitVideoCore(const AFrame: IMediaVideoFrame; APTS, ADuration: Int64);
var
  Source, Converted: PAVFrame;
  Backing: TBytes;
begin
  RequireActive('Submit video');
  if NOT Assigned(FEncoders[0]) OR NOT Assigned(AFrame) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Submit video', 'Video stream and frame are required');
  if (AFrame.Width <> FSettings.Video.Width) OR (AFrame.Height <> FSettings.Video.Height) OR
    NOT (AFrame.PixelFormat IN [mpfRGB24, mpfBGRA32]) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Submit video', 'Frame must match configured dimensions and use RGB24/BGRA32');
  if FVideoFrames = High(Int64) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Submit video', 'Frame index overflow');
  FOperation.RestartTimeout;
  Source:=nil;
  Converted:=nil;
  try
    try
      FOperation.Check('Submit video');
      if FState = mwsConfiguring then
        Start;
      Source:=ReferenceVideo(AFrame, Backing);
      CheckNative(TFFmpegVideoScaler.Scale(Source, AFrame.Width, AFrame.Height, AV_PIX_FMT_YUV420P, Converted), mecEncode, 'Convert video');
      Converted.pts:=APTS;
      Converted.duration:=ADuration;
      Converted.colorspace:=FEncoders[0].CodecContext.colorspace;
      Converted.color_range:=FEncoders[0].CodecContext.color_range;
      SendFrame(0, Converted);
      FLastVideoPTS:=APTS;
      Inc(FVideoFrames);
    except
      Fail;
      raise;
    end;
  finally
    av_frame_free(@Converted);
    av_frame_free(@Source);
  end;
end;

function TMediaWriterSession.AudioFrame(ASampleCount: Integer): PAVFrame;
var
  Frame: PAVFrame;
  Context: PAVCodecContext;
begin
  Result:=nil;
  if (ASampleCount < 1) OR (ASampleCount > MAX_AUDIO_SAMPLES) then
    raise EFFmpegMediaError.Create(mecEncode, 'Allocate audio', 'Audio block exceeds sample bound');
  Context:=FEncoders[1].CodecContext;
  Frame:=av_frame_alloc;
  if NOT Assigned(Frame) then
    raise EFFmpegMediaError.Create(mecEncode, 'Allocate audio', 'Cannot allocate audio frame');
  try
    Frame.format:=Ord(Context.sample_fmt);
    Frame.sample_rate:=Context.sample_rate;
    Frame.nb_samples:=ASampleCount;
    CheckNative(av_channel_layout_copy(@Frame.ch_layout, @Context.ch_layout), mecEncode, 'Copy audio layout');
    CheckNative(av_frame_get_buffer(Frame, 0), mecEncode, 'Allocate audio samples');
    Result:=Frame;
    Frame:=nil;
  finally
    av_frame_free(@Frame);
  end;
end;

procedure TMediaWriterSession.WriteAudioFrames(AFinal: Boolean);
var
  Frame: PAVFrame;
  Available, FrameSize, Count: Integer;
begin
  FrameSize:=FEncoders[1].CodecContext.frame_size;
  if FrameSize = 0 then
    FrameSize:=1024;
  while True do
  begin
    Available:=av_audio_fifo_size(FFifo);
    if (Available = 0) OR ((Available < FrameSize) AND NOT AFinal) then
      Exit;
    Count:=Min(Available, FrameSize);
    Frame:=AudioFrame(Count);
    try
      if av_audio_fifo_read(FFifo, PPointer(Frame.extended_data), Count) <> Count then
        raise EFFmpegMediaError.Create(mecEncode, 'Read audio FIFO', 'FIFO read did not return the requested sample count');
      if FAudioStartTicks > High(Int64) - FAudioSamples then
        raise EFFmpegMediaError.Create(mecEncode, 'Submit audio', 'Audio timestamp overflow');
      Frame.pts:=FAudioStartTicks + FAudioSamples;
      Frame.duration:=Count;
      if FAudioSamples > High(Int64) - Count then
        raise EFFmpegMediaError.Create(mecEncode, 'Submit audio', 'Sample index overflow');
      // Native send handles short final frames and their discard-padding metadata.
      // Feeding a padded application frame here would lose the true duration.
      SendFrame(1, Frame);
      Inc(FAudioSamples, Count);
    finally
      av_frame_free(@Frame);
    end;
  end;
end;

procedure TMediaWriterSession.ConvertAudio(AData: PByte; ASampleCount: Integer);
var
  Frame: PAVFrame;
  Capacity, Count: Integer;
  Input: PPByte;
begin
  Input:=nil;
  if Assigned(AData) then
    Input:=@AData;
  repeat
    Capacity:=swr_get_out_samples(FResampler, ASampleCount);
    CheckNative(Capacity, mecEncode, 'Bound audio conversion');
    Capacity:=Max(Capacity, 1);
    Frame:=AudioFrame(Capacity);
    try
      Count:=swr_convert(FResampler, Frame.extended_data, Capacity, Input, ASampleCount);
      CheckNative(Count, mecEncode, 'Convert audio');
      if av_audio_fifo_size(FFifo) > MAX_AUDIO_SAMPLES - Count then
        raise EFFmpegMediaError.Create(mecEncode, 'Convert audio', 'Pending audio exceeds FIFO bound');
      if (Count > 0) AND (av_audio_fifo_write(FFifo, PPointer(Frame.extended_data), Count) <> Count) then
        raise EFFmpegMediaError.Create(mecEncode, 'Convert audio', 'Cannot write converted samples to FIFO');
      WriteAudioFrames(False);
    finally
      av_frame_free(@Frame);
    end;
    // A non-nil input is consumed once. Nil input drains until no tail remains.
    if Assigned(AData) then
      Exit;
  until Count = 0;
end;

procedure TMediaWriterSession.SubmitAudio(const ABuffer: IMediaAudioBuffer);
var
  Bytes: TBytes;
  Layout: TMediaChannelLayout;
  NativeLayout: TAVChannelLayout;
  Format: TAVSampleFormat;
  Context: PAVCodecContext;
  SampleBytes, Offset, Count: Integer;
  Required: Int64;
  Expected: TMediaTime;
  Difference: Int64;
begin
  RequireActive('Submit audio');
  if NOT Assigned(FEncoders[1]) OR NOT Assigned(ABuffer) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Submit audio', 'Audio stream and buffer are required');
  Layout:=ABuffer.ChannelLayout;
  Layout.Validate;
  if (ABuffer.SampleCount < 1) OR (ABuffer.SampleCount > MAX_AUDIO_SAMPLES) OR (ABuffer.SampleRate < 8000) OR
    (ABuffer.SampleRate > 192000) OR NOT (ABuffer.SampleFormat IN [msfS16, msfFloat32]) OR
    NOT (((Layout.Channels = 1) AND (Layout.Name = 'mono')) OR ((Layout.Channels = 2) AND (Layout.Name = 'stereo'))) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Submit audio', 'Input requires bounded packed S16/float, 8-192 kHz and named mono/stereo');
  if Assigned(FResampler) AND ((ABuffer.SampleRate <> FInputRate) OR (Layout.Channels <> FInputChannels) OR (ABuffer.SampleFormat <> FInputFormat)) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Submit audio', 'Input audio format changes require a new writer');
  SampleBytes:=2;
  Format:=AV_SAMPLE_FMT_S16;
  if ABuffer.SampleFormat = msfFloat32 then
  begin
    SampleBytes:=4;
    Format:=AV_SAMPLE_FMT_FLT;
  end;
  SampleBytes:=SampleBytes * Layout.Channels;
  Required:=Int64(ABuffer.SampleCount) * SampleBytes;
  Bytes:=ABuffer.CopyBytes;
  if (Required > MEDIA_MAX_BUFFER_BYTES) OR (Length(Bytes) <> Required) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Submit audio', 'PCM byte count does not match its descriptor');
  if FAudioInputSamples > High(Int64) - ABuffer.SampleCount then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Submit audio', 'Input sample count overflow');
  if FSettings.Timing = mwtPreserve then
  begin
    if NOT ABuffer.Timestamp.Valid OR (ABuffer.Timestamp.Microseconds < 0) then
      raise EFFmpegMediaError.Create(mecInvalidSettings, 'Submit audio', 'Timestamp preservation requires known nonnegative audio timestamps');
    if NOT Assigned(FResampler) AND (ABuffer.Timestamp.Microseconds > 0) AND
      (FEncoders[1].CodecContext.codec_id = AV_CODEC_ID_AAC) AND
      ((FSettings.MuxerName = 'mp4') OR (FSettings.MuxerName = 'mov') OR (FSettings.MuxerName = 'ipod') OR
      (FSettings.MuxerName = '3gp') OR (FSettings.MuxerName = '3g2') OR (FSettings.MuxerName = 'ismv')) then
      raise EFFmpegMediaError.Create(mecUnsupported, 'Submit audio',
        'This MP4/AAC muxer cannot preserve delayed audio and gapless trim together; select an explicit compatible output preset');
    if Assigned(FResampler) then
    begin
      Expected:=FAudioAnchor.Add(TMediaTime.FromTicks(FAudioInputSamples, TMediaRate.Create(1, FInputRate)));
      Difference:=ABuffer.Timestamp.Subtract(Expected).Microseconds;
      if (Difference < -2) OR (Difference > 2) then
        raise EFFmpegMediaError.Create(mecUnsupported, 'Submit audio', 'Audio timestamp discontinuity is unsupported; submit a continuous sample-count timeline');
    end;
  end;
  FOperation.RestartTimeout;
  try
    FOperation.Check('Submit audio');
    if FState = mwsConfiguring then
      Start;
    if NOT Assigned(FResampler) then
    begin
      Context:=FEncoders[1].CodecContext;
      NativeLayout:=Default(TAVChannelLayout);
      av_channel_layout_default(@NativeLayout, Layout.Channels);
      try
        CheckNative(swr_alloc_set_opts2(@FResampler, @Context.ch_layout, Context.sample_fmt, Context.sample_rate,
          @NativeLayout, Format, ABuffer.SampleRate, 0, nil), mecUnsupported, 'Allocate encoder resampler');
        CheckNative(swr_init(FResampler), mecUnsupported, 'Initialize encoder resampler');
      finally
        av_channel_layout_uninit(@NativeLayout);
      end;
      FInputRate:=ABuffer.SampleRate;
      FInputChannels:=Layout.Channels;
      FInputFormat:=ABuffer.SampleFormat;
      if FSettings.Timing = mwtPreserve then
      begin
        FAudioAnchor:=ABuffer.Timestamp;
        FAudioStartTicks:=FAudioAnchor.ToTicks(TMediaRate.Create(1, FSettings.Audio.SampleRate));
      end;
    end;
    Offset:=0;
    while Offset < ABuffer.SampleCount do
    begin
      Count:=Min(AUDIO_INPUT_CHUNK, ABuffer.SampleCount - Offset);
      ConvertAudio(@Bytes[Offset * SampleBytes], Count);
      Inc(Offset, Count);
    end;
    Inc(FAudioInputSamples, ABuffer.SampleCount);
  except
    Fail;
    raise;
  end;
end;

procedure TMediaWriterSession.Finish;
begin
  if FState = mwsFinished then
    Exit;
  RequireActive('Finish writer');
  FOperation.RestartTimeout;
  try
    FOperation.Check('Finish writer');
    if (Assigned(FEncoders[0]) AND (FVideoFrames = 0)) OR (Assigned(FEncoders[1]) AND (FAudioInputSamples = 0)) then
      raise EFFmpegMediaError.Create(mecInvalidState, 'Finish writer', 'Each enabled stream requires at least one submitted sample');
    if Assigned(FEncoders[1]) then
    begin
      ConvertAudio(nil, 0);
      WriteAudioFrames(True);
      DrainEncoder(1);
    end;
    if Assigned(FEncoders[0]) then
      DrainEncoder(0);
    CheckNative(FOutput.Finish, mecInputOutput, 'Finalize output');
    FOperation.Check('Publish output');
    FFile.Publish;
    FState:=mwsFinished;
    Cleanup;
  except
    Fail;
    raise;
  end;
end;

procedure TMediaWriterSession.Abort;
begin
  if FState IN [mwsFinished, mwsAborted, mwsFailed] then
    Exit;
  FState:=mwsAborted;
  Cleanup;
end;

function TMediaWriterSession.GetState: TMediaWriterState;
begin
  Result:=FState;
end;

function TMediaWriterSession.GetVideoEncoderName: String;
begin
  Result:=FEncoderNames[0];
end;

function TMediaWriterSession.GetAudioEncoderName: String;
begin
  Result:=FEncoderNames[1];
end;

function TMediaWriterSession.GetVideoCodecName: String;
begin
  Result:=FCodecNames[0];
end;

function TMediaWriterSession.GetAudioCodecName: String;
begin
  Result:=FCodecNames[1];
end;

function OpenMediaOutput(const AFilename: String; const ASettings: TMediaWriterSettings;
  const AToken: IMediaCancellationToken): IMediaWriter;
begin
  Result:=TMediaWriterSession.Create(AFilename, ASettings, AToken);
end;

end.
