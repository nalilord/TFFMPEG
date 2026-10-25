program MediaTypesSmoke;

{$APPTYPE CONSOLE}
{$R+}
{$Q+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
{$IFDEF FPC}
  Classes,
  SysUtils,
{$ELSE}
  System.Classes,
  System.SysUtils,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Capabilities;

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

procedure TestTime;
var
  TimeValue: TMediaTime;
  Rate: TMediaRate;
  Failed: Boolean;
  I: Integer;
  Expected: Int64;
begin
  TimeValue:=Default(TMediaTime);
  Check(NOT TimeValue.Valid, 'Zero-initialized time must be unknown');
  Check(NOT TMediaRate.Unknown.Known, 'Unknown rate');
  Check(NOT TMediaOptionalInt64.Unknown.Known, 'Unknown optional value');
  Check(TMediaOptionalInt64.Create(0).Known, 'Known zero optional value');
  Check(TMediaOptionalInt64.Create(1, True).Estimated, 'Estimated value');
  Failed:=False;
  try
    Expected:=TimeValue.Microseconds;
  except
    on E: EFFmpegMediaError do
      Failed:=E.Category = mecInvalidSettings;
  end;
  Check(Failed, 'Unknown time must not masquerade as zero');
  TimeValue:=TMediaTime.FromSeconds(0);
  Check(TimeValue.Valid AND (TimeValue.Microseconds = 0), 'Known zero time');
  Check(TMediaTime.FromSeconds(-1.25).Microseconds = -1250000, 'Signed seconds');
  Check(TMediaTime.FromTicks(1, TMediaRate.Create(1001, 30000)).Microseconds = 33366, 'Rational precision/truncation');
  Check(TMediaTime.FromTicks(-1, TMediaRate.Create(1001, 30000)).Microseconds = -33366, 'Signed truncation');
  Rate:=TMediaRate.Create(1, 1000000);
  Check(TMediaTime.FromTicks(High(Int64), Rate).Microseconds = High(Int64), 'Intermediate overflow at positive limit');
  Check(TMediaTime.FromTicks(Low(Int64), Rate).Microseconds = Low(Int64), 'Intermediate overflow at negative limit');
  Check(TMediaTime.FromMicroseconds(High(Int64)).ToTicks(Rate) = High(Int64), 'Reverse limit conversion');
  Check(TMediaTime.FromMicroseconds(Low(Int64)).ToTicks(Rate) = Low(Int64), 'Reverse signed limit');
  Check(TMediaRate.Create(30000, 1001).Compare(TMediaRate.Create(60000, 2002)) = 0, 'Equivalent rational rates');
  Check(TMediaRate.Create(High(Integer), High(Integer) - 1).Compare(TMediaRate.Create(1, 1)) > 0, 'Exact rate comparison');
  Check(TMediaTime.FromMicroseconds(Low(Int64)).Subtract(TMediaTime.FromMicroseconds(Low(Int64))).Microseconds = 0, 'Subtract signed minimum');

  for I:=-1000 to 1000 do
  begin
    Expected:=Int64(I) * 1001000000 DIV 30000;
    Check(TMediaTime.FromTicks(I, TMediaRate.Create(1001, 30000)).Microseconds = Expected, 'Rational conversion sweep');
  end;

  for I:=0 to 6 do
  begin
    Failed:=False;
    try
      case I of
        0: TimeValue:=TMediaTime.FromTicks(High(Int64), TMediaRate.Create(1, 1));
        1: TimeValue:=TMediaTime.FromMicroseconds(High(Int64)).Add(TMediaTime.FromMicroseconds(1));
        2: TimeValue:=TMediaTime.FromMicroseconds(Low(Int64)).Subtract(TMediaTime.FromMicroseconds(1));
        3: Rate:=TMediaRate.Create(1, 0);
        4: TimeValue:=TMediaTime.FromSeconds(1E20);
        5: TimeValue:=TMediaTime.FromTicks(1, TMediaRate.Unknown);
        6: Expected:=TMediaTime.Unknown.Compare(TMediaTime.FromMicroseconds(0));
      end;
    except
      on E: EFFmpegMediaError do
        Failed:=E.Category = mecInvalidSettings;
    end;
    Check(Failed, 'Invalid/overflow time case ' + IntToStr(I));
  end;
  WriteLn('PASS: checked rational time, unknown values, signed limits and overflow');
end;

procedure TestOwnership;
var
  Bytes, Copied: TBytes;
  Video, SecondVideo: IMediaVideoFrame;
  Audio: IMediaAudioBuffer;
  Sample: IMediaSample;
  Info, InfoCopy: TMediaInfo;
  Streams: TMediaStreams;
  Metadata: TMediaMetadata;
  I: Integer;
  Failed: Boolean;
begin
  SetLength(Bytes, 8);
  Bytes[0]:=73;
  Video:=TMediaFrames.CopyVideo(Bytes, 1, 2, 4, mpfBGRA32, TMediaTime.FromSeconds(2), 4, True);
  Bytes[0]:=9;
  Copied:=Video.CopyBytes;
  Check(Copied[0] = 73, 'Factory must copy caller bytes');
  Copied[0]:=1;
  Copied:=Video.CopyBytes;
  Check(Copied[0] = 73, 'Copy accessor must not alias storage');
  Sample:=Video AS IMediaSample;
  Check((Sample.Kind = mkVideo) AND (Sample.StreamIndex = 4) AND Sample.FormatChanged, 'Tagged sample');
  Check(Sample.Timestamp.Microseconds = 2000000, 'Sample timestamp');
  SecondVideo:=TMediaFrames.CopyVideo(Bytes, 1, 2, 4, mpfBGRA32, TMediaTime.Unknown);
  Bytes:=nil;
  Video:=nil;
  SecondVideo:=nil;
  Copied:=Sample.CopyBytes;
  Check(Copied[0] = 73, 'Retained base interface must own video storage');
  Check(Supports(Sample, IMediaVideoFrame, Video), 'Retained sample supports typed video');
  Check((Video.Width = 1) AND (Video.Height = 2) AND (Video.Stride = 4), 'Video geometry');

  SetLength(Bytes, 1920);
  Bytes[0]:=42;
  Audio:=TMediaFrames.CopyAudio(Bytes, 480, 48000, msfS16, TMediaChannelLayout.Stereo, TMediaTime.FromSeconds(0));
  Bytes[0]:=0;
  Copied:=Audio.CopyBytes;
  Check((Copied[0] = 42) AND (Audio.SampleCount = 480) AND (Audio.Duration.Microseconds = 10000), 'Owned packed PCM/sample units');

  Info:=Default(TMediaInfo);
  SetLength(Metadata, 2);
  Metadata[0]:=TMediaMetadataEntry.Create('title', 'original');
  Metadata[1]:=TMediaMetadataEntry.Create('title', 'duplicate preserved');
  Info.Metadata:=Metadata;
  SetLength(Streams, 1);
  Streams[0].Index:=7;
  Streams[0].Metadata:=Metadata;
  Info.Streams:=Streams;
  InfoCopy:=Info;
  Metadata[0]:=TMediaMetadataEntry.Create('title', 'mutated');
  Streams[0].Index:=1;
  Streams:=Info.Streams;
  Check(Streams[0].Index = 7, 'Stream list must copy setter input');
  Streams[0].Metadata:=Metadata;
  InfoCopy.Streams:=Streams;
  Streams:=Info.Streams;
  Metadata:=Streams[0].Metadata;
  Check(Metadata[0].Value = 'original', 'Nested metadata lifetime/copy');
  Metadata:=Info.Metadata;
  Check((Metadata[0].Value = 'original') AND (Length(Metadata) = 2), 'Container metadata lifetime/duplicate keys');

  for I:=0 to 3 do
  begin
    Failed:=False;
    try
      case I of
        0: Video:=TMediaFrames.CopyVideo(Bytes, High(Integer), High(Integer), 4, mpfBGRA32, TMediaTime.Unknown);
        1: Video:=TMediaFrames.CopyVideo(Bytes, 1, 2, -4, mpfBGRA32, TMediaTime.Unknown);
        2: Audio:=TMediaFrames.CopyAudio(Bytes, 480, 48000, msfFloat32, TMediaChannelLayout.Stereo, TMediaTime.Unknown);
        3: Audio:=TMediaFrames.CopyAudio(Bytes, 480, 48000, msfS16, Default(TMediaChannelLayout), TMediaTime.Unknown);
      end;
    except
      on E: EFFmpegMediaError do
        Failed:=E.Category = mecInvalidSettings;
    end;
    Check(Failed, 'Invalid buffer case ' + IntToStr(I));
  end;
  WriteLn('PASS: immutable owned video/audio, retained interfaces, nested snapshots and allocation guards');
end;

type
  TCancelThread = class(TThread)
  private
    FSource: IMediaCancellationSource;
  protected
    procedure Execute; override;
  public
    constructor Create(const ASource: IMediaCancellationSource);
  end;

constructor TCancelThread.Create(const ASource: IMediaCancellationSource);
begin
  inherited Create(True);
  FSource:=ASource;
end;

procedure TCancelThread.Execute;
begin
  FSource.Cancel;
end;

procedure TestControl;
var
  Source: IMediaCancellationSource;
  Token: IMediaCancellationToken;
  Worker: TCancelThread;
  Failed: Boolean;
  ErrorValue: EFFmpegMediaError;
  Settings: TMediaInputSettings;
  Options: TMediaOptions;
begin
  Source:=TMediaCancellation.CreateSource;
  Token:=Source.Token;
  Check(NOT Token.IsCancellationRequested, 'Fresh token');
  Worker:=TCancelThread.Create(Source);
  try
    Worker.Start;
    Worker.WaitFor;
  finally
    Worker.Free;
  end;
  Source.Cancel;
  Source:=nil;
  Check(Token.IsCancellationRequested, 'Cross-thread cancellation and retained token');
  Failed:=False;
  try
    Token.ThrowIfCancellationRequested('test operation');
  except
    on E: EMediaCancelled do
      Failed:=(E.Category = mecCancelled) AND (E.Operation = 'test operation') AND NOT E.HasNativeCode;
  end;
  Check(Failed, 'Dedicated cancellation exception');
  ErrorValue:=EMediaTimedOut.Create('timeout operation');
  try
    Check((ErrorValue.Category = mecTimedOut) AND NOT ErrorValue.HasNativeCode, 'Timeout exception');
  finally
    ErrorValue.Free;
  end;
  ErrorValue:=EFFmpegMediaError.Create(mecDecode, 'Decode sample', 'Invalid bitstream', -123);
  try
    Check(ErrorValue.HasNativeCode AND (ErrorValue.NativeCode = -123) AND (ErrorValue.Operation = 'Decode sample'), 'Native diagnostics');
  finally
    ErrorValue.Free;
  end;

  Settings:=TMediaInputSettings.Default;
  Settings.Validate;
  SetLength(Options, 1);
  Options[0]:=TMediaOption.Create(mosDemuxer, 'analyzeduration', '1000000');
  Settings.Options:=Options;
  Options[0]:=TMediaOption.Create(mosDemuxer, 'max_streams', '1024');
  Settings.Validate;
  Settings.Options:=Options;
  Failed:=False;
  try
    Settings.Validate;
  except
    on E: EFFmpegMediaError do
      Failed:=E.Category = mecInvalidSettings;
  end;
  Check(Failed, 'Advanced options must not override typed limits');
  Settings:=Default(TMediaInputSettings);
  Failed:=False;
  try
    Settings.Validate;
  except
    on E: EFFmpegMediaError do
      Failed:=E.Category = mecInvalidSettings;
  end;
  Check(Failed, 'Zero-initialized input settings must fail explicitly');
  WriteLn('PASS: cross-thread cancellation, error diagnostics and explicit settings validation');
end;

procedure TestCapabilities;
begin
  Check(TMediaCapabilities.HasEncoder('pcm_s16le'), 'Required PCM encoder');
  Check(TMediaCapabilities.HasDecoder('pcm_s16le'), 'Required PCM decoder');
  Check(TMediaCapabilities.HasMuxer('wav'), 'Required WAV muxer');
  Check(TMediaCapabilities.HasDemuxer('wav'), 'Required WAV demuxer');
  Check(NOT TMediaCapabilities.HasEncoder('tffmpeg_missing_encoder'), 'Unavailable encoder must be false');
  WriteLn('PASS: native capabilities, runtime ', TMediaCapabilities.RuntimeVersion);
end;

begin
  try
    TestTime;
    TestOwnership;
    TestControl;
    TestCapabilities;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
