unit TFFmpeg.Media.Convert;

interface

uses
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Writer,
  TFFmpeg.Media.Images;

type
  TMediaMetadataPolicy = (mmpStripSource, mmpCopyContainerText);
  TMediaVideoTimingPolicy = (mvpPreserveTiming, mvpConstantRate);

  TMediaAudioConvertSettings = record
  private
    FInput: TMediaInputSettings;
    FAudioStreamIndex: Integer;
    FOutput: TMediaWriterSettings;
    FMetadataPolicy: TMediaMetadataPolicy;
    FProgressIntervalMilliseconds: Cardinal;
  public
    class function OggOpus(AChannels: Integer = 2; ABitRate: Int64 = 128000): TMediaAudioConvertSettings; static;
    procedure Validate;
    property Input: TMediaInputSettings read FInput write FInput;
    property AudioStreamIndex: Integer read FAudioStreamIndex write FAudioStreamIndex;
    property Output: TMediaWriterSettings read FOutput write FOutput;
    property MetadataPolicy: TMediaMetadataPolicy read FMetadataPolicy write FMetadataPolicy;
    property ProgressIntervalMilliseconds: Cardinal read FProgressIntervalMilliseconds write FProgressIntervalMilliseconds;
  end;

  TMediaAVConvertSettings = record
  private
    FInput: TMediaInputSettings;
    FVideoStreamIndex: Integer;
    FAudioStreamIndex: Integer;
    FOutput: TMediaWriterSettings;
    FImage: TMediaImageSettings;
    FVideoTiming: TMediaVideoTimingPolicy;
    FMetadataPolicy: TMediaMetadataPolicy;
    FProgressIntervalMilliseconds: Cardinal;
  public
    class function H264OpusMatroska(AWidth, AHeight: Integer; const AFrameRate: TMediaRate): TMediaAVConvertSettings; static;
    class function H264AACMP4(AWidth, AHeight: Integer; const AFrameRate: TMediaRate): TMediaAVConvertSettings; static;
    procedure Validate;
    property Input: TMediaInputSettings read FInput write FInput;
    property VideoStreamIndex: Integer read FVideoStreamIndex write FVideoStreamIndex;
    property AudioStreamIndex: Integer read FAudioStreamIndex write FAudioStreamIndex;
    property Output: TMediaWriterSettings read FOutput write FOutput;
    property Image: TMediaImageSettings read FImage write FImage;
    property VideoTiming: TMediaVideoTimingPolicy read FVideoTiming write FVideoTiming;
    property MetadataPolicy: TMediaMetadataPolicy read FMetadataPolicy write FMetadataPolicy;
    property ProgressIntervalMilliseconds: Cardinal read FProgressIntervalMilliseconds write FProgressIntervalMilliseconds;
  end;

  TMediaConversionResult = record
  private
    FAudioSamples: Int64;
    FAudioSampleRate: Integer;
    FDuration: TMediaTime;
    FElapsedMilliseconds: UInt64;
    FAudioEncoderName: String;
    FVideoFrames: Int64;
    FVideoEncoderName: String;
    FDuplicatedFrames: Int64;
    FDroppedFrames: Int64;
  public
    property AudioSamples: Int64 read FAudioSamples;
    property AudioSampleRate: Integer read FAudioSampleRate;
    property Duration: TMediaTime read FDuration;
    property ElapsedMilliseconds: UInt64 read FElapsedMilliseconds;
    property AudioEncoderName: String read FAudioEncoderName;
    property VideoFrames: Int64 read FVideoFrames;
    property VideoEncoderName: String read FVideoEncoderName;
    property DuplicatedFrames: Int64 read FDuplicatedFrames;
    property DroppedFrames: Int64 read FDroppedFrames;
  end;

  TMediaConvert = class sealed
  public
    class function MediaFile(const ASource, ADestination: String; const ASettings: TMediaAVConvertSettings;
      AProgress: TMediaProgressCallback = nil; const AToken: IMediaCancellationToken = nil): TMediaConversionResult; static;
    class function MediaURL(const AURL, ADestination: String; const ASettings: TMediaAVConvertSettings;
      AProgress: TMediaProgressCallback = nil; const AToken: IMediaCancellationToken = nil): TMediaConversionResult; static;
    class function AudioFile(const ASource, ADestination: String): TMediaConversionResult; overload; static;
    class function AudioFile(const ASource, ADestination: String; const ASettings: TMediaAudioConvertSettings;
      AProgress: TMediaProgressCallback = nil; const AToken: IMediaCancellationToken = nil): TMediaConversionResult; overload; static;
  end;

implementation

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
  System.Diagnostics,
{$ENDIF}
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Reader,
  TFFmpeg.Media.Internal.Files;

function ClockMilliseconds: UInt64;
{$IFNDEF FPC}
var
  Ticks, Frequency: Int64;
{$ENDIF}
begin
{$IFDEF FPC}
  Result:=GetTickCount64;
{$ELSE}
  Ticks:=TStopwatch.GetTimeStamp;
  Frequency:=TStopwatch.Frequency;
  Result:=UInt64(Ticks DIV Frequency) * 1000 + UInt64((Ticks MOD Frequency) * 1000 DIV Frequency);
{$ENDIF}
end;

procedure ReportProgress(AProgress: TMediaProgressCallback; AInterval: Cardinal; AStage: TMediaProgressStage;
  const ATotalDuration, AProcessedTime: TMediaTime; ABytes: Int64; AStarted: UInt64; var ALastProgress: UInt64; AForce: Boolean);
var
  Progress: TMediaProgress;
  NowMilliseconds: UInt64;
  Percent: Int64;
begin
  if NOT Assigned(AProgress) then
    Exit;
  NowMilliseconds:=ClockMilliseconds;
  if NOT AForce AND (NowMilliseconds - ALastProgress < AInterval) then
    Exit;
  ALastProgress:=NowMilliseconds;
  Progress:=Default(TMediaProgress);
  Progress.Stage:=AStage;
  Progress.ProcessedTime:=AProcessedTime;
  Progress.Bytes:=ABytes;
  Progress.ElapsedMilliseconds:=NowMilliseconds - AStarted;
  if ATotalDuration.Valid AND (ATotalDuration.Microseconds > 0) then
  begin
    Percent:=99;
    if AProcessedTime.Compare(ATotalDuration) < 0 then
      Percent:=Trunc(AProcessedTime.Microseconds / ATotalDuration.Microseconds * 100);
    if Percent < 0 then
      Percent:=0;
    if Percent > 99 then
      Percent:=99;
    if AStage = mpsCompleted then
      Percent:=100;
    Progress.Percent:=TMediaOptionalInt64.Create(Percent, AStage <> mpsCompleted);
  end;
  AProgress(Progress);
end;

class function TMediaAVConvertSettings.H264OpusMatroska(AWidth, AHeight: Integer; const AFrameRate: TMediaRate): TMediaAVConvertSettings;
begin
  Result:=Default(TMediaAVConvertSettings);
  Result.FInput:=TMediaInputSettings.Default;
  Result.FVideoStreamIndex:=-1;
  Result.FAudioStreamIndex:=-1;
  Result.FOutput:=TMediaWriterSettings.H264MP4(AWidth, AHeight, AFrameRate);
  Result.FOutput.MuxerName:='matroska';
  Result.FOutput.Audio:=TMediaAudioEncoding.Opus;
  Result.FOutput.Timing:=mwtPreserve;
  Result.FImage:=TMediaImageSettings.Default;
  Result.FProgressIntervalMilliseconds:=100;
end;

class function TMediaAVConvertSettings.H264AACMP4(AWidth, AHeight: Integer; const AFrameRate: TMediaRate): TMediaAVConvertSettings;
begin
  Result:=H264OpusMatroska(AWidth, AHeight, AFrameRate);
  Result.FOutput.MuxerName:='mp4';
  Result.FOutput.Audio:=TMediaAudioEncoding.AAC;
end;

procedure TMediaAVConvertSettings.Validate;
begin
  FInput.Validate;
  FOutput.Validate;
  FImage.Validate;
  if (FVideoStreamIndex < -2) OR (FAudioStreamIndex < -2) OR
    ((NOT FOutput.Video.Enabled OR (FVideoStreamIndex = -2)) AND (NOT FOutput.Audio.Enabled OR (FAudioStreamIndex = -2))) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'AV conversion', 'Select at least one enabled audio/video stream');
  if ((FVideoStreamIndex >= 0) AND NOT FOutput.Video.Enabled) OR ((FAudioStreamIndex >= 0) AND NOT FOutput.Audio.Enabled) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'AV conversion', 'An explicit input mapping requires its output stream enabled');
  if (FOutput.Timing <> mwtPreserve) OR NOT (FVideoTiming IN [mvpPreserveTiming, mvpConstantRate]) OR
    NOT (FMetadataPolicy IN [mmpStripSource, mmpCopyContainerText]) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'AV conversion', 'An explicit supported AV timestamp/metadata policy is required');
  if (FImage.AlphaMode <> mamComposite) OR
    (FOutput.Video.Enabled AND (((FImage.Width <> 0) AND (FImage.Width <> FOutput.Video.Width)) OR
    ((FImage.Height <> 0) AND (FImage.Height <> FOutput.Video.Height)))) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'AV conversion', 'Image settings require composite alpha and dimensions matching the video output');
end;

class function TMediaAudioConvertSettings.OggOpus(AChannels: Integer; ABitRate: Int64): TMediaAudioConvertSettings;
begin
  Result:=Default(TMediaAudioConvertSettings);
  Result.FInput:=TMediaInputSettings.Default;
  Result.FAudioStreamIndex:=-1;
  Result.FOutput:=TMediaWriterSettings.OggOpus(AChannels, ABitRate);
  Result.FProgressIntervalMilliseconds:=100;
end;

procedure TMediaAudioConvertSettings.Validate;
begin
  FInput.Validate;
  FOutput.Validate;
  if (FAudioStreamIndex < -1) OR NOT FOutput.Audio.Enabled OR FOutput.Video.Enabled then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Audio conversion', 'Select one audio stream and an audio-only writer');
  if FOutput.Timing <> mwtGenerate then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Audio conversion', 'AudioFile generates a zero-based sample-count timeline');
  if NOT (FMetadataPolicy IN [mmpStripSource, mmpCopyContainerText]) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Audio conversion', 'Unsupported metadata policy');
end;

function MergeMetadata(const ASource, AOverrides: TMediaMetadata): TMediaMetadata;
var
  I, J: Integer;
  Found: Boolean;
begin
  Result:=Copy(AOverrides);
  for I:=0 to Length(ASource) - 1 do
  begin
    Found:=False;
    for J:=0 to Length(AOverrides) - 1 do
      Found:=Found OR SameText(ASource[I].Key, AOverrides[J].Key);
    if NOT Found then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)]:=ASource[I];
    end;
  end;
end;

class function TMediaConvert.AudioFile(const ASource, ADestination: String): TMediaConversionResult;
begin
  Result:=AudioFile(ASource, ADestination, TMediaAudioConvertSettings.OggOpus);
end;

class function TMediaConvert.AudioFile(const ASource, ADestination: String; const ASettings: TMediaAudioConvertSettings;
  AProgress: TMediaProgressCallback; const AToken: IMediaCancellationToken): TMediaConversionResult;
var
  Reader: IMediaReader;
  Writer: IMediaWriter;
  ReaderSettings: TMediaReaderSettings;
  WriterSettings: TMediaWriterSettings;
  Sample: IMediaSample;
  Buffer: IMediaAudioBuffer;
  Status: TMediaReadStatus;
  Streams: TMediaStreams;
  TotalDuration: TMediaTime;
  ProcessedTime: TMediaTime;
  Started, LastProgress: UInt64;
  ProcessedBytes, Samples, AddedBytes: Int64;
  Selected, I: Integer;

  procedure Report(AStage: TMediaProgressStage; AForce: Boolean);
  begin
    ReportProgress(AProgress, ASettings.ProgressIntervalMilliseconds, AStage, TotalDuration, ProcessedTime,
      ProcessedBytes, Started, LastProgress, AForce);
  end;

begin
  Result:=Default(TMediaConversionResult);
  ASettings.Validate;
  RequireDifferentFiles(ASource, ADestination);
  Started:=ClockMilliseconds;
  LastProgress:=Started;
  Samples:=0;
  ProcessedBytes:=0;
  ProcessedTime:=TMediaTime.FromMicroseconds(0);
  TotalDuration:=TMediaTime.Unknown;
  Report(mpsOpening, True);
  ReaderSettings:=TMediaReaderSettings.Default;
  ReaderSettings.Input:=ASettings.Input;
  ReaderSettings.VideoStreamIndex:=-2;
  ReaderSettings.AudioStreamIndex:=ASettings.AudioStreamIndex;
  ReaderSettings.SampleRate:=ASettings.Output.Audio.SampleRate;
  ReaderSettings.Channels:=ASettings.Output.Audio.Channels;
  Reader:=TMediaReader.OpenFile(ASource, ReaderSettings, AToken);
  try
    Selected:=TMediaProbe.SelectStream(Reader.Info, mkAudio, ASettings.AudioStreamIndex);
    Streams:=Reader.Info.Streams;
    for I:=0 to Length(Streams) - 1 do
      if Streams[I].Index = Selected then
        TotalDuration:=Streams[I].Duration;
    WriterSettings:=ASettings.Output;
    if ASettings.MetadataPolicy = mmpCopyContainerText then
      WriterSettings.Metadata:=MergeMetadata(Reader.Info.Metadata, WriterSettings.Metadata);
    Writer:=TMediaWriter.OpenFile(ADestination, WriterSettings, AToken);
    try
      Result.FAudioEncoderName:=Writer.AudioEncoderName;
      Result.FAudioSampleRate:=WriterSettings.Audio.SampleRate;
      Report(mpsProcessing, True);
      while True do
      begin
        Status:=Reader.ReadSample(Sample);
        case Status of
          mrsEndOfInput: Break;
          mrsCancelled: raise EMediaCancelled.Create('Convert audio');
          mrsTimedOut: raise EMediaTimedOut.Create('Convert audio');
        end;
        Buffer:=Sample AS IMediaAudioBuffer;
        if Samples > High(Int64) - Buffer.SampleCount then
          raise EFFmpegMediaError.Create(mecEncode, 'Convert audio', 'Sample count overflow');
        AddedBytes:=Int64(Buffer.SampleCount) * Buffer.ChannelLayout.Channels * 2;
        if ProcessedBytes > High(Int64) - AddedBytes then
          raise EFFmpegMediaError.Create(mecEncode, 'Convert audio', 'Processed byte count overflow');
        Writer.SubmitAudio(Buffer);
        Inc(Samples, Buffer.SampleCount);
        Inc(ProcessedBytes, AddedBytes);
        ProcessedTime:=TMediaTime.FromTicks(Samples, TMediaRate.Create(1, Result.FAudioSampleRate));
        Buffer:=nil;
        Sample:=nil;
        Report(mpsProcessing, False);
      end;
      Report(mpsFinalizing, True);
      Writer.Finish;
      Result.FAudioSamples:=Samples;
      Result.FDuration:=ProcessedTime;
      Result.FElapsedMilliseconds:=ClockMilliseconds - Started;
      // Completion is observable only after Finish has closed and published.
      Report(mpsCompleted, True);
    finally
      Writer.Abort;
    end;
  finally
    Reader.Close;
  end;
end;

function HasRequestedKind(const AInfo: TMediaInfo; AKind: TMediaKind): Boolean;
var
  Streams: TMediaStreams;
  I: Integer;
begin
  Result:=False;
  Streams:=AInfo.Streams;
  for I:=0 to Length(Streams) - 1 do
    if (Streams[I].Kind = AKind) AND NOT Streams[I].AttachedArt then
      Exit(True);
end;

function SelectedDuration(const AInfo: TMediaInfo; AVideo, AAudio: Integer; const AOrigin: TMediaTime): TMediaTime;
var
  Streams: TMediaStreams;
  I: Integer;
  EndTime: TMediaTime;
begin
  Result:=TMediaTime.FromMicroseconds(0);
  Streams:=AInfo.Streams;
  for I:=0 to Length(Streams) - 1 do
    if (Streams[I].Index = AVideo) OR (Streams[I].Index = AAudio) then
    begin
      if NOT Streams[I].Duration.Valid OR NOT Streams[I].StartTime.Valid then
        Exit(TMediaTime.Unknown);
      EndTime:=Streams[I].StartTime.Add(Streams[I].Duration).Subtract(AOrigin);
      if EndTime.Compare(Result) > 0 then
        Result:=EndTime;
    end;
end;

function ConvertAVInput(const ASource, ADestination: String; AUseURL: Boolean; const ASettings: TMediaAVConvertSettings;
  AProgress: TMediaProgressCallback; const AToken: IMediaCancellationToken): TMediaConversionResult;
var
  Reader: IMediaReader;
  Writer: IMediaWriter;
  ReaderSettings: TMediaReaderSettings;
  WriterSettings: TMediaWriterSettings;
  ImageSettings: TMediaImageSettings;
  VideoEncoding: TMediaVideoEncoding;
  AudioEncoding: TMediaAudioEncoding;
  Sample: IMediaSample;
  Video, Pending: IMediaVideoFrame;
  Audio: IMediaAudioBuffer;
  Status: TMediaReadStatus;
  Streams: TMediaStreams;
  Stream: TMediaStreamInfo;
  TotalDuration, ProcessedTime, EndTime, FramePeriod: TMediaTime;
  FrameBase: TMediaRate;
  SelectedVideo, SelectedAudio, I: Integer;
  NextFrameIndex, ProcessedBytes: Int64;
  Started, LastProgress: UInt64;

  procedure Report(AStage: TMediaProgressStage; AForce: Boolean);
  begin
    ReportProgress(AProgress, ASettings.ProgressIntervalMilliseconds, AStage, TotalDuration, ProcessedTime,
      ProcessedBytes, Started, LastProgress, AForce);
  end;

  procedure MarkProcessed(ABytes: Int64; const AEnd: TMediaTime);
  begin
    if (ABytes < 0) OR (ProcessedBytes > High(Int64) - ABytes) then
      raise EFFmpegMediaError.Create(mecEncode, 'AV conversion', 'Processed byte count overflow');
    Inc(ProcessedBytes, ABytes);
    if AEnd.Compare(ProcessedTime) > 0 then
      ProcessedTime:=AEnd;
    Report(mpsProcessing, False);
  end;

  procedure EmitFrame(const ATimestamp, ADuration: TMediaTime);
  begin
    if Result.FVideoFrames = High(Int64) then
      raise EFFmpegMediaError.Create(mecEncode, 'AV conversion', 'Output frame count overflow');
    Writer.SubmitVideoAt(Pending, ATimestamp, ADuration);
    Inc(Result.FVideoFrames);
    MarkProcessed(Int64(Pending.Stride) * Pending.Height, ATimestamp.Add(ADuration));
  end;

  procedure EmitPending(const AEnd: TMediaTime);
  var
    GridTime, NextGridTime: TMediaTime;
    Emitted: Int64;
  begin
    if NOT Assigned(Pending) then
      Exit;
    if AEnd.Compare(Pending.Timestamp) <= 0 then
      raise EFFmpegMediaError.Create(mecUnsupported, 'AV conversion', 'Video timestamps/durations must advance strictly');
    if ASettings.VideoTiming = mvpPreserveTiming then
      EmitFrame(Pending.Timestamp, AEnd.Subtract(Pending.Timestamp))
    else
    begin
      Emitted:=0;
      GridTime:=TMediaTime.FromTicks(NextFrameIndex, FrameBase);
      while GridTime.Compare(AEnd) < 0 do
      begin
        if NextFrameIndex = High(Int64) then
          raise EFFmpegMediaError.Create(mecEncode, 'AV conversion', 'Constant-rate frame grid overflow');
        NextGridTime:=TMediaTime.FromTicks(NextFrameIndex + 1, FrameBase);
        EmitFrame(GridTime, NextGridTime.Subtract(GridTime));
        Inc(Emitted);
        Inc(NextFrameIndex);
        GridTime:=NextGridTime;
      end;
      if Emitted = 0 then
        Inc(Result.FDroppedFrames)
      else
        Inc(Result.FDuplicatedFrames, Emitted - 1);
    end;
    Pending:=nil;
  end;

begin
  Result:=Default(TMediaConversionResult);
  ASettings.Validate;
  if NOT AUseURL then
    RequireDifferentFiles(ASource, ADestination);
  Started:=ClockMilliseconds;
  LastProgress:=Started;
  ProcessedBytes:=0;
  ProcessedTime:=TMediaTime.FromMicroseconds(0);
  TotalDuration:=TMediaTime.Unknown;
  Report(mpsOpening, True);
  ReaderSettings:=TMediaReaderSettings.Default;
  ReaderSettings.Input:=ASettings.Input;
  ReaderSettings.VideoStreamIndex:=ASettings.VideoStreamIndex;
  ReaderSettings.AudioStreamIndex:=ASettings.AudioStreamIndex;
  if NOT ASettings.Output.Video.Enabled then
    ReaderSettings.VideoStreamIndex:=-2;
  if ASettings.Output.Audio.Enabled then
  begin
    ReaderSettings.SampleRate:=ASettings.Output.Audio.SampleRate;
    ReaderSettings.Channels:=ASettings.Output.Audio.Channels;
  end else
    ReaderSettings.AudioStreamIndex:=-2;
  if AUseURL then
    Reader:=TMediaReader.OpenURL(ASource, ReaderSettings, AToken)
  else
    Reader:=TMediaReader.OpenFile(ASource, ReaderSettings, AToken);
  try
    SelectedVideo:=TMediaProbe.SelectStream(Reader.Info, mkVideo, ReaderSettings.VideoStreamIndex);
    SelectedAudio:=TMediaProbe.SelectStream(Reader.Info, mkAudio, ReaderSettings.AudioStreamIndex);
    if ((ReaderSettings.VideoStreamIndex = -1) AND (SelectedVideo < 0) AND HasRequestedKind(Reader.Info, mkVideo)) OR
      ((ReaderSettings.AudioStreamIndex = -1) AND (SelectedAudio < 0) AND HasRequestedKind(Reader.Info, mkAudio)) then
      raise EFFmpegMediaError.Create(mecUnsupported, 'AV conversion', 'A requested media kind is present but has no available decoder');
    WriterSettings:=ASettings.Output;
    VideoEncoding:=WriterSettings.Video;
    VideoEncoding.Enabled:=SelectedVideo >= 0;
    WriterSettings.Video:=VideoEncoding;
    AudioEncoding:=WriterSettings.Audio;
    AudioEncoding.Enabled:=SelectedAudio >= 0;
    WriterSettings.Audio:=AudioEncoding;
    if ASettings.MetadataPolicy = mmpCopyContainerText then
      WriterSettings.Metadata:=MergeMetadata(Reader.Info.Metadata, WriterSettings.Metadata);
    ImageSettings:=ASettings.Image;
    ImageSettings.Width:=VideoEncoding.Width;
    ImageSettings.Height:=VideoEncoding.Height;
    if ImageSettings.TimeoutMilliseconds = 0 then
      ImageSettings.TimeoutMilliseconds:=WriterSettings.TimeoutMilliseconds;
    TotalDuration:=SelectedDuration(Reader.Info, SelectedVideo, SelectedAudio, Reader.PresentationOrigin);
    FrameBase:=TMediaRate.Unknown;
    FramePeriod:=TMediaTime.Unknown;
    if VideoEncoding.Enabled then
    begin
      FrameBase:=TMediaRate.Create(VideoEncoding.FrameRate.Denominator, VideoEncoding.FrameRate.Numerator);
      FramePeriod:=TMediaTime.FromTicks(1, FrameBase);
    end;
    NextFrameIndex:=0;
    Writer:=TMediaWriter.OpenFile(ADestination, WriterSettings, AToken);
    try
      Result.FVideoEncoderName:=Writer.VideoEncoderName;
      Result.FAudioEncoderName:=Writer.AudioEncoderName;
      if AudioEncoding.Enabled then
        Result.FAudioSampleRate:=AudioEncoding.SampleRate;
      Report(mpsProcessing, True);
      while True do
      begin
        Status:=Reader.ReadSample(Sample);
        case Status of
          mrsEndOfInput: Break;
          mrsCancelled: raise EMediaCancelled.Create('Convert AV');
          mrsTimedOut: raise EMediaTimedOut.Create('Convert AV');
        end;
        if Sample.Kind = mkVideo then
        begin
          Video:=Sample AS IMediaVideoFrame;
          if NOT Video.Timestamp.Valid OR (Video.Timestamp.Microseconds < 0) then
            raise EFFmpegMediaError.Create(mecUnsupported, 'AV conversion', 'Video conversion requires known nonnegative presentation timestamps');
          EmitPending(Video.Timestamp);
          Streams:=Reader.Info.Streams;
          Stream:=Default(TMediaStreamInfo);
          for I:=0 to Length(Streams) - 1 do
            if Streams[I].Index = Video.StreamIndex then
              Stream:=Streams[I];
          Pending:=TMediaImages.Render(Video, Stream, ImageSettings, AToken);
          if (Result.FVideoFrames = 0) AND (Result.FDroppedFrames = 0) then
          begin
            NextFrameIndex:=Pending.Timestamp.ToTicks(FrameBase);
            if TMediaTime.FromTicks(NextFrameIndex, FrameBase).Compare(Pending.Timestamp) < 0 then
              Inc(NextFrameIndex);
          end;
          Video:=nil;
        end else
        if Sample.Kind = mkAudio then
        begin
          Audio:=Sample AS IMediaAudioBuffer;
          if NOT Audio.Timestamp.Valid OR (Audio.Timestamp.Microseconds < 0) then
            raise EFFmpegMediaError.Create(mecUnsupported, 'AV conversion', 'Audio conversion requires known nonnegative presentation timestamps');
          if Result.FAudioSamples > High(Int64) - Audio.SampleCount then
            raise EFFmpegMediaError.Create(mecEncode, 'AV conversion', 'Audio sample count overflow');
          Writer.SubmitAudio(Audio);
          Inc(Result.FAudioSamples, Audio.SampleCount);
          EndTime:=Audio.Timestamp.Add(TMediaTime.FromTicks(Audio.SampleCount, TMediaRate.Create(1, Audio.SampleRate)));
          MarkProcessed(Int64(Audio.SampleCount) * Audio.ChannelLayout.Channels * 2, EndTime);
          Audio:=nil;
        end else
          raise EFFmpegMediaError.Create(mecUnsupported, 'AV conversion', 'Only selected audio/video samples are supported');
        Sample:=nil;
      end;
      if Assigned(Pending) then
      begin
        EndTime:=FramePeriod;
        if Pending.Duration.Valid AND (Pending.Duration.Microseconds > 0) then
          EndTime:=Pending.Duration;
        EmitPending(Pending.Timestamp.Add(EndTime));
      end;
      Report(mpsFinalizing, True);
      Writer.Finish;
      Result.FDuration:=ProcessedTime;
      Result.FElapsedMilliseconds:=ClockMilliseconds - Started;
      Report(mpsCompleted, True);
    finally
      Writer.Abort;
    end;
  finally
    Reader.Close;
  end;
end;

class function TMediaConvert.MediaFile(const ASource, ADestination: String; const ASettings: TMediaAVConvertSettings;
  AProgress: TMediaProgressCallback; const AToken: IMediaCancellationToken): TMediaConversionResult;
begin
  Result:=ConvertAVInput(ASource, ADestination, False, ASettings, AProgress, AToken);
end;

class function TMediaConvert.MediaURL(const AURL, ADestination: String; const ASettings: TMediaAVConvertSettings;
  AProgress: TMediaProgressCallback; const AToken: IMediaCancellationToken): TMediaConversionResult;
begin
  Result:=ConvertAVInput(AURL, ADestination, True, ASettings, AProgress, AToken);
end;

end.
