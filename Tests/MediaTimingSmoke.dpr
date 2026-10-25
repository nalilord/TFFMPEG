program MediaTimingSmoke;

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
  TFFmpeg.Media.Reader,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Images,
  TFFmpeg.Media.Errors,
  MediaTestSupport;

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

function Fixture(const AName: String): String;
begin
  Result:=ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + 'fixtures' + PathDelim + AName);
end;

procedure FrameColor(const AFrame: IMediaVideoFrame; ARed, AGreen, ABlue, ATolerance: Integer);
var
  Bytes: TBytes;
begin
  Check(AFrame.PixelFormat = mpfBGRA32, 'Expected BGRA pixels');
  Bytes:=AFrame.CopyBytes;
  Check((Abs(Integer(Bytes[2]) - ARed) <= ATolerance) AND (Abs(Integer(Bytes[1]) - AGreen) <= ATolerance) AND
    (Abs(Integer(Bytes[0]) - ABlue) <= ATolerance),
    Format('RGB actual %d,%d,%d expected %d,%d,%d', [Bytes[2], Bytes[1], Bytes[0], ARed, AGreen, ABlue]));
end;

procedure TestReorderingAndVFR;
const
  VFR_TIMES: Array[0..4] of Int64 = (0, 100000, 350000, 400000, 900000);
var
  Reader: IMediaReader;
  Settings: TMediaReaderSettings;
  Sample: IMediaSample;
  Video: IMediaVideoFrame;
  Screenshot: TMediaScreenshot;
  I, Pass: Integer;
begin
  Settings:=TMediaReaderSettings.Default;
  Settings.AudioStreamIndex:=-2;
  Reader:=TMediaReader.OpenFile(Fixture('reordered.mp4'), Settings);
  for Pass:=0 to 1 do
  begin
    I:=0;
    while Reader.ReadSample(Sample) = mrsSample do
    begin
      Video:=Sample AS IMediaVideoFrame;
      Check(Video.Timestamp.Microseconds = Int64(I) * 100000, 'Reordered frame presentation timestamp');
      FrameColor(Video, 30 + I * 17, 20 + I * 13, 10 + I * 11, 5);
      Inc(I);
    end;
    Check(I = 12, 'All reordered/delayed frames must drain');
    if Pass = 0 then
      Reader.Seek(TMediaTime.FromSeconds(0));
  end;
  Reader.Close;
  Screenshot:=TMediaImages.ScreenshotFile(Fixture('reordered.mp4'), TMediaTime.FromSeconds(1.09));
  Check(Screenshot.ActualTime.Microseconds = 1100000, 'Decode-forward near EOF with B frames');
  FrameColor(Screenshot.Frame, 217, 163, 131, 5);
  Reader:=TMediaReader.OpenFile(Fixture('vfr.mp4'), Settings);
  I:=0;
  while Reader.ReadSample(Sample) = mrsSample do
  begin
    Check(I < Length(VFR_TIMES), 'Unexpected extra VFR frame');
    Check(Sample.Timestamp.Microseconds = VFR_TIMES[I], 'VFR timestamps must not be synthesized from average frame rate');
    Inc(I);
  end;
  Check(I = 5, 'All VFR frames must drain');
  Screenshot:=TMediaImages.ScreenshotFile(Fixture('vfr.mp4'), TMediaTime.FromSeconds(0.3));
  Check(Screenshot.ActualTime.Microseconds = 350000, 'VFR first at/after selection');
  FrameColor(Screenshot.Frame, 64, 46, 32, 5);
  Screenshot:=TMediaImages.ScreenshotFile(Fixture('vfr.mp4'), TMediaTime.FromSeconds(0.351));
  Check(Screenshot.ActualTime.Microseconds = 400000, 'VFR target between adjacent display timestamps');
  WriteLn('PASS: reordered decoder drain/seek, exact VFR times and near-EOF decode-forward frame identity');
end;

procedure TestOffsetsAndFormats;
var
  Reader: IMediaReader;
  Settings: TMediaReaderSettings;
  Info, OldInfo: TMediaInfo;
  Streams: TMediaStreams;
  Sample: IMediaSample;
  Video: IMediaVideoFrame;
  Audio: IMediaAudioBuffer;
  Screenshot: TMediaScreenshot;
  Count, Frames, Changes, OldWidth: Integer;
  AudioSamples: Int64;
  Failed: Boolean;
begin
  Settings:=TMediaReaderSettings.Default;
  Reader:=TMediaReader.OpenFile(Fixture('offsets.mkv'), Settings);
  Check(Reader.PresentationOrigin.Microseconds = 5000000, 'Common selected origin preserves nonzero source start');
  Frames:=0;
  AudioSamples:=0;
  while Reader.ReadSample(Sample) = mrsSample do
    if Sample.Kind = mkVideo then
    begin
      Check(Sample.Timestamp.Microseconds = Int64(Frames) * 100000, 'Video normalized to common origin');
      Inc(Frames);
    end else
    begin
      Audio:=Sample AS IMediaAudioBuffer;
      Check(Audio.Timestamp.Microseconds = 250000 + TMediaTime.FromTicks(AudioSamples, TMediaRate.Create(1, 48000)).Microseconds,
        'Relative AV offset must survive audio conversion');
      Inc(AudioSamples, Audio.SampleCount);
    end;
  Check((Frames = 12) AND (AudioSamples = 4800), 'Nonzero-start/unequal-length AV complete drain');
  Screenshot:=TMediaImages.ScreenshotFile(Fixture('offsets.mkv'), TMediaTime.FromSeconds(0.15));
  Check((Screenshot.ActualTime.Microseconds = 200000) AND (Screenshot.SourceStream.StartTime.Microseconds = 5000000), 'Screenshot position is relative to presentation origin');
  FrameColor(Screenshot.Frame, 64, 46, 32, 0);
  Settings.VideoStreamIndex:=-2;
  Reader:=TMediaReader.OpenFile(Fixture('offsets.mkv'), Settings);
  Check(Reader.PresentationOrigin.Microseconds = 5250000, 'Origin uses selected streams independently of container start');
  Check((Reader.ReadSample(Sample) = mrsSample) AND (Sample.Timestamp.Microseconds = 0), 'Audio-only selected origin');
  Reader.Close;

  Settings:=TMediaReaderSettings.Default;
  Settings.AudioStreamIndex:=-2;
  Settings.PixelFormat:=mpfRGB24;
  Reader:=TMediaReader.OpenFile(Fixture('format-change.h264'), Settings);
  OldInfo:=Reader.Info;
  Streams:=OldInfo.Streams;
  OldWidth:=Streams[0].Width;
  Count:=0;
  Changes:=0;
  while Reader.ReadSample(Sample) = mrsSample do
  begin
    Video:=Sample AS IMediaVideoFrame;
    if Count < 3 then
      Check((Video.Width = 32) AND (Video.Height = 24), 'Initial coded geometry')
    else
      Check((Video.Width = 64) AND (Video.Height = 48), 'Changed coded geometry');
    Check((Video.PixelFormat = mpfRGB24) AND (Video.Stride = Video.Width * 3), 'RGB24 actual format/stride');
    if Video.FormatChanged then
      Inc(Changes);
    Info:=Reader.Info;
    Streams:=Info.Streams;
    Check((Streams[0].Width = Video.Width) AND (Streams[0].Height = Video.Height), 'Session snapshot follows actual decoded format');
    Streams:=OldInfo.Streams;
    Check(Streams[0].Width = OldWidth, 'Old snapshot is detached from per-frame format updates');
    Inc(Count);
  end;
  Check((Count = 6) AND (Changes = 1), 'Video source-format change is reported once and conversion refreshes');
  Streams:=OldInfo.Streams;
  Check(Streams[0].Width = OldWidth, 'Old snapshot is detached from format updates');
  Reader:=TMediaReader.OpenFile(Fixture('unclocked.h264'), Settings);
  Check(NOT Reader.Info.Seekable, 'Untimestamped elementary stream is not presentation-time seekable');
  Failed:=False;
  try
    Reader.Seek(TMediaTime.FromSeconds(0));
  except
    on E: EFFmpegMediaError do
      Failed:=E.Category = mecUnsupported;
  end;
  Check(Failed, 'Native non-seekable input must fail explicitly');
  Check((Reader.ReadSample(Sample) = mrsSample) AND NOT Sample.Timestamp.Valid, 'Non-seekable guard leaves sequential read usable and preserves unknown time');
  WriteLn('PASS: nonzero selected origin/AV offset, source-format change, detached snapshots, RGB24 and native non-seekable input');
end;

procedure TestColorAndImages;
var
  Screenshot: TMediaScreenshot;
  Settings: TMediaScreenshotSettings;
  ImageSettings: TMediaImageSettings;
  Frame: IMediaVideoFrame;
  Reader: IMediaReader;
  Sample: IMediaSample;
  Failed: Boolean;
begin
  Screenshot:=TMediaImages.ScreenshotFile(Fixture('sdr709.mkv'), TMediaTime.FromSeconds(0));
  FrameColor(Screenshot.Frame, 255, 24, 0, 2);
  Screenshot:=TMediaImages.ScreenshotFile(Fixture('sdr601.mkv'), TMediaTime.FromSeconds(0));
  FrameColor(Screenshot.Frame, 254, 0, 0, 2);
  Screenshot:=TMediaImages.ScreenshotFile(Fixture('full709.mkv'), TMediaTime.FromSeconds(0));
  FrameColor(Screenshot.Frame, 255, 36, 10, 2);
  Reader:=TMediaReader.OpenFile(Fixture('hdr-pq.mp4'), TMediaReaderSettings.Default);
  Failed:=False;
  try
    Reader.ReadSample(Sample);
  except
    on E: EFFmpegMediaError do
      Failed:=(E.Category = mecUnsupported) AND (Pos('HDR', E.Message) > 0);
  end;
  Check(Failed AND NOT Assigned(Sample), 'PQ/HDR input must never silently become SDR');
  Frame:=TMediaImages.LoadFile(Fixture('exif.jpg'));
  Check((Frame.Width = 2) AND (Frame.Height = 3), 'EXIF orientation applies once on image load');
  ImageSettings:=TMediaImageSettings.Default;
  ImageSettings.Geometry:=migCoded;
  Frame:=TMediaImages.LoadFile(Fixture('exif.jpg'), ImageSettings);
  Check((Frame.Width = 3) AND (Frame.Height = 2), 'EXIF coded geometry option');
  Failed:=False;
  try
    TMediaImages.ScreenshotFile(Fixture('unclocked.h264'), TMediaTime.FromSeconds(0));
  except
    on E: EFFmpegMediaError do
      Failed:=(E.Category = mecUnsupported) AND (Pos('timestamps', E.Message) > 0);
  end;
  Check(Failed, 'Native missing timestamps fail accurate first-frame screenshot');
  Settings:=TMediaScreenshotSettings.Default;
  Settings.Policy:=mspAllowUnknownTimestamp;
  Screenshot:=TMediaImages.ScreenshotFile(Fixture('unclocked.h264'), TMediaTime.FromSeconds(0), Settings);
  Check(Screenshot.Approximate AND NOT Screenshot.ActualTime.Valid, 'Native approximate policy reports unknown actual time');
  WriteLn('PASS: independent SDR matrix/range vectors, HDR rejection, EXIF orientation and native unknown-timestamp policies');
end;

procedure TestAudioChangeAndTruncation;
var
  Reader: IMediaReader;
  Settings: TMediaReaderSettings;
  Sample: IMediaSample;
  Directory: TMediaTestDirectory;
  Input, Output: TFileStream;
  Name: String;
  Failed: Boolean;
  Count, I: Integer;
begin
  Settings:=TMediaReaderSettings.Default;
  Settings.VideoStreamIndex:=-2;
  Reader:=TMediaReader.OpenFile(Fixture('audio-change.aac'), Settings);
  Failed:=False;
  Count:=0;
  try
    while Reader.ReadSample(Sample) = mrsSample do
      Inc(Count);
  except
    on E: EFFmpegMediaError do
      Failed:=(E.Category = mecUnsupported) AND (Pos('format/layout', E.Message) > 0);
  end;
  Check(Failed AND (Count > 0) AND NOT Assigned(Sample), 'Audio source-format change must fail explicitly without stale output');
  Reader.Close;
  Directory:=TMediaTestDirectory.Create;
  try
    for I:=0 to 1 do
    begin
      if I = 0 then
        Name:='reordered.mp4'
      else
        Name:='colors.bmp';
      Input:=TFileStream.Create(Fixture(Name), fmOpenRead OR fmShareDenyWrite);
      try
        Output:=TFileStream.Create(Directory.FileName(Name), fmCreate);
        try
          if I = 0 then
            Output.CopyFrom(Input, 512)
          else
            Output.CopyFrom(Input, 55);
        finally
          Output.Free;
        end;
      finally
        Input.Free;
      end;
      Failed:=False;
      try
        if I = 0 then
          Reader:=TMediaReader.OpenFile(Directory.FileName(Name), TMediaReaderSettings.Default)
        else
          TMediaImages.LoadFile(Directory.FileName(Name));
      except
        on E: EFFmpegMediaError do
          Failed:=E.Category IN [mecInputOutput, mecDecode];
      end;
      Check(Failed, 'Truncated media/image must fail instead of producing a complete result');
      Check(DeleteFile(Directory.FileName(Name)), 'Failed decode must release the truncated input file handle');
      Reader:=TMediaReader.OpenFile(Fixture('video.mkv'), TMediaReaderSettings.Default);
      Check(Reader.ReadSample(Sample) = mrsSample, 'Reopen after truncated input failure');
      Reader.Close;
    end;
  finally
    Directory.Free;
  end;
  WriteLn('PASS: explicit audio-format-change failure, corrupt/truncated input cleanup and successful reopen');
end;

procedure TestSelectedTracksAndArt;
var
  Reader: IMediaReader;
  Settings: TMediaReaderSettings;
  Sample: IMediaSample;
  Audio: IMediaAudioBuffer;
  Bytes: TBytes;
  First, Last: SmallInt;
  Track, Count: Integer;
begin
  Settings:=TMediaReaderSettings.Default;
  Settings.VideoStreamIndex:=-2;
  Settings.SampleRate:=24000;
  Settings.Channels:=1;
  for Track:=1 to 2 do
  begin
    Settings.AudioStreamIndex:=Track;
    Reader:=TMediaReader.OpenFile(Fixture('tracks.mkv'), Settings);
    Count:=0;
    First:=0;
    Last:=0;
    while Reader.ReadSample(Sample) = mrsSample do
    begin
      Audio:=Sample AS IMediaAudioBuffer;
      Check(Audio.StreamIndex = Track, 'Explicit audio source index');
      Bytes:=Audio.CopyBytes;
      if Count = 0 then
        First:=PSmallInt(@Bytes[0])^;
      Last:=PSmallInt(@Bytes[Length(Bytes) - 2])^;
      Inc(Count, Audio.SampleCount);
    end;
    Check(Count = 2400, 'Selected audio track sample count');
    if Track = 1 then
      Check((First = 1234) AND (Last = -2345), 'First selected track signal identity')
    else
      Check((First = -1234) AND (Last = 2345), 'Second selected track has a distinguishable signal');
    Reader.Close;
  end;
  Settings:=TMediaReaderSettings.Default;
  Settings.VideoStreamIndex:=3;
  Settings.AudioStreamIndex:=-2;
  Reader:=TMediaReader.OpenFile(Fixture('tracks.mkv'), Settings);
  Check((Reader.ReadSample(Sample) = mrsSample) AND (Sample.StreamIndex = 3), 'Explicit alternate video track index');
  FrameColor(Sample AS IMediaVideoFrame, 0, 0, 255, 0);
  Reader.Close;
  Settings:=TMediaReaderSettings.Default;
  Settings.SampleRate:=24000;
  Settings.Channels:=1;
  Reader:=TMediaReader.OpenFile(Fixture('cover.mp3'), Settings);
  Count:=0;
  while Reader.ReadSample(Sample) = mrsSample do
  begin
    Check(Sample.Kind = mkAudio, 'Cover art must not become default decoded video');
    Audio:=Sample AS IMediaAudioBuffer;
    Inc(Count, Audio.SampleCount);
  end;
  Check(Count = 2400, 'MP3 native skip/padding handling must not duplicate or omit decoded source samples');
  WriteLn('PASS: explicit audio/video selection by actual signal identity, default attached-art exclusion and MP3 drain count');
end;

begin
  try
    TestReorderingAndVFR;
    TestOffsetsAndFormats;
    TestColorAndImages;
    TestAudioChangeAndTruncation;
    TestSelectedTracksAndArt;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
