program MediaSequenceSmoke;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Images,
  TFFmpeg.Media.Reader,
  TFFmpeg.Media.Writer,
  MediaTestSupport;

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

function Solid(ARed, AGreen, ABlue: Byte): IMediaVideoFrame;
var
  Bytes: TBytes;
  I: Integer;
begin
  Result:=nil;
  SetLength(Bytes, 16 * 12 * 4);
  for I:=0 to 16 * 12 - 1 do
  begin
    Bytes[I * 4]:=ABlue;
    Bytes[I * 4 + 1]:=AGreen;
    Bytes[I * 4 + 2]:=ARed;
    Bytes[I * 4 + 3]:=255;
  end;
  Result:=TMediaFrames.CopyVideo(Bytes, 16, 12, 64, mpfBGRA32, TMediaTime.Unknown);
end;

procedure TestSequence(const AFilename, AImageFile: String);
var
  Images: Array of TMediaSequenceImage;
  Settings: TMediaImageSequenceSettings;
  Output: TMediaImageSequenceResult;
  ReaderSettings: TMediaReaderSettings;
  Reader: IMediaReader;
  Sample: IMediaSample;
  Frame: IMediaVideoFrame;
  Bytes: TBytes;
  I, Count, Item, Center, Corner: Integer;
  ExpectedRed, ExpectedGreen, ExpectedBlue: Integer;
  Boundary: Int64;
begin
  TMediaImages.SaveFile(Solid(20, 180, 30), AImageFile, TMediaImageWriteSettings.Default(mifPNG));
  SetLength(Images, 101);
  for I:=0 to Length(Images) - 1 do
    if (I MOD 2) = 0 then
      Images[I]:=TMediaSequenceImage.FromFrame(Solid(180, 20, 30), TMediaTime.FromMicroseconds(37000))
    else
      Images[I]:=TMediaSequenceImage.FromFile(AImageFile, TMediaTime.FromMicroseconds(37000));
  Settings:=TMediaImageSequenceSettings.H264MP4(32, 32, TMediaRate.Create(30000, 1001));
  Settings.BackgroundRGB:=$102030;
  Settings.Fit:=mfFit;
  Output:=TMediaImageSequence.WriteFile(AFilename, Images, Settings);
  Check((Output.FrameCount = 111) AND (Output.RequestedDuration.Microseconds = 3737000), 'Cumulative rational boundaries avoid per-item rounding drift');
  Check((Output.EncodedDuration.Microseconds = 3703700) AND (Output.EncoderName = 'libx264'), 'Sequence reports exact rational duration and concrete encoder');
  ReaderSettings:=TMediaReaderSettings.Default;
  ReaderSettings.AudioStreamIndex:=-2;
  Reader:=TMediaReader.OpenFile(AFilename, ReaderSettings);
  Count:=0;
  Item:=0;
  while Reader.ReadSample(Sample) = mrsSample do
  begin
    Check(Count < 111, 'No extra repeated frame');
    Boundary:=Int64(Item + 1) * 37000 * 30000 DIV 1001000000;
    while Count >= Boundary do
    begin
      Inc(Item);
      Boundary:=Int64(Item + 1) * 37000 * 30000 DIV 1001000000;
    end;
    ExpectedRed:=180;
    ExpectedGreen:=20;
    ExpectedBlue:=30;
    if (Item MOD 2) <> 0 then
    begin
      ExpectedRed:=20;
      ExpectedGreen:=180;
    end;
    Frame:=Sample AS IMediaVideoFrame;
    Check((Frame.Width = 32) AND (Frame.Height = 32), 'Sequence target geometry');
    Check(Abs(Frame.Timestamp.Microseconds - Int64(Count) * 1001000000 DIV 30000) <= 1, 'Rational sequence PTS');
    Bytes:=Frame.CopyBytes;
    Center:=16 * Frame.Stride + 16 * 4;
    Corner:=0;
    Check((Abs(Integer(Bytes[Center + 2]) - ExpectedRed) <= 6) AND
      (Abs(Integer(Bytes[Center + 1]) - ExpectedGreen) <= 6) AND
      (Abs(Integer(Bytes[Center]) - ExpectedBlue) <= 6), 'Repeated image identity at frame ' + IntToStr(Count));
    Check((Abs(Integer(Bytes[Corner + 2]) - $10) <= 6) AND (Abs(Integer(Bytes[Corner + 1]) - $20) <= 6) AND
      (Abs(Integer(Bytes[Corner]) - $30) <= 6), 'Fit letterbox uses explicit background');
    Inc(Count);
  end;
  Check(Count = 111, 'Every quantized sequence frame decodes');
  Check(Abs(Reader.Info.Duration.Microseconds - Output.EncodedDuration.Microseconds) <= 1000, 'Independent container duration agrees with rational total');
  Reader.Close;
end;

procedure TestInvalid(const AFilename: String);
var
  Images: Array[0..0] of TMediaSequenceImage;
  Settings: TMediaImageSequenceSettings;
  Source: IMediaCancellationSource;
begin
  Settings:=TMediaImageSequenceSettings.H264MP4(32, 24, TMediaRate.Create(25, 1));
  Images[0]:=TMediaSequenceImage.FromFrame(Solid(10, 20, 30), TMediaTime.FromMicroseconds(0));
  try
    TMediaImageSequence.WriteFile(AFilename, Images, Settings);
    Check(False, 'Zero duration must fail');
  except
    on E: EFFmpegMediaError do
      Check(E.Category = mecInvalidSettings, 'Invalid duration category');
  end;
  Check(NOT FileExists(AFilename), 'Invalid duration does not publish');
  Images[0]:=TMediaSequenceImage.FromFrame(Solid(10, 20, 30), TMediaTime.FromSeconds(1));
  Source:=TMediaCancellation.CreateSource;
  Source.Cancel;
  try
    TMediaImageSequence.WriteFile(AFilename, Images, Settings, Source.Token);
    Check(False, 'Cancelled sequence must fail');
  except
    on E: EMediaCancelled do
      Check(NOT FileExists(AFilename), 'Cancelled sequence does not publish');
  end;
end;

var
  Directory: TMediaTestDirectory;
begin
  try
    Directory:=TMediaTestDirectory.Create;
    try
      TestSequence(Directory.FileName('sequence.mp4'), Directory.FileName('green.png'));
      TestInvalid(Directory.FileName('invalid.mp4'));
      WriteLn('PASS: image sequence rational rounding, decoded identities, fit/background, duration and failure guards');
    finally
      Directory.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
