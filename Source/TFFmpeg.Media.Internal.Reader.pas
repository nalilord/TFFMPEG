unit TFFmpeg.Media.Internal.Reader;

interface

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Reader;

function ProbeLocalFile(const AFilename: String; const ASettings: TMediaInputSettings; const AToken: IMediaCancellationToken): TMediaInfo;
function ProbeOwnedBytes(const ABytes: TBytes; const ASettings: TMediaInputSettings; const AToken: IMediaCancellationToken): TMediaInfo;
function OpenMediaFile(const AFilename: String; const ASettings: TMediaReaderSettings; const AToken: IMediaCancellationToken): IMediaReader;
function OpenMediaBytes(const ABytes: TBytes; const ASettings: TMediaReaderSettings; const AToken: IMediaCancellationToken): IMediaReader;
function OpenMediaURL(const AURL: String; const ASettings: TMediaReaderSettings; const AToken: IMediaCancellationToken): IMediaReader;
function ProbeRemoteURL(const AURL: String; const ASettings: TMediaInputSettings; const AToken: IMediaCancellationToken): TMediaInfo;
// Invoked only by a device worker that owns backend registration and COM.
function OpenMediaDevice(const ADeviceName, AFormatName: String; const ASettings: TMediaReaderSettings;
  const AToken: IMediaCancellationToken): IMediaReader;

implementation

uses
{$IFDEF FPC}
  Math,
{$ELSE}
  System.Math,
{$ENDIF}
  libavcodec_codec,
  libavcodec_codec_id,
  libavcodec_codec_par,
  libavcodec_packet,
  libavformat,
  libavformat_avio,
  libavutil,
  libavutil_channel_layout,
  libavutil_dict,
  libavutil_display,
  libavutil_error,
  libavutil_frame,
  libavutil_mathematics,
  libavutil_pixdesc,
  libavutil_pixfmt,
  libavutil_rational,
  libavutil_samplefmt,
  TFFmpeg.Decoder,
  TFFmpeg.AudioResampler,
  TFFmpeg.VideoScaler,
  TFFmpeg.Input,
  TFFmpeg.Utils,
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Internal.Frames,
  TFFmpeg.Media.Internal.Native;

type
  TMediaReaderSession = class(TInterfacedObject, IMediaReader)
  private
    FInput: TFFmpegInput;
    FOperation: TMediaOperation;
    FDecoders: Array[0..1] of TFFmpegDecoder;
    FStreamIndexes: Array[0..1] of Integer;
    FTimeBases: Array[0..1] of TMediaRate;
    FDrainSent: Array[0..1] of Boolean;
    FDecoderDone: Array[0..1] of Boolean;
    FPacket: PAVPacket;
    FFrame: PAVFrame;
    FPendingDecoder: Integer;
    FDemuxDone: Boolean;
    FInfo: TMediaInfo;
    FSettings: TMediaReaderSettings;
    FOrigin: TMediaTime;
    FOpened: Boolean;
    FFailed: Boolean;
    FDeviceInput: Boolean;
    FTerminal: TMediaReadStatus;
    FResampler: TFFmpegAudioResampler;
    FResamplerOpen: Boolean;
    FAudioDrained: Boolean;
    FAudioInputLayout: TAVChannelLayout;
    FAudioInputFormat: Integer;
    FAudioInputRate: Integer;
    FAudioAnchor: TMediaTime;
    FAudioOutputSamples: Int64;
    FAudioInputSamples: Int64;
    FVideoWidth: Integer;
    FVideoHeight: Integer;
    FVideoFormat: Integer;
    function FrameTime(ADecoder: Integer; AValue: Int64): TMediaTime;
    function VideoSample: IMediaSample;
    function AudioSample(AFlush: Boolean): IMediaSample;
    procedure ResetPump;
    function Pump(out ASample: IMediaSample): TMediaReadStatus;
  public
    constructor Create(const AFilename: String; const ABytes: TBytes; AUseBytes: Boolean;
      const ASettings: TMediaReaderSettings; const AToken: IMediaCancellationToken; AUseURL: Boolean = False;
      const ADeviceFormat: String = '');
    destructor Destroy; override;
    function GetInfo: TMediaInfo;
    function GetPresentationOrigin: TMediaTime;
    function ReadSample(out ASample: IMediaSample): TMediaReadStatus;
    procedure Seek(const APosition: TMediaTime);
    procedure Close;
  end;

procedure CheckNative(ACode: Integer; const AOperation: String);
begin
  if ACode < 0 then
    raise EFFmpegMediaError.Create(mecInputOutput, AOperation, FFmpegErrorText(ACode), ACode);
end;

function PublicRate(const AValue: TAVRational): TMediaRate;
begin
  Result:=TMediaRate.Unknown;
  if (AValue.num > 0) AND (AValue.den > 0) then
    Result:=TMediaRate.Create(AValue.num, AValue.den);
end;

function PublicTime(AValue: Int64; const ATimeBase: TMediaRate; AEstimated: Boolean = False): TMediaTime;
begin
  Result:=TMediaTime.Unknown;
  if (AValue <> AV_NOPTS_VALUE) AND ATimeBase.Known then
    Result:=TMediaTime.FromTicks(AValue, ATimeBase, AEstimated);
end;

function PublicMetadata(ADictionary: PAVDictionary): TMediaMetadata;
var
  Entry: PAVDictionaryEntry;
  I: Integer;
begin
  Result:=nil;
  SetLength(Result, av_dict_count(ADictionary));
  Entry:=nil;
  I:=0;
  Entry:=av_dict_iterate(ADictionary, Entry);
  while Assigned(Entry) do
  begin
    Result[I]:=TMediaMetadataEntry.Create(UTF8PtrToString(Entry.key), UTF8PtrToString(Entry.value));
    Inc(I);
    Entry:=av_dict_iterate(ADictionary, Entry);
  end;
end;

function PublicLayout(const ALayout: TAVChannelLayout): TMediaChannelLayout;
var
  Buffer: Array[0..2047] of AnsiChar;
  Names: TMediaStrings;
  I, Required: Integer;
  Description: UTF8String;
begin
  Result:=Default(TMediaChannelLayout);
  if ALayout.nb_channels <= 0 then
    Exit;
  if (ALayout.order <> AV_CHANNEL_ORDER_UNSPEC) AND (ALayout.nb_channels <= MEDIA_MAX_CHANNELS) then
  begin
    SetLength(Names, ALayout.nb_channels);
    for I:=0 to ALayout.nb_channels - 1 do
    begin
      FillChar(Buffer, SizeOf(Buffer), 0);
      CheckNative(av_channel_name(@Buffer[0], SizeOf(Buffer), av_channel_layout_channel_from_index(@ALayout, I)), 'Describe channel');
      Names[I]:=UTF8PtrToString(@Buffer[0]);
    end;
  end;
  FillChar(Buffer, SizeOf(Buffer), 0);
  Required:=av_channel_layout_describe(@ALayout, @Buffer[0], SizeOf(Buffer));
  CheckNative(Required, 'Describe channel layout');
  if Required < SizeOf(Buffer) then
    Description:=UTF8String(PAnsiChar(@Buffer[0]))
  else
  begin
    if Required > 1024 * 1024 then
      raise EFFmpegMediaError.Create(mecUnsupported, 'Probe layout', 'Channel description exceeds the 1 MiB metadata limit');
    SetLength(Description, Required + 1);
    CheckNative(av_channel_layout_describe(@ALayout, PAnsiChar(Description), Length(Description)), 'Describe channel layout');
  end;
  Result:=TMediaChannelLayout.Described(ALayout.nb_channels, UTF8PtrToString(PAnsiChar(Description)), Names);
end;

function PublicKind(AKind: TAVMediaType): TMediaKind;
begin
  Result:=mkUnknown;
  case AKind of
    AVMEDIA_TYPE_VIDEO: Result:=mkVideo;
    AVMEDIA_TYPE_AUDIO: Result:=mkAudio;
    AVMEDIA_TYPE_SUBTITLE: Result:=mkSubtitle;
    AVMEDIA_TYPE_ATTACHMENT: Result:=mkAttachment;
    AVMEDIA_TYPE_DATA: Result:=mkData;
  end;
end;

function PublicDispositions(AFlags: Integer): TMediaStrings;
var
  I, Count: Integer;
  Flag: Cardinal;
  Name: String;
begin
  Result:=nil;
  Count:=0;
  for I:=0 to 30 do
  begin
    Flag:=Cardinal(1) SHL I;
    if (Cardinal(AFlags) AND Flag) <> 0 then
    begin
      Name:=UTF8PtrToString(av_disposition_to_string(Integer(Flag)));
      if Name = '' then
        Name:='unknown-bit-' + IntToStr(I);
      SetLength(Result, Count + 1);
      Result[Count]:=Name;
      Inc(Count);
    end;
  end;
end;

function DisplayAspect(AWidth, AHeight: Integer; const APixelAspect: TMediaRate): TMediaRate;
var
  Numerator, Denominator, LeftValue, RightValue, Remainder: Int64;
begin
  Result:=TMediaRate.Unknown;
  if (AWidth <= 0) OR (AHeight <= 0) OR NOT APixelAspect.Known then
    Exit;
  Numerator:=Int64(AWidth) * APixelAspect.Numerator;
  Denominator:=Int64(AHeight) * APixelAspect.Denominator;
  LeftValue:=Numerator;
  RightValue:=Denominator;
  while RightValue <> 0 do
  begin
    Remainder:=LeftValue MOD RightValue;
    LeftValue:=RightValue;
    RightValue:=Remainder;
  end;
  Numerator:=Numerator DIV LeftValue;
  Denominator:=Denominator DIV LeftValue;
  if (Numerator <= High(Integer)) AND (Denominator <= High(Integer)) then
    Result:=TMediaRate.Create(Integer(Numerator), Integer(Denominator));
end;

function StreamSnapshot(AStream: PAVStream; AEstimatedDuration: Boolean): TMediaStreamInfo;
var
  Parameters: PAVCodecParameters;
  Color: TMediaColorInfo;
  SideData: PAVPacketSideData;
  Matrix: Array[0..8] of Integer;
  Values: Array[0..8] of Double;
  Angle: Double;
  I: Integer;
begin
  Result:=Default(TMediaStreamInfo);
  Parameters:=AStream.codecpar;
  Result.Index:=AStream.index;
  Result.Metadata:=PublicMetadata(AStream.metadata);
  Result.Language:=DictValue(AStream.metadata, 'language');
  Result.TimeBase:=PublicRate(AStream.time_base);
  Result.Duration:=PublicTime(AStream.duration, Result.TimeBase, AEstimatedDuration);
  Result.StartTime:=PublicTime(AStream.start_time, Result.TimeBase);
  Result.AttachedArt:=(AStream.disposition AND AV_DISPOSITION_ATTACHED_PIC) <> 0;
  Result.DefaultTrack:=(AStream.disposition AND AV_DISPOSITION_DEFAULT) <> 0;
  Result.Dispositions:=PublicDispositions(AStream.disposition);
  if AStream.nb_frames > 0 then
    Result.FrameCount:=TMediaOptionalInt64.Create(AStream.nb_frames);
  if NOT Assigned(Parameters) then
    Exit;

  Result.Kind:=PublicKind(Parameters.codec_type);
  Result.CodecName:=UTF8PtrToString(avcodec_get_name(Parameters.codec_id));
  if (Parameters.codec_type = AVMEDIA_TYPE_VIDEO) AND (Parameters.format >= 0) AND (Parameters.format < Ord(AV_PIX_FMT_NB)) then
    Result.PixelFormatName:=UTF8PtrToString(av_get_pix_fmt_name(TAVPixelFormat(Parameters.format)));
  if (Parameters.codec_type = AVMEDIA_TYPE_AUDIO) AND (Parameters.format >= 0) AND (Parameters.format < Ord(AV_SAMPLE_FMT_NB)) then
    Result.SampleFormatName:=UTF8PtrToString(av_get_sample_fmt_name(TAVSampleFormat(Parameters.format)));
  Result.BitsPerSample:=Parameters.bits_per_coded_sample;
  if (Result.BitsPerSample <= 0) AND (Parameters.codec_type = AVMEDIA_TYPE_AUDIO) then
    Result.BitsPerSample:=av_get_bits_per_sample(Parameters.codec_id);
  Result.Profile:=UTF8PtrToString(avcodec_profile_name(Parameters.codec_id, Parameters.profile));
  Result.DecoderAvailable:=Assigned(avcodec_find_decoder(Parameters.codec_id));
  if Parameters.bit_rate > 0 then
    Result.BitRate:=TMediaOptionalInt64.Create(Parameters.bit_rate);
  Result.Width:=Parameters.width;
  Result.Height:=Parameters.height;
  Result.FrameRate:=PublicRate(AStream.avg_frame_rate);
  Result.PixelAspect:=PublicRate(AStream.sample_aspect_ratio);
  if NOT Result.PixelAspect.Known then
    Result.PixelAspect:=PublicRate(Parameters.sample_aspect_ratio);
  Result.DisplayAspect:=DisplayAspect(Result.Width, Result.Height, Result.PixelAspect);
  Result.SampleRate:=Parameters.sample_rate;
  Result.ChannelLayout:=PublicLayout(Parameters.ch_layout);

  Color:=Default(TMediaColorInfo);
  Color.Matrix:=UTF8PtrToString(av_color_space_name(Parameters.color_space));
  Color.RangeName:=UTF8PtrToString(av_color_range_name(Parameters.color_range));
  Color.Primaries:=UTF8PtrToString(av_color_primaries_name(Parameters.color_primaries));
  Color.Transfer:=UTF8PtrToString(av_color_transfer_name(Parameters.color_trc));
  Color.ChromaLocation:=UTF8PtrToString(av_chroma_location_name(Parameters.chroma_location));
  Result.Color:=Color;

  SideData:=av_packet_side_data_get(Parameters.coded_side_data, Parameters.nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
  if Assigned(SideData) AND (SideData.size >= SizeOf(Matrix)) then
  begin
    Move(SideData.data^, Matrix, SizeOf(Matrix));
    for I:=0 to 8 do
      if (I MOD 3) = 2 then
        Values[I]:=Matrix[I] / 1073741824.0
      else
        Values[I]:=Matrix[I] / 65536.0;
    Result.DisplayTransform:=TMediaDisplayTransform.Create(Values);
    Angle:=av_display_rotation_get(@Matrix[0]);
    Result.RotationKnown:=NOT IsNan(Angle) AND NOT IsInfinite(Angle);
    if Result.RotationKnown then
      Result.RotationDegrees:=Angle;
  end;
end;

function Snapshot(AContext: PAVFormatContext): TMediaInfo;
var
  Streams: TMediaStreams;
  I: Integer;
  Estimated: Boolean;
begin
  Result:=Default(TMediaInfo);
  if Assigned(AContext.iformat) then
  begin
    Result.FormatName:=UTF8PtrToString(AContext.iformat.name);
    Result.FormatDescription:=UTF8PtrToString(AContext.iformat.long_name);
  end;
  Estimated:=AContext.duration_estimation_method = AVFMT_DURATION_FROM_BITRATE;
  Result.Duration:=PublicTime(AContext.duration, TMediaRate.Create(1, 1000000), Estimated);
  Result.StartTime:=PublicTime(AContext.start_time, TMediaRate.Create(1, 1000000));
  if AContext.bit_rate > 0 then
    Result.BitRate:=TMediaOptionalInt64.Create(AContext.bit_rate, True);
  Result.Seekable:=Assigned(AContext.pb) AND ((AContext.pb.seekable AND AVIO_SEEKABLE_NORMAL) <> 0);
  if Assigned(AContext.iformat) AND ((AContext.iformat.flags AND AVFMT_NOTIMESTAMPS) <> 0) then
    Result.Seekable:=False;
  Result.Metadata:=PublicMetadata(AContext.metadata);
  SetLength(Streams, AContext.nb_streams);
  for I:=0 to Length(Streams) - 1 do
    Streams[I]:=StreamSnapshot(PPtrIdx(AContext.streams, I), Estimated);
  Result.Streams:=Streams;
end;

function InputOptions(const ASettings: TMediaInputSettings): PAVDictionary;
var
  Options: TMediaOptions;
  I: Integer;
begin
  Result:=nil;
  try
    // Some demuxers return success after refusing additional streams. Reserve
    // one sentinel slot so an overflow cannot masquerade as a complete snapshot.
    CheckNative(av_dict_set(@Result, 'max_streams', PAnsiChar(AnsiString(IntToStr(ASettings.MaxStreams + 1))), 0), 'Set stream limit');
    CheckNative(av_dict_set(@Result, 'probesize', PAnsiChar(AnsiString(IntToStr(ASettings.MaxProbeBytes))), 0), 'Set probe limit');
    Options:=ASettings.Options;
    for I:=0 to Length(Options) - 1 do
      CheckNative(av_dict_set(@Result, PAnsiChar(StringToUTF8String(Options[I].Key)),
        PAnsiChar(StringToUTF8String(Options[I].Value)), 0), 'Set demuxer option');
  except
    av_dict_free(@Result);
    raise;
  end;
end;

procedure ValidateHTTPURL(const AURL: String);
begin
  if (AURL = '') OR (Pos(#0, AURL) > 0) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Open URL', 'An HTTP/HTTPS URL without NUL is required');
  if NOT SameText(Copy(AURL, 1, 7), 'http://') AND NOT SameText(Copy(AURL, 1, 8), 'https://') then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Open URL', 'Only HTTP and HTTPS URL input is supported');
end;

function ProbeInput(const AFilename: String; const ABytes: TBytes; AUseBytes: Boolean;
  const ASettings: TMediaInputSettings; const AToken: IMediaCancellationToken; AUseURL: Boolean = False): TMediaInfo;
var
  Input: TFFmpegInput;
  Operation: TMediaOperation;
  Options: PAVDictionary;
  Entry: PAVDictionaryEntry;
  Code: Integer;
  OperationName: String;
begin
  Result:=Default(TMediaInfo);
  ASettings.Validate;
  if AUseURL then
  begin
    OperationName:='Probe URL';
    ValidateHTTPURL(AFilename);
  end else
  if AUseBytes then
  begin
    OperationName:='Probe bytes';
    if (Length(ABytes) = 0) OR (Length(ABytes) > MEDIA_MAX_BUFFER_BYTES) then
      raise EFFmpegMediaError.Create(mecInvalidSettings, OperationName, 'Encoded input must contain 1 byte to 256 MiB');
  end else
  begin
    OperationName:='Probe file';
    if (AFilename = '') OR (Pos(#0, AFilename) > 0) then
      raise EFFmpegMediaError.Create(mecInvalidSettings, OperationName, 'A literal local filename without NUL is required');
  end;

  Operation:=TMediaOperation.Create(AToken, ASettings.TimeoutMilliseconds);
  try
    Operation.Check(OperationName);
    Input:=TFFmpegInput.Create;
    try
      Options:=InputOptions(ASettings);
      try
        if AUseURL then
          Code:=Input.ProbeURL(AFilename, Options, Operation.Interrupt)
        else
        if AUseBytes then
          Code:=Input.ProbeBytes(ABytes, Options, Operation.Interrupt)
        else
          Code:=Input.ProbeFile(AFilename, Options, Operation.Interrupt);
        Operation.Check(OperationName);
        CheckNative(Code, OperationName);
        Entry:=av_dict_iterate(Options, nil);
        if Assigned(Entry) then
          raise EFFmpegMediaError.Create(mecInvalidSettings, OperationName, 'Unconsumed demuxer option: ' + UTF8PtrToString(Entry.key));
        if Int64(Input.FormatContext.nb_streams) > ASettings.MaxStreams then
          raise EFFmpegMediaError.Create(mecUnsupported, OperationName, 'Stream limit exceeded');
        Result:=Snapshot(Input.FormatContext);
        Operation.Check(OperationName);
      finally
        av_dict_free(@Options);
      end;
    finally
      // Contexts borrow the interrupt state and must close before its release.
      Input.Free;
    end;
  finally
    Operation.Free;
  end;
end;

function ProbeLocalFile(const AFilename: String; const ASettings: TMediaInputSettings; const AToken: IMediaCancellationToken): TMediaInfo;
begin
  Result:=ProbeInput(AFilename, nil, False, ASettings, AToken);
end;

function ProbeOwnedBytes(const ABytes: TBytes; const ASettings: TMediaInputSettings; const AToken: IMediaCancellationToken): TMediaInfo;
begin
  Result:=ProbeInput('', ABytes, True, ASettings, AToken);
end;

constructor TMediaReaderSession.Create(const AFilename: String; const ABytes: TBytes; AUseBytes: Boolean;
  const ASettings: TMediaReaderSettings; const AToken: IMediaCancellationToken; AUseURL: Boolean; const ADeviceFormat: String);
var
  Options: PAVDictionary;
  Entry: PAVDictionaryEntry;
  Stream: PAVStream;
  Streams: TMediaStreams;
  I, Code: Integer;
  PresentationStart: TMediaTime;
  DelayBase: TAVRational;
  DelayTicks: Int64;
begin
  inherited Create;
  FPendingDecoder:=-1;
  FStreamIndexes[0]:=-1;
  FStreamIndexes[1]:=-1;
  ASettings.Validate;
  if AUseURL then
    ValidateHTTPURL(AFilename)
  else
  if AUseBytes then
  begin
    if (Length(ABytes) = 0) OR (Length(ABytes) > MEDIA_MAX_BUFFER_BYTES) then
      raise EFFmpegMediaError.Create(mecInvalidSettings, 'Open reader', 'Encoded input must contain 1 byte to 256 MiB');
  end else
  if (AFilename = '') OR (Pos(#0, AFilename) > 0) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Open reader', 'A literal local filename without NUL is required');

  FSettings:=ASettings;
  FDeviceInput:=ADeviceFormat <> '';
  FOperation:=TMediaOperation.Create(AToken, ASettings.Input.TimeoutMilliseconds);
  FOperation.Check('Open reader');
  FInput:=TFFmpegInput.Create;
  Options:=InputOptions(ASettings.Input);
  try
    if ADeviceFormat <> '' then
      Code:=FInput.ProbeDevice(AFilename, ADeviceFormat, Options, FOperation.Interrupt)
    else
    if AUseURL then
      Code:=FInput.ProbeURL(AFilename, Options, FOperation.Interrupt)
    else
    if AUseBytes then
      Code:=FInput.ProbeBytes(ABytes, Options, FOperation.Interrupt)
    else
      Code:=FInput.ProbeFile(AFilename, Options, FOperation.Interrupt);
    FOperation.Check('Open reader');
    CheckNative(Code, 'Open reader');
    Entry:=av_dict_iterate(Options, nil);
    if Assigned(Entry) then
      raise EFFmpegMediaError.Create(mecInvalidSettings, 'Open reader', 'Unconsumed demuxer option: ' + UTF8PtrToString(Entry.key));
    if Int64(FInput.FormatContext.nb_streams) > ASettings.Input.MaxStreams then
      raise EFFmpegMediaError.Create(mecUnsupported, 'Open reader', 'Stream limit exceeded');
    FInfo:=Snapshot(FInput.FormatContext);
  finally
    av_dict_free(@Options);
  end;

  FStreamIndexes[0]:=TMediaProbe.SelectStream(FInfo, mkVideo, ASettings.VideoStreamIndex);
  FStreamIndexes[1]:=TMediaProbe.SelectStream(FInfo, mkAudio, ASettings.AudioStreamIndex);
  if (FStreamIndexes[0] < 0) AND (FStreamIndexes[1] < 0) then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Open reader', 'No selected decodable audio/video stream');
  FOrigin:=TMediaTime.Unknown;
  Streams:=FInfo.Streams;
  for I:=0 to Length(Streams) - 1 do
    if ((Streams[I].Index = FStreamIndexes[0]) OR (Streams[I].Index = FStreamIndexes[1])) AND Streams[I].StartTime.Valid then
    begin
      PresentationStart:=Streams[I].StartTime;
      Stream:=PPtrIdx(FInput.FormatContext.streams, Streams[I].Index);
      if (Streams[I].Kind = mkAudio) AND (Stream.codecpar.initial_padding > 0) AND
        (UTF8PtrToString(FInput.FormatContext.iformat.name) = 'matroska,webm') then
      begin
        // Matroska subtracts CodecDelay from packet times. Native decoding then
        // trims those samples and advances PTS. Normalize the presentation start,
        // not the priming packet start; do not trim the PCM a second time.
        DelayBase.num:=1;
        DelayBase.den:=Stream.codecpar.sample_rate;
        if Stream.codecpar.codec_id = AV_CODEC_ID_OPUS then
          DelayBase.den:=48000;
        if DelayBase.den > 0 then
        begin
          DelayTicks:=av_rescale_q(Stream.codecpar.initial_padding, DelayBase, Stream.time_base);
          PresentationStart:=PresentationStart.Add(TMediaTime.FromTicks(DelayTicks, PublicRate(Stream.time_base)));
        end;
      end;
      if NOT FOrigin.Valid OR (PresentationStart.Compare(FOrigin) < 0) then
        FOrigin:=PresentationStart;
    end;
  if NOT FOrigin.Valid then
    FOrigin:=FInfo.StartTime;
  if NOT FOrigin.Valid then
    FOrigin:=TMediaTime.FromMicroseconds(0);

  for I:=0 to 1 do
    if FStreamIndexes[I] >= 0 then
    begin
      Stream:=PPtrIdx(FInput.FormatContext.streams, FStreamIndexes[I]);
      if (I = 1) AND (Stream.codecpar.ch_layout.nb_channels > MEDIA_MAX_CHANNELS) then
        raise EFFmpegMediaError.Create(mecUnsupported, 'Open reader', 'Selected audio exceeds the 32-channel input limit');
      FTimeBases[I]:=PublicRate(Stream.time_base);
      FDecoders[I]:=TFFmpegDecoder.Create;
      Code:=FDecoders[I].OpenLimited(avcodec_find_decoder(Stream.codecpar.codec_id), Stream.codecpar,
        MEDIA_MAX_PIXELS, MEDIA_MAX_BUFFER_BYTES DIV (MEDIA_MAX_CHANNELS * 8), Stream.time_base);
      if Code < 0 then
        raise EFFmpegMediaError.Create(mecDecode, 'Open decoder', FFmpegErrorText(Code), Code);
    end;

  FResampler:=TFFmpegAudioResampler.Create;
  FPacket:=av_packet_alloc;
  FFrame:=av_frame_alloc;
  if NOT Assigned(FPacket) OR NOT Assigned(FFrame) then
    raise EFFmpegMediaError.Create(mecDecode, 'Open reader', 'Cannot allocate decode buffers');
  ResetPump;
  FOperation.Check('Open reader');
  FOpened:=True;
end;

destructor TMediaReaderSession.Destroy;
begin
  Close;
  inherited Destroy;
end;

function OpenMediaDevice(const ADeviceName, AFormatName: String; const ASettings: TMediaReaderSettings;
  const AToken: IMediaCancellationToken): IMediaReader;
begin
  Result:=TMediaReaderSession.Create(ADeviceName, nil, False, ASettings, AToken, False, AFormatName);
end;

procedure TMediaReaderSession.Close;
var
  I: Integer;
begin
  FOpened:=False;
  av_packet_free(@FPacket);
  av_frame_free(@FFrame);
  FResampler.Free;
  FResampler:=nil;
  av_channel_layout_uninit(@FAudioInputLayout);
  for I:=0 to 1 do
  begin
    FDecoders[I].Free;
    FDecoders[I]:=nil;
  end;
  FInput.Free;
  FInput:=nil;
  // The input's native callbacks borrow this state until input close completes.
  FOperation.Free;
  FOperation:=nil;
end;

function TMediaReaderSession.GetInfo: TMediaInfo;
begin
  Result:=FInfo;
end;

function TMediaReaderSession.GetPresentationOrigin: TMediaTime;
begin
  Result:=FOrigin;
end;

procedure TMediaReaderSession.ResetPump;
var
  I: Integer;
begin
  av_packet_unref(FPacket);
  av_frame_unref(FFrame);
  FPendingDecoder:=-1;
  FDemuxDone:=False;
  for I:=0 to 1 do
  begin
    FDecoderDone[I]:=FStreamIndexes[I] < 0;
    FDrainSent[I]:=False;
  end;
  FResampler.Close;
  FResamplerOpen:=False;
  FAudioDrained:=FStreamIndexes[1] < 0;
  av_channel_layout_uninit(@FAudioInputLayout);
  FAudioAnchor:=TMediaTime.Unknown;
  FAudioOutputSamples:=0;
  FAudioInputSamples:=0;
  FVideoWidth:=0;
  FVideoHeight:=0;
  FVideoFormat:=-1;
end;

function TMediaReaderSession.FrameTime(ADecoder: Integer; AValue: Int64): TMediaTime;
begin
  Result:=PublicTime(AValue, FTimeBases[ADecoder]);
  if Result.Valid then
    Result:=Result.Subtract(FOrigin);
end;

function TMediaReaderSession.VideoSample: IMediaSample;
var
  Converted: PAVFrame;
  PixelFormat: TAVPixelFormat;
  Changed: Boolean;
  Duration: TMediaTime;
  Code, I: Integer;
  Streams: TMediaStreams;
  Stream: TMediaStreamInfo;
  Transform: TMediaDisplayTransform;
  Aspect: TMediaRate;
  Color: TMediaColorInfo;
  SideData: PAVFrameSideData;
  Angle: Double;
  J: Integer;
begin
  Result:=nil;
  if (FFrame.color_trc = AVCOL_TRC_SMPTE2084) OR (FFrame.color_trc = AVCOL_TRC_ARIB_STD_B67) then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Read video', 'HDR to SDR conversion requires tone mapping, which is unsupported');
  if NOT (FFrame.colorspace IN [AVCOL_SPC_RGB, AVCOL_SPC_BT709, AVCOL_SPC_UNSPECIFIED, AVCOL_SPC_FCC,
    AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M, AVCOL_SPC_SMPTE240M, AVCOL_SPC_BT2020_NCL]) then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Read video', 'Unsupported source color matrix');

  Changed:=(FVideoWidth <> 0) AND ((FVideoWidth <> FFrame.width) OR (FVideoHeight <> FFrame.height) OR (FVideoFormat <> FFrame.format));
  Aspect:=PublicRate(FFrame.sample_aspect_ratio);
  Transform:=FrameDisplayMatrix(FFrame);
  Streams:=FInfo.Streams;
  for I:=0 to Length(Streams) - 1 do
    if Streams[I].Index = FStreamIndexes[0] then
    begin
      Stream:=Streams[I];
      Stream.PixelFormatName:=UTF8PtrToString(av_get_pix_fmt_name(TAVPixelFormat(FFrame.format)));
      if Aspect.Known then
      begin
        if (FVideoWidth <> 0) AND Stream.PixelAspect.Known AND (Aspect.Compare(Stream.PixelAspect) <> 0) then
          Changed:=True;
        Stream.PixelAspect:=Aspect;
      end;
      if Transform.Known then
      begin
        if (FVideoWidth <> 0) AND NOT Stream.DisplayTransform.Known then
          Changed:=True;
        if (FVideoWidth <> 0) AND Stream.DisplayTransform.Known then
          for J:=0 to 8 do
            if Transform.Values[J] <> Stream.DisplayTransform.Values[J] then
              Changed:=True;
        Stream.DisplayTransform:=Transform;
        SideData:=av_frame_get_side_data(FFrame, AV_FRAME_DATA_DISPLAYMATRIX);
        Angle:=av_display_rotation_get(PInteger(SideData.data));
        Stream.RotationKnown:=NOT IsNan(Angle) AND NOT IsInfinite(Angle);
        if Stream.RotationKnown then
          Stream.RotationDegrees:=Angle;
      end;
      Stream.Width:=FFrame.width;
      Stream.Height:=FFrame.height;
      Stream.DisplayAspect:=DisplayAspect(Stream.Width, Stream.Height, Stream.PixelAspect);
      Color:=Default(TMediaColorInfo);
      Color.Matrix:=UTF8PtrToString(av_color_space_name(FFrame.colorspace));
      Color.RangeName:=UTF8PtrToString(av_color_range_name(FFrame.color_range));
      Color.Primaries:=UTF8PtrToString(av_color_primaries_name(FFrame.color_primaries));
      Color.Transfer:=UTF8PtrToString(av_color_transfer_name(FFrame.color_trc));
      Color.ChromaLocation:=UTF8PtrToString(av_chroma_location_name(FFrame.chroma_location));
      if (FVideoWidth <> 0) AND ((Color.Matrix <> Stream.Color.Matrix) OR (Color.RangeName <> Stream.Color.RangeName) OR
        (Color.Primaries <> Stream.Color.Primaries) OR (Color.Transfer <> Stream.Color.Transfer) OR
        (Color.ChromaLocation <> Stream.Color.ChromaLocation)) then
        Changed:=True;
      Stream.Color:=Color;
      Streams[I]:=Stream;
    end;
  FInfo.Streams:=Streams;
  FVideoWidth:=FFrame.width;
  FVideoHeight:=FFrame.height;
  FVideoFormat:=FFrame.format;
  PixelFormat:=AV_PIX_FMT_BGRA;
  if FSettings.PixelFormat = mpfRGB24 then
    PixelFormat:=AV_PIX_FMT_RGB24;
  Converted:=nil;
  try
    if FFrame.format = Ord(PixelFormat) then
    begin
      // Decoder buffers are reference-counted. Retaining a reference prevents
      // reuse while this immutable public sample is alive, without a pixel copy.
      Converted:=av_frame_clone(FFrame);
      if NOT Assigned(Converted) then
        raise EFFmpegMediaError.Create(mecDecode, 'Retain video', 'Cannot retain decoded frame');
    end else
    begin
      Code:=TFFmpegVideoScaler.Scale(FFrame, FFrame.width, FFrame.height, PixelFormat, Converted);
      if Code < 0 then
        raise EFFmpegMediaError.Create(mecDecode, 'Convert video', FFmpegErrorText(Code), Code);
    end;
    Duration:=TMediaTime.Unknown;
    if FFrame.duration > 0 then
      Duration:=PublicTime(FFrame.duration, FTimeBases[0]);
    Result:=TakeVideoFrame(Converted, FrameTime(0, FFrame.best_effort_timestamp), Duration, FStreamIndexes[0], Changed);
  finally
    av_frame_free(@Converted);
  end;
end;

function TMediaReaderSession.AudioSample(AFlush: Boolean): IMediaSample;
var
  Buffer: PByte;
  ByteCount, Code, Count, BytesPerSample: Integer;
  SampleFormat: TAVSampleFormat;
  Layout: TMediaChannelLayout;
  Bytes: TBytes;
  Timestamp: TMediaTime;
  InputTimestamp, ExpectedTimestamp: TMediaTime;
  Tolerance: Int64;
  Difference: Int64;
begin
  Result:=nil;
  if AFlush AND NOT FResamplerOpen then
  begin
    FAudioDrained:=True;
    Exit;
  end;
  if NOT AFlush then
  begin
    if (FFrame.ch_layout.nb_channels < 1) OR (FFrame.ch_layout.nb_channels > MEDIA_MAX_CHANNELS) OR
      (FFrame.sample_rate < 8000) OR (FFrame.sample_rate > 384000) OR
      (FFrame.nb_samples < 0) OR (Int64(FFrame.nb_samples) * FFrame.ch_layout.nb_channels * 8 > MEDIA_MAX_BUFFER_BYTES) then
      raise EFFmpegMediaError.Create(mecUnsupported, 'Read audio', 'Input rate/channel/sample allocation limit exceeded');
    if NOT FResamplerOpen then
    begin
      FAudioInputRate:=FFrame.sample_rate;
      FAudioInputFormat:=FFrame.format;
      CheckNative(av_channel_layout_copy(@FAudioInputLayout, @FFrame.ch_layout), 'Retain audio layout');
      SampleFormat:=AV_SAMPLE_FMT_S16;
      if FSettings.SampleFormat = msfFloat32 then
        SampleFormat:=AV_SAMPLE_FMT_FLT;
      Code:=FResampler.OpenFromCodec(FDecoders[1].CodecContext, FSettings.SampleRate, FSettings.Channels, SampleFormat);
      if Code < 0 then
        raise EFFmpegMediaError.Create(mecDecode, 'Convert audio', FFmpegErrorText(Code), Code);
      FResamplerOpen:=True;
      FAudioAnchor:=FrameTime(1, FFrame.best_effort_timestamp);
    end;
    if (FAudioInputRate <> FFrame.sample_rate) OR (FAudioInputFormat <> FFrame.format) OR
      (av_channel_layout_compare(@FAudioInputLayout, @FFrame.ch_layout) <> 0) then
      raise EFFmpegMediaError.Create(mecUnsupported, 'Read audio', 'Midstream audio format/layout changes are unsupported');
    InputTimestamp:=FrameTime(1, FFrame.best_effort_timestamp);
    if FAudioAnchor.Valid AND InputTimestamp.Valid then
    begin
      ExpectedTimestamp:=FAudioAnchor.Add(TMediaTime.FromTicks(FAudioInputSamples, TMediaRate.Create(1, FAudioInputRate)));
      Tolerance:=TMediaTime.FromTicks(1, FTimeBases[1]).Microseconds + 2 * (1000000 DIV FAudioInputRate + 1);
      Difference:=InputTimestamp.Subtract(ExpectedTimestamp).Microseconds;
      if FDeviceInput then
      begin
        // A live driver's timestamps may jitter or jump. Keep every converted
        // PCM sample and preserve that clock change in the output timeline;
        // the capture queue reports it and strict recording rejects the gap.
        // File readers retain their contiguous, sample-count clock contract.
        FAudioAnchor:=FAudioAnchor.Add(TMediaTime.FromMicroseconds(Difference));
      end else
      if (Difference > Tolerance) OR (Difference < -Tolerance) then
        raise EFFmpegMediaError.Create(mecUnsupported, 'Read audio', 'Audio timestamp discontinuity requires an explicit gap policy');
    end;
    if FAudioInputSamples > High(Int64) - FFrame.nb_samples then
      raise EFFmpegMediaError.Create(mecDecode, 'Read audio', 'Input audio sample counter overflow');
    Inc(FAudioInputSamples, FFrame.nb_samples);
  end;

  if AFlush then
    Code:=FResampler.Flush(Buffer, ByteCount)
  else
    Code:=FResampler.ConvertFrame(FFrame, Buffer, ByteCount);
  if Code < 0 then
    raise EFFmpegMediaError.Create(mecDecode, 'Convert audio', FFmpegErrorText(Code), Code);
  if AFlush AND (ByteCount = 0) then
    FAudioDrained:=True;
  if ByteCount = 0 then
    Exit;
  BytesPerSample:=2;
  if FSettings.SampleFormat = msfFloat32 then
    BytesPerSample:=4;
  if (ByteCount < 0) OR (ByteCount > MEDIA_MAX_BUFFER_BYTES) OR NOT Assigned(Buffer) OR
    (ByteCount MOD (FSettings.Channels * BytesPerSample) <> 0) then
    raise EFFmpegMediaError.Create(mecDecode, 'Convert audio', 'Invalid packed audio output size');
  Count:=ByteCount DIV (FSettings.Channels * BytesPerSample);
  Timestamp:=FAudioAnchor;
  if Timestamp.Valid then
    Timestamp:=Timestamp.Add(TMediaTime.FromTicks(FAudioOutputSamples, TMediaRate.Create(1, FSettings.SampleRate)));
  if FAudioOutputSamples > High(Int64) - Count then
    raise EFFmpegMediaError.Create(mecDecode, 'Read audio', 'Audio sample counter overflow');
  Inc(FAudioOutputSamples, Count);
  SetLength(Bytes, ByteCount);
  Move(Buffer^, Bytes[0], ByteCount);
  Layout:=TMediaChannelLayout.Mono;
  if FSettings.Channels = 2 then
    Layout:=TMediaChannelLayout.Stereo;
  Result:=CreateAudioCopy(Bytes, Count, FSettings.SampleRate, FSettings.SampleFormat, Layout, Timestamp, FStreamIndexes[1], False);
end;

function TMediaReaderSession.Pump(out ASample: IMediaSample): TMediaReadStatus;
var
  I, Code: Integer;
  SentDrain, ReceivedFrame: Boolean;
  Backpressure: Integer;
begin
  Result:=mrsEndOfInput;
  ASample:=nil;
  Backpressure:=0;
  while True do
  begin
    FOperation.Check('Read sample');
    ReceivedFrame:=False;
    for I:=0 to 1 do
      if NOT FDecoderDone[I] then
      begin
        Code:=FDecoders[I].ReceiveFrame(FFrame);
        if Code = AVERROR_EOF then
          FDecoderDone[I]:=True
        else
        if Code <> AVERROR_EAGAIN then
        begin
          if Code < 0 then
            raise EFFmpegMediaError.Create(mecDecode, 'Receive sample', FFmpegErrorText(Code), Code);
          if FFrame.decode_error_flags <> 0 then
            raise EFFmpegMediaError.Create(mecDecode, 'Receive sample', 'Decoder reported damaged frame data');
          ReceivedFrame:=True;
          Backpressure:=0;
          try
            if I = 0 then
              ASample:=VideoSample
            else
              ASample:=AudioSample(False);
            if Assigned(ASample) then
              Exit(mrsSample);
          finally
            av_frame_unref(FFrame);
          end;
        end;
      end;

    if ReceivedFrame then
      Continue;

    if FDecoderDone[1] AND NOT FAudioDrained then
    begin
      ASample:=AudioSample(True);
      if Assigned(ASample) then
        Exit(mrsSample);
    end;
    if FDecoderDone[0] AND FDecoderDone[1] AND FAudioDrained then
      Exit;

    if FPendingDecoder >= 0 then
    begin
      Code:=FDecoders[FPendingDecoder].SendPacket(FPacket);
      if Code = AVERROR_EAGAIN then
      begin
        Inc(Backpressure);
        if Backpressure > 1 then
          raise EFFmpegMediaError.Create(mecDecode, 'Send sample packet', 'Decoder send/receive made no progress');
        Continue;
      end;
      if Code < 0 then
        raise EFFmpegMediaError.Create(mecDecode, 'Send sample packet', FFmpegErrorText(Code), Code);
      av_packet_unref(FPacket);
      FPendingDecoder:=-1;
      Continue;
    end;

    if FDemuxDone then
    begin
      SentDrain:=False;
      for I:=0 to 1 do
        if NOT FDecoderDone[I] AND NOT FDrainSent[I] then
        begin
          Code:=FDecoders[I].SendPacket(nil);
          if Code = AVERROR_EAGAIN then
          begin
            Inc(Backpressure);
            if Backpressure > 2 then
              raise EFFmpegMediaError.Create(mecDecode, 'Drain decoder', 'Decoder send/receive made no progress');
            SentDrain:=True;
            Continue;
          end;
          if Code < 0 then
            raise EFFmpegMediaError.Create(mecDecode, 'Drain decoder', FFmpegErrorText(Code), Code);
          FDrainSent[I]:=True;
          SentDrain:=True;
        end;
      if NOT SentDrain then
        raise EFFmpegMediaError.Create(mecDecode, 'Drain decoder', 'Decoder returned EAGAIN after accepting end of input');
      Continue;
    end;

    Code:=FInput.ReadPacket(FPacket);
    FOperation.Check('Read sample');
    if Code = AVERROR_EOF then
    begin
      FDemuxDone:=True;
      Continue;
    end;
    if Code = AVERROR_EAGAIN then
    begin
      Sleep(1);
      Continue;
    end;
    CheckNative(Code, 'Read packet');
    if (FPacket.size < 0) OR (FPacket.size > FSettings.MaxPacketBytes) then
      raise EFFmpegMediaError.Create(mecDecode, 'Read packet', 'Packet allocation limit exceeded');
    for I:=0 to 1 do
      if (FStreamIndexes[I] >= 0) AND (FPacket.stream_index = FStreamIndexes[I]) then
        FPendingDecoder:=I;
    if FPendingDecoder < 0 then
      av_packet_unref(FPacket);
  end;
end;

function TMediaReaderSession.ReadSample(out ASample: IMediaSample): TMediaReadStatus;
begin
  Result:=mrsEndOfInput;
  ASample:=nil;
  if NOT FOpened OR FFailed then
    raise EFFmpegMediaError.Create(mecInvalidState, 'Read sample', 'Reader is closed or failed');
  if FTerminal IN [mrsCancelled, mrsTimedOut] then
    Exit(FTerminal);
  FOperation.RestartTimeout;
  try
    Result:=Pump(ASample);
  except
    on E: EMediaCancelled do
    begin
      FTerminal:=mrsCancelled;
      ASample:=nil;
      Result:=FTerminal;
    end;

    on E: EMediaTimedOut do
    begin
      FTerminal:=mrsTimedOut;
      ASample:=nil;
      Result:=FTerminal;
    end;

    else
    begin
      FFailed:=True;
      ASample:=nil;
      raise;
    end;
  end;
end;

procedure TMediaReaderSession.Seek(const APosition: TMediaTime);
var
  I, Code: Integer;
  Target: TMediaTime;
begin
  if NOT FOpened OR FFailed OR (FTerminal IN [mrsCancelled, mrsTimedOut]) then
    raise EFFmpegMediaError.Create(mecInvalidState, 'Seek reader', 'Reader is closed, failed or interrupted');
  if NOT FInfo.Seekable then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Seek reader', 'Input is not seekable');
  if NOT APosition.Valid OR (APosition.Microseconds < 0) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Seek reader', 'A known nonnegative position is required');
  if FInfo.Duration.Valid AND (APosition.Compare(FInfo.Duration) > 0) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Seek reader', 'Position exceeds known duration');
  Target:=APosition.Add(FOrigin);
  FOperation.RestartTimeout;
  try
    FOperation.Check('Seek reader');
    Code:=avformat_seek_file(FInput.FormatContext, -1, Low(Int64), Target.Microseconds, Target.Microseconds, 0);
    FOperation.Check('Seek reader');
    if Code < 0 then
      raise EFFmpegMediaError.Create(mecInputOutput, 'Seek reader', FFmpegErrorText(Code), Code);
    for I:=0 to 1 do
      if Assigned(FDecoders[I]) then
        FDecoders[I].Reset;
    ResetPump;
  except
    on E: EMediaCancelled do
    begin
      FTerminal:=mrsCancelled;
      raise;
    end;

    on E: EMediaTimedOut do
    begin
      FTerminal:=mrsTimedOut;
      raise;
    end;

    else
    begin
      FFailed:=True;
      raise;
    end;
  end;
end;

function OpenMediaFile(const AFilename: String; const ASettings: TMediaReaderSettings; const AToken: IMediaCancellationToken): IMediaReader;
begin
  Result:=TMediaReaderSession.Create(AFilename, nil, False, ASettings, AToken);
end;

function OpenMediaBytes(const ABytes: TBytes; const ASettings: TMediaReaderSettings; const AToken: IMediaCancellationToken): IMediaReader;
begin
  Result:=TMediaReaderSession.Create('', ABytes, True, ASettings, AToken);
end;

function OpenMediaURL(const AURL: String; const ASettings: TMediaReaderSettings; const AToken: IMediaCancellationToken): IMediaReader;
begin
  Result:=TMediaReaderSession.Create(AURL, nil, False, ASettings, AToken, True);
end;

function ProbeRemoteURL(const AURL: String; const ASettings: TMediaInputSettings; const AToken: IMediaCancellationToken): TMediaInfo;
begin
  Result:=ProbeInput(AURL, nil, False, ASettings, AToken, True);
end;

end.
