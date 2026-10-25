program MediaScreenshotSmoke;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
  Classes,
{$ELSE}
  System.SysUtils,
  System.Classes,
{$ENDIF}
  TFFmpeg.Media,
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Reader,
  TFFmpeg.Media.Images,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Capabilities,
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

procedure CheckColor(const AFrame: IMediaVideoFrame; ARed, AGreen, ABlue: Byte; ATolerance: Integer = 0);
var
  Bytes: TBytes;
begin
  Bytes:=AFrame.CopyBytes;
  Check((Abs(Integer(Bytes[0]) - ABlue) <= ATolerance) AND (Abs(Integer(Bytes[1]) - AGreen) <= ATolerance) AND
    (Abs(Integer(Bytes[2]) - ARed) <= ATolerance) AND (Bytes[3] = 255), 'Screenshot frame identity');
end;

procedure TestFileScreenshots;
var
  Screenshot, Last: TMediaScreenshot;
  Settings: TMediaScreenshotSettings;
  ImageSettings: TMediaImageSettings;
  Frame: IMediaVideoFrame;
  Directory: TMediaTestDirectory;
  Reader: IMediaReader;
  ReaderSettings: TMediaReaderSettings;
  Failed: Boolean;
  Name: String;
  I: Integer;
  Bytes: TBytes;
  Stream: TFileStream;
begin
  Screenshot:=TMediaImages.ScreenshotFile(Fixture('video.mkv'), TMediaTime.FromSeconds(0.05));
  Check((Screenshot.RequestedTime.Microseconds = 50000) AND (Screenshot.ActualTime.Microseconds = 100000), 'Decode forward selects first frame at/after target');
  Check(NOT Screenshot.Approximate, 'Timestamped selection must be accurate');
  CheckColor(Screenshot.Frame, 0, 255, 0);
  Stream:=TFileStream.Create(Fixture('video.mkv'), fmOpenRead OR fmShareDenyWrite);
  try
    SetLength(Bytes, Stream.Size);
    Stream.ReadBuffer(Bytes[0], Length(Bytes));
  finally
    Stream.Free;
  end;
  Screenshot:=TMediaImages.ScreenshotBytes(Bytes, TMediaTime.FromSeconds(0.05), TMediaScreenshotSettings.Default);
  FillChar(Bytes[0], Length(Bytes), 0);
  Bytes:=nil;
  Check(Screenshot.ActualTime.Microseconds = 100000, 'Owned screenshot byte input');
  CheckColor(Screenshot.Frame, 0, 255, 0);
  Last:=TMediaImages.ScreenshotFile(Fixture('video.mkv'), TMediaTime.FromSeconds(0.2));
  Check(Last.ActualTime.Microseconds = 200000, 'Last displayed frame exact target');
  CheckColor(Last.Frame, 0, 0, 255);
  for I:=0 to 1 do
  begin
    Failed:=False;
    try
      TMediaImages.ScreenshotFile(Fixture('video.mkv'), TMediaTime.FromMicroseconds(299000 + I * 1000));
    except
      on E: EFFmpegMediaError do
        Failed:=E.Category = mecPositionUnavailable;
    end;
    Check(Failed, 'Near-EOF target with no later frame is position-unavailable');
  end;
  CheckColor(Screenshot.Frame, 0, 255, 0);

  ReaderSettings:=TMediaReaderSettings.Default;
  ReaderSettings.AudioStreamIndex:=-2;
  Reader:=TMediaReader.OpenFile(Fixture('video.mkv'), ReaderSettings);
  Screenshot:=TMediaImages.Screenshot(Reader, TMediaTime.FromSeconds(0.15), TMediaImageSettings.Default);
  Check(Screenshot.ActualTime.Microseconds = 200000, 'Borrowed reader selection');
  Screenshot:=TMediaImages.Screenshot(Reader, TMediaTime.FromSeconds(0), TMediaImageSettings.Default);
  CheckColor(Screenshot.Frame, 255, 0, 0);
  Reader.Close;
  CheckColor(Screenshot.Frame, 255, 0, 0);

  Screenshot:=TMediaImages.ScreenshotFile(Fixture('rotated.mp4'), TMediaTime.FromSeconds(0));
  Check((Screenshot.Frame.Width = 12) AND (Screenshot.Frame.Height = 32), 'Display screenshot applies SAR before rotation');
  Check((Screenshot.SourceStream.Width = 16) AND (Screenshot.SourceStream.Height = 12), 'Source coded geometry remains unchanged in metadata');
  CheckColor(Screenshot.Frame, 255, 0, 0, 3);
  Settings:=TMediaScreenshotSettings.Default;
  ImageSettings:=Settings.Image;
  ImageSettings.Geometry:=migCoded;
  Settings.Image:=ImageSettings;
  Last:=TMediaImages.ScreenshotFile(Fixture('rotated.mp4'), TMediaTime.FromSeconds(0), Settings);
  Check((Last.Frame.Width = 16) AND (Last.Frame.Height = 12), 'Explicit coded screenshot geometry');

  Directory:=TMediaTestDirectory.Create;
  try
    Name:=Directory.FileName('display.bmp');
    Last:=TFFmpegMedia.SaveScreenshot(Fixture('rotated.mp4'), TMediaTime.FromSeconds(0), Name);
    Frame:=TMediaImages.LoadFile(Name);
    Check((Frame.Width = 12) AND (Frame.Height = 32), 'Saved screenshot does not apply orientation twice');
    CheckColor(Frame, 255, 0, 0, 3);
    if TMediaCapabilities.HasEncoder('png') then
    begin
      Name:=Directory.FileName('exact-' + #$00E4 + #$4E2D + '.png');
      Last:=TFFmpegMedia.SaveScreenshot(Fixture('video.mkv'), TMediaTime.FromSeconds(0.05), Name);
      Frame:=TMediaImages.LoadFile(Name);
      CheckColor(Frame, 0, 255, 0);
    end;
  finally
    Directory.Free;
  end;
  WriteLn('PASS: decode-forward timestamps/identity, near EOF, retained screenshots, display/coded geometry and public save facade');
end;

type
  TUnknownTimestampReader = class(TInterfacedObject, IMediaReader)
  private
    FFrame: IMediaVideoFrame;
    FRead: Boolean;
    FSeekable: Boolean;
    FStatus: TMediaReadStatus;
  public
    constructor Create(ASeekable: Boolean; AStatus: TMediaReadStatus);
    function GetInfo: TMediaInfo;
    function GetPresentationOrigin: TMediaTime;
    function ReadSample(out ASample: IMediaSample): TMediaReadStatus;
    procedure Seek(const APosition: TMediaTime);
    procedure Close;
  end;

constructor TUnknownTimestampReader.Create(ASeekable: Boolean; AStatus: TMediaReadStatus);
var
  Bytes: TBytes;
begin
  inherited Create;
  SetLength(Bytes, 4);
  Bytes[1]:=255;
  Bytes[3]:=255;
  FFrame:=TMediaFrames.CopyVideo(Bytes, 1, 1, 4, mpfBGRA32, TMediaTime.Unknown, 0);
  FSeekable:=ASeekable;
  FStatus:=AStatus;
end;

function TUnknownTimestampReader.GetInfo: TMediaInfo;
var
  Streams: TMediaStreams;
begin
  Result:=Default(TMediaInfo);
  Result.Seekable:=FSeekable;
  SetLength(Streams, 1);
  Streams[0].Index:=0;
  Streams[0].Kind:=mkVideo;
  Result.Streams:=Streams;
end;

function TUnknownTimestampReader.GetPresentationOrigin: TMediaTime;
begin
  Result:=TMediaTime.FromMicroseconds(0);
end;

function TUnknownTimestampReader.ReadSample(out ASample: IMediaSample): TMediaReadStatus;
begin
  Result:=FStatus;
  ASample:=nil;
  if Result <> mrsSample then
    Exit;
  if FRead then
    Exit(mrsEndOfInput);
  ASample:=FFrame;
  FRead:=True;
end;

procedure TUnknownTimestampReader.Seek(const APosition: TMediaTime);
begin
  if NOT FSeekable then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Mock seek', 'Input is not seekable');
  FRead:=False;
end;

procedure TUnknownTimestampReader.Close;
begin
  FFrame:=nil;
end;

procedure TestUnknownAndInterrupted;
var
  Reader: IMediaReader;
  Screenshot: TMediaScreenshot;
  Failed: Boolean;
  I: Integer;
begin
  Reader:=TUnknownTimestampReader.Create(True, mrsSample);
  Failed:=False;
  try
    TMediaImages.Screenshot(Reader, TMediaTime.FromSeconds(0), TMediaImageSettings.Default);
  except
    on E: EFFmpegMediaError do
      Failed:=(E.Category = mecUnsupported) AND (Pos('timestamps', E.Message) > 0);
  end;
  Check(Failed, 'Unknown displayed timestamp must fail accurate extraction');
  Screenshot:=TMediaImages.Screenshot(Reader, TMediaTime.FromSeconds(0), TMediaImageSettings.Default, mspAllowUnknownTimestamp);
  Check(Screenshot.Approximate AND NOT Screenshot.ActualTime.Valid, 'Approximate policy never fabricates actual time');
  CheckColor(Screenshot.Frame, 0, 255, 0);
  Reader:=TUnknownTimestampReader.Create(False, mrsSample);
  Failed:=False;
  try
    TMediaImages.Screenshot(Reader, TMediaTime.FromSeconds(0), TMediaImageSettings.Default);
  except
    on E: EFFmpegMediaError do
      Failed:=E.Category = mecUnsupported;
  end;
  Check(Failed, 'Screenshot propagates non-seekable failure');
  for I:=0 to 1 do
  begin
    if I = 0 then
      Reader:=TUnknownTimestampReader.Create(True, mrsCancelled)
    else
      Reader:=TUnknownTimestampReader.Create(True, mrsTimedOut);
    Failed:=False;
    try
      TMediaImages.Screenshot(Reader, TMediaTime.FromSeconds(0), TMediaImageSettings.Default);
    except
      on E: EMediaCancelled do
        Failed:=I = 0;
      on E: EMediaTimedOut do
        Failed:=I = 1;
    end;
    Check(Failed, 'Screenshot must distinguish cancellation and timeout from EOF');
  end;
  WriteLn('PASS: missing timestamp policy, non-seekable propagation and dedicated screenshot interruption errors');
end;

begin
  try
    TestFileScreenshots;
    TestUnknownAndInterrupted;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
