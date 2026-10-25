program MediaResourceSmoke;

{$APPTYPE CONSOLE}
{$R+}
{$Q+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Reader,
  TFFmpeg.Media.Writer,
  TFFmpeg.Media.Images,
  MediaTestSupport,
  MediaResourceSupport;

const
  LONG_VIDEO_FRAMES = 18000;
  AUDIO_SAMPLES_PER_FRAME = 1600;

type
  TMediaResources = class
  private
    FDirectory: TMediaTestDirectory;
    FVideo: IMediaVideoFrame;
    FAudio: IMediaAudioBuffer;
    FWriterSettings: TMediaWriterSettings;
    FReaderSettings: TMediaReaderSettings;
    FImageWriteSettings: TMediaImageWriteSettings;
  public
    constructor Create;
    destructor Destroy; override;
    procedure WriteMedia(const AFilename: String; AFrames: Integer);
    procedure ReadMedia(const AFilename: String; AFrames: Integer);
    procedure Cycle;
    procedure Run;
  end;

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

constructor TMediaResources.Create;
var
  Bytes: TBytes;
  I: Integer;
  Value: SmallInt;
begin
  inherited Create;
  FDirectory:=TMediaTestDirectory.Create;
  SetLength(Bytes, 16 * 16 * 4);
  for I:=0 to 16 * 16 - 1 do
  begin
    Bytes[I * 4]:=10;
    Bytes[I * 4 + 1]:=30;
    Bytes[I * 4 + 2]:=200;
    Bytes[I * 4 + 3]:=255;
  end;
  FVideo:=TMediaFrames.CopyVideo(Bytes, 16, 16, 64, mpfBGRA32, TMediaTime.FromMicroseconds(0));
  SetLength(Bytes, AUDIO_SAMPLES_PER_FRAME * 2);
  for I:=0 to AUDIO_SAMPLES_PER_FRAME - 1 do
  begin
    Value:=10000;
    if I MOD 48 >= 24 then
      Value:=-10000;
    Move(Value, Bytes[I * 2], SizeOf(Value));
  end;
  FAudio:=TMediaFrames.CopyAudio(Bytes, AUDIO_SAMPLES_PER_FRAME, 48000, msfS16, TMediaChannelLayout.Mono, TMediaTime.FromMicroseconds(0));
  FWriterSettings:=TMediaWriterSettings.H264MP4(16, 16, TMediaRate.Create(30, 1));
  FWriterSettings.MuxerName:='matroska';
  FWriterSettings.Audio:=TMediaAudioEncoding.Opus(1);
  FWriterSettings.Overwrite:=True;
  FWriterSettings.TimeoutMilliseconds:=5000;
  FReaderSettings:=TMediaReaderSettings.Default;
  FReaderSettings.Channels:=1;
  FImageWriteSettings:=TMediaImageWriteSettings.Default(mifPNG);
  FImageWriteSettings.Overwrite:=True;
end;

destructor TMediaResources.Destroy;
begin
  FVideo:=nil;
  FAudio:=nil;
  FDirectory.Free;
  inherited Destroy;
end;

procedure TMediaResources.WriteMedia(const AFilename: String; AFrames: Integer);
var
  Writer: IMediaWriter;
  I: Integer;
begin
  Writer:=TMediaWriter.OpenFile(AFilename, FWriterSettings);
  try
    for I:=0 to AFrames - 1 do
    begin
      Writer.SubmitVideo(FVideo);
      Writer.SubmitAudio(FAudio);
    end;
    Writer.Finish;
  finally
    if Writer.State <> mwsFinished then
      Writer.Abort;
  end;
end;

procedure TMediaResources.ReadMedia(const AFilename: String; AFrames: Integer);
var
  Reader: IMediaReader;
  Sample: IMediaSample;
  Audio: IMediaAudioBuffer;
  Status: TMediaReadStatus;
  Videos, Samples: Int64;
begin
  Videos:=0;
  Samples:=0;
  Reader:=TMediaReader.OpenFile(AFilename, FReaderSettings);
  try
    repeat
      Status:=Reader.ReadSample(Sample);
      if Status = mrsSample then
        if Sample.Kind = mkVideo then
          Inc(Videos)
        else
        if Supports(Sample, IMediaAudioBuffer, Audio) then
          Inc(Samples, Audio.SampleCount);
    until Status <> mrsSample;
    Check(Status = mrsEndOfInput, 'Long reader reaches EOF');
  finally
    Reader.Close;
  end;
  Check(Videos = AFrames, 'Complete long H.264 drain');
  Check(Samples = Int64(AFrames) * AUDIO_SAMPLES_PER_FRAME, 'Complete long Opus sample count, including final trim');
end;

procedure TMediaResources.Cycle;
var
  Reader: IMediaReader;
  Sample, Retained: IMediaSample;
  Screenshot: TMediaScreenshot;
  Bytes: TBytes;
  I: Integer;
begin
  Reader:=TMediaReader.OpenFile(FDirectory.FileName('long.mkv'), FReaderSettings);
  try
    for I:=0 to 15 do
      Check(Reader.ReadSample(Sample) = mrsSample, 'Repeated reader yields samples');
    Retained:=Sample;
    Reader.Seek(TMediaTime.FromSeconds(10));
    Check(Reader.ReadSample(Sample) = mrsSample, 'Repeated seek yields samples');
  finally
    Reader.Close;
    Reader:=nil;
  end;
  Bytes:=Retained.CopyBytes;
  Check(Length(Bytes) > 0, 'Repeated close retains public storage');
  Screenshot:=TMediaImages.ScreenshotFile(FDirectory.FileName('long.mkv'), TMediaTime.FromSeconds(0.1));
  TMediaImages.SaveFile(Screenshot.Frame, FDirectory.FileName('shot.png'), FImageWriteSettings);
  WriteMedia(FDirectory.FileName('short.mkv'), 12);
  ReadMedia(FDirectory.FileName('short.mkv'), 12);
end;

procedure TMediaResources.Run;
var
  Baseline, Current, AfterLong: TMediaResourceSnapshot;
  I: Integer;
begin
  // Ten minutes of media exercises sustained bounded pumps and full final drain.
  WriteMedia(FDirectory.FileName('long.mkv'), LONG_VIDEO_FRAMES);
  ReadMedia(FDirectory.FileName('long.mkv'), LONG_VIDEO_FRAMES);
  AfterLong:=TMediaResourceSnapshot.Capture;
  AfterLong.Print('After 600-second media write/read');
  for I:=0 to 4 do
    Cycle;
  Baseline:=TMediaResourceSnapshot.Capture;
  Baseline.Print('After five warmup cycles');
  for I:=0 to 59 do
  begin
    Cycle;
    Current:=TMediaResourceSnapshot.Capture;
    Current.CheckGrowth(Baseline, 32 * 1024 * 1024, 4, 'Repeated reader/image/writer cycle ' + IntToStr(I));
    if I MOD 10 = 9 then
      Current.Print('Cycle ' + IntToStr(I + 1));
  end;
  WriteLn('PASS: 600-second AV media and 60 reader/seek/image/publication/writer cycles stay within measured growth allowances');
end;

var
  Resources: TMediaResources;
begin
  try
    Resources:=TMediaResources.Create;
    try
      Resources.Run;
    finally
      Resources.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
