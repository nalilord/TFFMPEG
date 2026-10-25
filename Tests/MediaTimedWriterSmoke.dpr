program MediaTimedWriterSmoke;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Reader,
  TFFmpeg.Media.Writer,
  MediaTestSupport;

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

function Video(AIndex: Integer): IMediaVideoFrame;
var
  Bytes: TBytes;
  I: Integer;
begin
  Result:=nil;
  SetLength(Bytes, 32 * 24 * 4);
  for I:=0 to 32 * 24 - 1 do
  begin
    Bytes[I * 4]:=20 + AIndex * 10;
    Bytes[I * 4 + 1]:=40 + AIndex * 10;
    Bytes[I * 4 + 2]:=60 + AIndex * 10;
    Bytes[I * 4 + 3]:=255;
  end;
  Result:=TMediaFrames.CopyVideo(Bytes, 32, 24, 128, mpfBGRA32, TMediaTime.Unknown);
end;

function Audio(ACount: Integer; ATimestamp: Int64): IMediaAudioBuffer;
var
  Bytes: TBytes;
  I: Integer;
  Value: SmallInt;
begin
  Result:=nil;
  SetLength(Bytes, ACount * 2);
  for I:=0 to ACount - 1 do
  begin
    Value:=Round(10000 * Sin(I * 2 * Pi * 440 / 48000));
    Move(Value, Bytes[I * 2], 2);
  end;
  Result:=TMediaFrames.CopyAudio(Bytes, ACount, 48000, msfS16, TMediaChannelLayout.Mono, TMediaTime.FromMicroseconds(ATimestamp));
end;

procedure TestVFR(const AFilename: String);
const
  Times: Array[0..4] of Int64 = (0, 100000, 350000, 400000, 900000);
  Durations: Array[0..4] of Int64 = (100000, 250000, 50000, 500000, 100000);
var
  Settings: TMediaWriterSettings;
  Writer: IMediaWriter;
  Reader: IMediaReader;
  ReaderSettings: TMediaReaderSettings;
  Sample: IMediaSample;
  Bytes: TBytes;
  I: Integer;
begin
  Settings:=TMediaWriterSettings.H264MP4(32, 24, TMediaRate.Create(30000, 1001));
  Settings.Timing:=mwtPreserve;
  Writer:=TMediaWriter.OpenFile(AFilename, Settings);
  try
    Writer.SubmitVideo(Video(0));
    Check(False, 'Preservation must reject missing frame timing');
  except
    on E: EFFmpegMediaError do
      Check((E.Category = mecInvalidSettings) AND (Writer.State = mwsConfiguring), 'Timing validation leaves configuring session usable');
  end;
  for I:=0 to 4 do
    Writer.SubmitVideoAt(Video(I), TMediaTime.FromMicroseconds(Times[I]), TMediaTime.FromMicroseconds(Durations[I]));
  try
    Writer.SubmitVideoAt(Video(4), TMediaTime.FromMicroseconds(Times[4]), TMediaTime.FromMicroseconds(100000));
    Check(False, 'Duplicate video PTS must fail');
  except
    on E: EFFmpegMediaError do
      Check((E.Category = mecInvalidSettings) AND (Writer.State = mwsWriting), 'Timestamp guard leaves accepted frames usable');
  end;
  Writer.Finish;
  ReaderSettings:=TMediaReaderSettings.Default;
  ReaderSettings.AudioStreamIndex:=-2;
  Reader:=TMediaReader.OpenFile(AFilename, ReaderSettings);
  I:=0;
  while Reader.ReadSample(Sample) = mrsSample do
  begin
    Check(I < 5, 'No extra VFR output');
    Check(Abs(Sample.Timestamp.Microseconds - Times[I]) <= 1, 'Preserved VFR presentation time ' + IntToStr(I));
    Bytes:=Sample.CopyBytes;
    Check(Abs(Integer(Bytes[2]) - (60 + I * 10)) <= 5, 'VFR frame identity');
    Inc(I);
  end;
  Check(I = 5, 'Every VFR frame drained');
  Check(Abs(Reader.Info.Duration.Microseconds - 1000000) <= 1, 'VFR last-frame duration: ' + IntToStr(Reader.Info.Duration.Microseconds));
  Reader.Close;
end;

procedure TestOffset(const AFilename: String; AKind: Integer; AOffset: Int64 = 250000);
var
  Settings: TMediaWriterSettings;
  Writer: IMediaWriter;
  Reader: IMediaReader;
  ReaderSettings: TMediaReaderSettings;
  Sample: IMediaSample;
  FirstAudio: TMediaTime;
  I, Frames, Samples: Integer;
begin
  Settings:=TMediaWriterSettings.H264MP4(32, 24, TMediaRate.Create(10, 1));
  Settings.Timing:=mwtPreserve;
  Settings.Audio:=TMediaAudioEncoding.AAC(48000, 1);
  if AKind <> 2 then
  begin
    Settings.MuxerName:='matroska';
    Settings.Audio:=TMediaAudioEncoding.PCM(48000, 1);
    if AKind = 1 then
      Settings.Audio:=TMediaAudioEncoding.Opus(1);
  end;
  Writer:=TMediaWriter.OpenFile(AFilename, Settings);
  Writer.SubmitAudio(Audio(1177, AOffset));
  try
    Writer.SubmitAudio(Audio(1177, AOffset + 34520));
    Check(False, 'Audio gaps require an explicit conversion policy');
  except
    on E: EFFmpegMediaError do
      Check((E.Category = mecUnsupported) AND (Writer.State = mwsWriting), 'Audio gap guard leaves continuous writer usable');
  end;
  Writer.SubmitAudio(Audio(1177, AOffset + 24520));
  Writer.SubmitAudio(Audio(46, AOffset + 49041));
  for I:=0 to 11 do
    Writer.SubmitVideoAt(Video(I), TMediaTime.FromMicroseconds(Int64(I) * 100000), TMediaTime.FromMicroseconds(100000));
  Writer.Finish;
  ReaderSettings:=TMediaReaderSettings.Default;
  ReaderSettings.Channels:=1;
  Reader:=TMediaReader.OpenFile(AFilename, ReaderSettings);
  Frames:=0;
  Samples:=0;
  FirstAudio:=TMediaTime.Unknown;
  while Reader.ReadSample(Sample) = mrsSample do
    if Sample.Kind = mkVideo then
    begin
      Check(Abs(Sample.Timestamp.Microseconds - Int64(Frames) * 100000) <= 1, 'Offset output video clock');
      Inc(Frames);
    end else
    begin
      if NOT FirstAudio.Valid then
        FirstAudio:=Sample.Timestamp;
      Inc(Samples, (Sample AS IMediaAudioBuffer).SampleCount);
    end;
  Check((Frames = 12) AND (Samples = 2400), 'Preserved offset stream counts: ' + IntToStr(Frames) + '/' + IntToStr(Samples));
  Check(Abs(FirstAudio.Microseconds - AOffset) <= 1000, 'Preserved audio offset: ' + IntToStr(FirstAudio.Microseconds));
  Reader.Close;
end;

procedure TestUnsupported(const AFilename: String);
var
  Settings: TMediaWriterSettings;
  Encoding: TMediaVideoEncoding;
  Writer: IMediaWriter;
begin
  Settings:=TMediaWriterSettings.H264MP4(32, 24, TMediaRate.Create(10, 1));
  Settings.Timing:=mwtPreserve;
  Encoding:=Settings.Video;
  Encoding.Options:=[TMediaOption.Create(mosEncoder, 'x264-params', 'bframes=2')];
  Settings.Video:=Encoding;
  try
    Writer:=TMediaWriter.OpenFile(AFilename, Settings);
    Check(False, 'Reorder override is unsupported in preserving mode');
  except
    on E: EFFmpegMediaError do
      Check((E.Category = mecUnsupported) AND NOT Assigned(Writer), 'Reorder conflict fails before output reservation');
  end;
  Check(NOT FileExists(AFilename), 'Reorder conflict does not publish');
  Settings:=TMediaWriterSettings.H264MP4(32, 24, TMediaRate.Create(10, 1));
  Settings.Timing:=mwtPreserve;
  Settings.Audio:=TMediaAudioEncoding.AAC(48000, 1);
  Writer:=TMediaWriter.OpenFile(AFilename, Settings);
  try
    Writer.SubmitAudio(Audio(2400, 250000));
    Check(False, 'Delayed AAC/MP4 without valid trim must fail explicitly');
  except
    on E: EFFmpegMediaError do
      Check((E.Category = mecUnsupported) AND (Writer.State = mwsConfiguring), 'Delayed AAC capability guard precedes header/submission');
  end;
  Writer.Abort;
  Check(NOT FileExists(AFilename), 'Rejected delayed AAC does not publish incomplete output');
end;

procedure Run;
var
  Directory: TMediaTestDirectory;
begin
  Directory:=TMediaTestDirectory.Create;
  try
    if ParamCount = 1 then
    begin
      TestVFR(ParamStr(1));
      Exit;
    end;
    TestVFR(Directory.FileName('vfr.mp4'));
    TestOffset(Directory.FileName('offset-pcm.mkv'), 0);
    TestOffset(Directory.FileName('offset-opus.mkv'), 1);
    TestOffset(Directory.FileName('zero-offset-aac.mp4'), 2, 0);
    TestUnsupported(Directory.FileName('unsupported.mp4'));
    WriteLn('PASS: preserved VFR/durations, shared AV origin, PCM/Opus offsets, zero-offset AAC and explicit capability/discontinuity guards');
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
