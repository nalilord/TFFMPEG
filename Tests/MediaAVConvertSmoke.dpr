program MediaAVConvertSmoke;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
  Classes,
{$ELSE}
  System.SysUtils,
  System.Classes,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Reader,
  TFFmpeg.Media.Writer,
  TFFmpeg.Media.Images,
  TFFmpeg.Media.Convert,
  MediaTestSupport;

type
  TAVObserver = class
  private
    FSource: IMediaCancellationSource;
    FCancelStage: Integer;
    FErrorStage: Integer;
  public
    constructor Create;
    procedure Progress(const AProgress: TMediaProgress);
    property Source: IMediaCancellationSource read FSource write FSource;
    property CancelStage: Integer read FCancelStage write FCancelStage;
    property ErrorStage: Integer read FErrorStage write FErrorStage;
  end;

constructor TAVObserver.Create;
begin
  inherited Create;
  FCancelStage:=-1;
  FErrorStage:=-1;
end;

procedure TAVObserver.Progress(const AProgress: TMediaProgress);
begin
  if (AProgress.Stage = mpsProcessing) AND (AProgress.Bytes = 0) then
    Exit;
  if Ord(AProgress.Stage) = FCancelStage then
    FSource.Cancel;
  if Ord(AProgress.Stage) = FErrorStage then
    raise Exception.Create('Controlled AV callback failure');
end;

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

function Fixture(const AName: String): String;
begin
  Result:=ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + 'fixtures' + PathDelim + AName);
  Check(FileExists(Result), 'Missing fixture ' + Result);
end;

procedure TestOffsets(const AFilename: String);
var
  Settings: TMediaAVConvertSettings;
  Converted: TMediaConversionResult;
  ReaderSettings: TMediaReaderSettings;
  Reader: IMediaReader;
  Sample: IMediaSample;
  Frame: IMediaVideoFrame;
  Bytes: TBytes;
  VideoStart, AudioStart: TMediaTime;
  Frames, Samples: Integer;
begin
  Settings:=TMediaAVConvertSettings.H264OpusMatroska(64, 48, TMediaRate.Create(30000, 1001));
  Converted:=TMediaConvert.MediaFile(Fixture('offsets.mkv'), AFilename, Settings);
  Check((Converted.VideoFrames = 12) AND (Converted.AudioSamples = 4800), 'Selected AV conversion counts');
  Check((Converted.VideoEncoderName = 'libx264') AND (Converted.AudioEncoderName = 'libopus'), 'Explicit AV encoder reporting');
  Check((Converted.DroppedFrames = 0) AND (Converted.DuplicatedFrames = 0), 'VFR preservation never duplicates/drops');
  Check(Abs(Converted.Duration.Microseconds - 1200000) <= 1, 'Conversion result has shared normalized duration');
  ReaderSettings:=TMediaReaderSettings.Default;
  Reader:=TMediaReader.OpenFile(AFilename, ReaderSettings);
  Frames:=0;
  Samples:=0;
  VideoStart:=TMediaTime.Unknown;
  AudioStart:=TMediaTime.Unknown;
  while Reader.ReadSample(Sample) = mrsSample do
    if Sample.Kind = mkVideo then
    begin
      Frame:=Sample AS IMediaVideoFrame;
      if NOT VideoStart.Valid then
        VideoStart:=Frame.Timestamp;
      Check((Frame.Width = 64) AND (Frame.Height = 48), 'Explicit AV output dimensions');
      Check(Abs(Frame.Timestamp.Subtract(VideoStart).Microseconds - Int64(Frames) * 100000) <= 1000, 'Preserved video cadence');
      Bytes:=Frame.CopyBytes;
      Check((Abs(Integer(Bytes[2]) - (30 + Frames * 17)) <= 8) AND
        (Abs(Integer(Bytes[1]) - (20 + Frames * 13)) <= 8) AND
        (Abs(Integer(Bytes[0]) - (10 + Frames * 11)) <= 8), 'Converted AV frame identity ' + IntToStr(Frames));
      Inc(Frames);
    end else
    begin
      if NOT AudioStart.Valid then
        AudioStart:=Sample.Timestamp;
      Inc(Samples, (Sample AS IMediaAudioBuffer).SampleCount);
    end;
  Check((Frames = 12) AND (Samples = 4800), 'Reopened AV output drains every stream');
  Check(Abs(AudioStart.Subtract(VideoStart).Microseconds - 250000) <= 1000, 'Preserved relative 250-ms offset: ' +
    IntToStr(AudioStart.Subtract(VideoStart).Microseconds));
  Check(Abs(Reader.Info.Duration.Microseconds - 1200000) <= 1000, 'Unequal stream lengths do not truncate video');
  Reader.Close;
end;

procedure TestVFR(const AFilename: String; AConstant: Boolean);
const
  Times: Array[0..4] of Int64 = (0, 100000, 350000, 400000, 900000);
  ConstantIDs: Array[0..9] of Integer = (0, 1, 1, 1, 3, 3, 3, 3, 3, 4);
var
  Settings: TMediaAVConvertSettings;
  Converted: TMediaConversionResult;
  Reader: IMediaReader;
  Sample: IMediaSample;
  Bytes: TBytes;
  ExpectedTime: Int64;
  Count, Identity: Integer;
  ReaderSettings: TMediaReaderSettings;
begin
  Settings:=TMediaAVConvertSettings.H264AACMP4(32, 24, TMediaRate.Create(10, 1));
  if AConstant then
    Settings.VideoTiming:=mvpConstantRate;
  Converted:=TMediaConvert.MediaFile(Fixture('vfr.mp4'), AFilename, Settings);
  if AConstant then
    Check((Converted.VideoFrames = 10) AND (Converted.DuplicatedFrames = 6) AND (Converted.DroppedFrames = 1), 'CFR duplicate/drop rules and counters')
  else
    Check((Converted.VideoFrames = 5) AND (Converted.DuplicatedFrames = 0) AND (Converted.DroppedFrames = 0), 'Preserved VFR counters');
  Check((Converted.AudioSamples = 0) AND (Converted.AudioEncoderName = ''), 'Absent default audio is omitted explicitly');
  ReaderSettings:=TMediaReaderSettings.Default;
  ReaderSettings.AudioStreamIndex:=-2;
  Reader:=TMediaReader.OpenFile(AFilename, ReaderSettings);
  Count:=0;
  while Reader.ReadSample(Sample) = mrsSample do
  begin
    if AConstant then
    begin
      Check(Count < 10, 'No extra CFR frame');
      ExpectedTime:=Int64(Count) * 100000;
      Identity:=ConstantIDs[Count];
    end else
    begin
      Check(Count < 5, 'No extra VFR frame');
      ExpectedTime:=Times[Count];
      Identity:=Count;
    end;
    Check(Abs(Sample.Timestamp.Microseconds - ExpectedTime) <= 1, 'Converted video presentation time ' + IntToStr(Count));
    Bytes:=Sample.CopyBytes;
    Check(Abs(Integer(Bytes[2]) - (30 + Identity * 17)) <= 8, 'Duplicate/drop frame identity ' + IntToStr(Count));
    Inc(Count);
  end;
  Check(Count = Converted.VideoFrames, 'Decoded output count matches actual submissions');
  Check(Abs(Reader.Info.Duration.Microseconds - 1000000) <= 1, 'Final frame end policy preserves VFR duration');
  Reader.Close;
end;

procedure TestReordered(const AFilename: String);
var
  Settings: TMediaAVConvertSettings;
  Converted: TMediaConversionResult;
  Reader: IMediaReader;
  ReaderSettings: TMediaReaderSettings;
  Sample: IMediaSample;
  Count: Integer;
begin
  Settings:=TMediaAVConvertSettings.H264AACMP4(32, 24, TMediaRate.Create(10, 1));
  Converted:=TMediaConvert.MediaFile(Fixture('reordered.mp4'), AFilename, Settings);
  Check(Converted.VideoFrames = 12, 'All reordered source frames are drained');
  ReaderSettings:=TMediaReaderSettings.Default;
  ReaderSettings.AudioStreamIndex:=-2;
  Reader:=TMediaReader.OpenFile(AFilename, ReaderSettings);
  Count:=0;
  while Reader.ReadSample(Sample) = mrsSample do
  begin
    Check(Sample.Timestamp.Microseconds = Int64(Count) * 100000, 'Reordered source display time');
    Inc(Count);
  end;
  Check(Count = 12, 'Reordered output drain complete');
  Reader.Close;
end;

procedure TestSelection(const AFilename, AReencoded: String);
var
  Settings: TMediaAVConvertSettings;
  Converted: TMediaConversionResult;
  Reader: IMediaReader;
  Sample: IMediaSample;
  Bytes: TBytes;
  FirstVideo, FirstAudio: TMediaTime;
  Count, Samples, Pass: Integer;
begin
  Settings:=TMediaAVConvertSettings.H264OpusMatroska(32, 24, TMediaRate.Create(10, 1));
  Settings.VideoStreamIndex:=3;
  Settings.AudioStreamIndex:=1;
  Converted:=TMediaConvert.MediaFile(Fixture('tracks.mkv'), AFilename, Settings);
  Check((Converted.VideoFrames = 3) AND (Converted.AudioSamples = 4800), 'Explicit nondefault AV mappings');
  for Pass:=0 to 1 do
  begin
    if Pass = 1 then
    begin
      Settings.VideoStreamIndex:=-1;
      Settings.AudioStreamIndex:=-1;
      Converted:=TMediaConvert.MediaFile(AFilename, AReencoded, Settings);
      Check(Abs(Converted.Duration.Microseconds - 300000) <= 1000, 'Codec delay must not accumulate across conversions');
      Reader:=TMediaReader.OpenFile(AReencoded, TMediaReaderSettings.Default);
    end else
      Reader:=TMediaReader.OpenFile(AFilename, TMediaReaderSettings.Default);
    FirstVideo:=TMediaTime.Unknown;
    FirstAudio:=TMediaTime.Unknown;
    Count:=0;
    Samples:=0;
    while Reader.ReadSample(Sample) = mrsSample do
      if Sample.Kind = mkVideo then
      begin
        if NOT FirstVideo.Valid then
          FirstVideo:=Sample.Timestamp;
        Bytes:=Sample.CopyBytes;
        Check((Bytes[0] >= 248) AND (Bytes[1] <= 8) AND (Bytes[2] <= 8), 'Selected alternate blue video track');
        Inc(Count);
      end else
      begin
        if NOT FirstAudio.Valid then
          FirstAudio:=Sample.Timestamp;
        Inc(Samples, (Sample AS IMediaAudioBuffer).SampleCount);
      end;
    Check((Count = 3) AND (Samples = 4800), 'Mapped stream counts after re-encode');
    Check((Abs(FirstVideo.Microseconds) <= 1000) AND (Abs(FirstAudio.Microseconds) <= 1000),
      'Presentation origin excludes native codec priming: ' + IntToStr(FirstVideo.Microseconds) + '/' + IntToStr(FirstAudio.Microseconds));
    Reader.Close;
  end;
end;

procedure TestChangingGeometry(const AFilename: String);
var
  Settings: TMediaAVConvertSettings;
  Converted: TMediaConversionResult;
  Reader: IMediaReader;
  Sample: IMediaSample;
  Frame: IMediaVideoFrame;
  Bytes: TBytes;
  Count, Identity: Integer;
begin
  Settings:=TMediaAVConvertSettings.H264AACMP4(32, 24, TMediaRate.Create(10, 1));
  Converted:=TMediaConvert.MediaFile(Fixture('format-change.ts'), AFilename, Settings);
  Check(Converted.VideoFrames = 6, 'Geometry changes retain every displayed frame');
  Reader:=TMediaReader.OpenFile(AFilename, TMediaReaderSettings.Default);
  Count:=0;
  while Reader.ReadSample(Sample) = mrsSample do
  begin
    Frame:=Sample AS IMediaVideoFrame;
    Check((Frame.Width = 32) AND (Frame.Height = 24), 'Explicit resizing normalizes changing source geometry');
    Check(Abs(Frame.Timestamp.Microseconds - Int64(Count) * 100000) <= 1, 'Changing geometry preserves source clock');
    Identity:=Count MOD 3;
    Bytes:=Frame.CopyBytes;
    Check(Abs(Integer(Bytes[2]) - (30 + Identity * 17)) <= 8, 'Changing geometry preserves frame identity');
    Inc(Count);
  end;
  Check(Count = 6, 'Changed geometry drain completes');
  Reader.Close;
end;

procedure TestRationalCFR(const AFilename: String);
var
  Settings: TMediaAVConvertSettings;
  Converted: TMediaConversionResult;
  Reader: IMediaReader;
  Sample: IMediaSample;
  Count: Integer;
begin
  Settings:=TMediaAVConvertSettings.H264AACMP4(32, 24, TMediaRate.Create(30000, 1001));
  Settings.VideoTiming:=mvpConstantRate;
  Converted:=TMediaConvert.MediaFile(Fixture('vfr.mp4'), AFilename, Settings);
  Check((Converted.VideoFrames = 30) AND (Converted.Duration.Microseconds = 1001000), 'Rational CFR endpoint is within one output frame');
  Reader:=TMediaReader.OpenFile(AFilename, TMediaReaderSettings.Default);
  Count:=0;
  while Reader.ReadSample(Sample) = mrsSample do
  begin
    Check(Abs(Sample.Timestamp.Microseconds - Int64(Count) * 1001000000 DIV 30000) <= 1, 'Rational CFR has no cumulative tick drift');
    Inc(Count);
  end;
  Check(Count = 30, 'Rational CFR frame count');
  Reader.Close;
end;

procedure TestDisplayGeometry(const AFilename: String);
var
  Settings: TMediaAVConvertSettings;
  Image: TMediaImageSettings;
  Converted: TMediaConversionResult;
  Reader: IMediaReader;
  Sample: IMediaSample;
  Frame: IMediaVideoFrame;
  Bytes: TBytes;
begin
  Settings:=TMediaAVConvertSettings.H264AACMP4(12, 32, TMediaRate.Create(10, 1));
  Image:=Settings.Image;
  Image.Fit:=mfFit;
  Settings.Image:=Image;
  Converted:=TMediaConvert.MediaFile(Fixture('rotated.mp4'), AFilename, Settings);
  Check(Converted.VideoFrames = 3, 'Display conversion frame count');
  Reader:=TMediaReader.OpenFile(AFilename, TMediaReaderSettings.Default);
  Check(Reader.ReadSample(Sample) = mrsSample, 'Display conversion produces a frame');
  Frame:=Sample AS IMediaVideoFrame;
  Check((Frame.Width = 12) AND (Frame.Height = 32), 'SAR is applied before the quarter turn');
  Bytes:=Frame.CopyBytes;
  Check((Bytes[2] > 200) AND (Bytes[1] < 20) AND (Bytes[0] < 20), 'Display fit fills target without erroneous bars');
  Reader.Close;
end;

procedure TestEarlyAudio(const ASource, APreserved, AConstant: String);
var
  WriterSettings: TMediaWriterSettings;
  Writer: IMediaWriter;
  Frame: IMediaVideoFrame;
  VideoBytes, AudioBytes: TBytes;
  Value: SmallInt;
  Settings: TMediaAVConvertSettings;
  Converted: TMediaConversionResult;
  Reader: IMediaReader;
  Sample: IMediaSample;
  FirstVideo, FirstAudio: TMediaTime;
  I, Pass, Frames, Samples: Integer;
begin
  SetLength(VideoBytes, 32 * 24 * 4);
  for I:=0 to 32 * 24 - 1 do
  begin
    VideoBytes[I * 4]:=64;
    VideoBytes[I * 4 + 1]:=64;
    VideoBytes[I * 4 + 2]:=64;
    VideoBytes[I * 4 + 3]:=255;
  end;
  Frame:=TMediaFrames.CopyVideo(VideoBytes, 32, 24, 128, mpfBGRA32, TMediaTime.Unknown);
  SetLength(AudioBytes, 4800 * 2);
  for I:=0 to 4799 do
  begin
    Value:=Round(10000 * Sin(I * 2 * Pi * 440 / 48000));
    Move(Value, AudioBytes[I * 2], 2);
  end;
  WriterSettings:=TMediaWriterSettings.H264MP4(32, 24, TMediaRate.Create(10, 1));
  WriterSettings.MuxerName:='matroska';
  WriterSettings.Timing:=mwtPreserve;
  WriterSettings.Audio:=TMediaAudioEncoding.PCM(48000, 1);
  Writer:=TMediaWriter.OpenFile(ASource, WriterSettings);
  Writer.SubmitAudio(TMediaFrames.CopyAudio(AudioBytes, 4800, 48000, msfS16, TMediaChannelLayout.Mono, TMediaTime.FromMicroseconds(0)));
  for I:=0 to 11 do
    Writer.SubmitVideoAt(Frame, TMediaTime.FromMicroseconds(250000 + Int64(I) * 100000), TMediaTime.FromMicroseconds(100000));
  Writer.Finish;
  Settings:=TMediaAVConvertSettings.H264OpusMatroska(32, 24, TMediaRate.Create(10, 1));
  for Pass:=0 to 1 do
  begin
    if Pass = 0 then
    begin
      Converted:=TMediaConvert.MediaFile(ASource, APreserved, Settings);
      Reader:=TMediaReader.OpenFile(APreserved, TMediaReaderSettings.Default);
      Check(Converted.Duration.Microseconds = 1450000, 'Preserved timeline end with earlier audio');
    end else
    begin
      Settings.VideoTiming:=mvpConstantRate;
      Converted:=TMediaConvert.MediaFile(ASource, AConstant, Settings);
      Reader:=TMediaReader.OpenFile(AConstant, TMediaReaderSettings.Default);
      Check(Converted.Duration.Microseconds = 1500000, 'CFR endpoint extends by less than one frame');
    end;
    FirstVideo:=TMediaTime.Unknown;
    FirstAudio:=TMediaTime.Unknown;
    Frames:=0;
    Samples:=0;
    while Reader.ReadSample(Sample) = mrsSample do
      if Sample.Kind = mkVideo then
      begin
        if NOT FirstVideo.Valid then
          FirstVideo:=Sample.Timestamp;
        Inc(Frames);
      end else
      begin
        if NOT FirstAudio.Valid then
          FirstAudio:=Sample.Timestamp;
        Inc(Samples, (Sample AS IMediaAudioBuffer).SampleCount);
      end;
    Check((Frames = 12) AND (Samples = 4800), 'Earlier-audio unequal-length stream counts');
    if Pass = 0 then
      Check(Abs(FirstVideo.Subtract(FirstAudio).Microseconds - 250000) <= 1000, 'Video retains later 250-ms start')
    else
      Check(Abs(FirstVideo.Subtract(FirstAudio).Microseconds - 300000) <= 1000, 'CFR starts on the first global grid point at/after video start');
    Reader.Close;
  end;
end;

procedure Sentinel(const AFilename: String; AWrite: Boolean);
var
  Stream: TFileStream;
  Value: Byte;
begin
  Value:=71;
  if AWrite then
    Stream:=TFileStream.Create(AFilename, fmCreate)
  else
    Stream:=TFileStream.Create(AFilename, fmOpenRead OR fmShareDenyNone);
  try
    if AWrite then
      Stream.WriteBuffer(Value, 1)
    else
    begin
      Check(Stream.Size = 1, 'Failed AV conversion preserves destination size');
      Stream.ReadBuffer(Value, 1);
      Check(Value = 71, 'Failed AV conversion preserves destination bytes');
    end;
  finally
    Stream.Free;
  end;
end;

procedure CheckNoSibling(const AFilename: String);
var
  Search: TSearchRec;
begin
  if FindFirst(AFilename + '.tffmpeg-*', faAnyFile, Search) = 0 then
  begin
    FindClose(Search);
    raise Exception.Create('Leaked AV output sibling');
  end;
end;

procedure TestFailures(const AFilename: String);
var
  Settings: TMediaAVConvertSettings;
  Output: TMediaWriterSettings;
  Observer: TAVObserver;
  Source: IMediaCancellationSource;
  I: Integer;
begin
  Settings:=TMediaAVConvertSettings.H264OpusMatroska(32, 24, TMediaRate.Create(10, 1));
  Output:=Settings.Output;
  Output.Overwrite:=True;
  Settings.Output:=Output;
  Settings.ProgressIntervalMilliseconds:=0;
  Sentinel(AFilename, True);
  Observer:=TAVObserver.Create;
  try
    for I:=Ord(mpsOpening) to Ord(mpsFinalizing) do
    begin
      Source:=TMediaCancellation.CreateSource;
      Observer.Source:=Source;
      Observer.CancelStage:=I;
      try
        TMediaConvert.MediaFile(Fixture('offsets.mkv'), AFilename, Settings, Observer.Progress, Source.Token);
        Check(False, 'AV cancellation must propagate');
      except
        on E: EMediaCancelled do
          Sentinel(AFilename, False);
      end;
      CheckNoSibling(AFilename);
    end;
    Observer.CancelStage:=-1;
    Observer.ErrorStage:=Ord(mpsProcessing);
    try
      TMediaConvert.MediaFile(Fixture('offsets.mkv'), AFilename, Settings, Observer.Progress);
      Check(False, 'AV callback exception must propagate');
    except
      on E: Exception do
        Check(E.Message = 'Controlled AV callback failure', 'AV callback exception identity');
    end;
    Sentinel(AFilename, False);
    CheckNoSibling(AFilename);
    try
      TMediaConvert.MediaFile(Fixture('audio-gap.mka'), AFilename, Settings);
      Check(False, 'Audio gap must fail explicitly');
    except
      on E: EFFmpegMediaError do
        Check((E.Category = mecUnsupported) AND (Pos('discontinuity', E.Message) > 0), 'Audio gap policy diagnostic');
    end;
    Sentinel(AFilename, False);
    CheckNoSibling(AFilename);
    try
      TMediaConvert.MediaFile(Fixture('audio-change.aac'), AFilename, Settings);
      Check(False, 'Audio format change must fail explicitly');
    except
      on E: EFFmpegMediaError do
        Check(E.Category = mecUnsupported, 'Fixed audio format change diagnostic');
    end;
    Sentinel(AFilename, False);
    CheckNoSibling(AFilename);
    Settings.VideoStreamIndex:=1;
    try
      TMediaConvert.MediaFile(Fixture('tracks.mkv'), AFilename, Settings);
      Check(False, 'Wrong-kind explicit video mapping must fail');
    except
      on E: EFFmpegMediaError do
        Check(E.Category = mecInvalidSettings, 'Explicit mapping error category');
    end;
    Sentinel(AFilename, False);
    Settings.VideoStreamIndex:=-1;
    try
      TMediaConvert.MediaFile(Fixture('unclocked.h264'), AFilename, Settings);
      Check(False, 'Unclocked video requires explicit unsupported error');
    except
      on E: EFFmpegMediaError do
        Check(E.Category = mecUnsupported, 'Unclocked source category');
    end;
    Sentinel(AFilename, False);
    CheckNoSibling(AFilename);
    Settings:=TMediaAVConvertSettings.H264AACMP4(32, 24, TMediaRate.Create(10, 1));
    Output:=Settings.Output;
    Output.Overwrite:=True;
    Settings.Output:=Output;
    try
      TMediaConvert.MediaFile(Fixture('offsets.mkv'), AFilename, Settings);
      Check(False, 'Unsupported AAC/MP4 offset must fail rather than lose trim');
    except
      on E: EFFmpegMediaError do
        Check((E.Category = mecUnsupported) AND (Pos('MP4/AAC', E.Message) > 0), 'Explicit AAC/MP4 offset limitation');
    end;
    Sentinel(AFilename, False);
    CheckNoSibling(AFilename);
  finally
    Observer.Free;
  end;
end;

procedure Run;
var
  Directory: TMediaTestDirectory;
begin
  Directory:=TMediaTestDirectory.Create;
  try
    TestOffsets(Directory.FileName('offsets.mkv'));
    TestVFR(Directory.FileName('vfr.mp4'), False);
    TestVFR(Directory.FileName('constant.mp4'), True);
    TestReordered(Directory.FileName('reordered.mp4'));
    TestSelection(Directory.FileName('selected.mkv'), Directory.FileName('reencoded.mkv'));
    TestChangingGeometry(Directory.FileName('geometry.mp4'));
    TestRationalCFR(Directory.FileName('rational.mp4'));
    TestDisplayGeometry(Directory.FileName('display.mp4'));
    TestEarlyAudio(Directory.FileName('early-source.mkv'), Directory.FileName('early-preserved.mkv'), Directory.FileName('early-cfr.mkv'));
    TestFailures(Directory.FileName('failed.mkv'));
    WriteLn('PASS: coordinated AV conversion, shared offsets, resize/identity, VFR, CFR duplicate/drop and reorder drain');
  finally
    Directory.Free;
  end;
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
