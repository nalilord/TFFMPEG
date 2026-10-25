unit TFFmpeg.Media.Images;

interface

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Reader;

type
  TMediaImageFormat = (mifAutomatic, mifBMP, mifPNG, mifJPEG);
  TMediaAlphaMode = (mamComposite, mamPreserve);
  TMediaImageGeometry = (migDisplay, migCoded);
  TMediaScreenshotPolicy = (mspAccurate, mspAllowUnknownTimestamp);

  TMediaImageSettings = record
  private
    FWidth: Integer;
    FHeight: Integer;
    FFit: TMediaFit;
    FBackgroundRGB: Cardinal;
    FAlphaMode: TMediaAlphaMode;
    FGeometry: TMediaImageGeometry;
    FTimeoutMilliseconds: Cardinal;
  public
    class function Default: TMediaImageSettings; static;
    procedure Validate;
    property Width: Integer read FWidth write FWidth;
    property Height: Integer read FHeight write FHeight;
    property Fit: TMediaFit read FFit write FFit;
    property BackgroundRGB: Cardinal read FBackgroundRGB write FBackgroundRGB;
    property AlphaMode: TMediaAlphaMode read FAlphaMode write FAlphaMode;
    property Geometry: TMediaImageGeometry read FGeometry write FGeometry;
    property TimeoutMilliseconds: Cardinal read FTimeoutMilliseconds write FTimeoutMilliseconds;
  end;

  TMediaImageWriteSettings = record
  private
    FFormat: TMediaImageFormat;
    FQuality: Integer;
    FBackgroundRGB: Cardinal;
    FOverwrite: Boolean;
    FTimeoutMilliseconds: Cardinal;
  public
    class function Default(AFormat: TMediaImageFormat = mifAutomatic): TMediaImageWriteSettings; static;
    procedure Validate;
    property ImageFormat: TMediaImageFormat read FFormat write FFormat;
    property Quality: Integer read FQuality write FQuality;
    property BackgroundRGB: Cardinal read FBackgroundRGB write FBackgroundRGB;
    property Overwrite: Boolean read FOverwrite write FOverwrite;
    property TimeoutMilliseconds: Cardinal read FTimeoutMilliseconds write FTimeoutMilliseconds;
  end;

  TMediaScreenshotSettings = record
  private
    FReader: TMediaReaderSettings;
    FImage: TMediaImageSettings;
    FPolicy: TMediaScreenshotPolicy;
  public
    class function Default: TMediaScreenshotSettings; static;
    procedure Validate;
    property Reader: TMediaReaderSettings read FReader write FReader;
    property Image: TMediaImageSettings read FImage write FImage;
    property Policy: TMediaScreenshotPolicy read FPolicy write FPolicy;
  end;

  TMediaScreenshot = record
  private
    FRequestedTime: TMediaTime;
    FActualTime: TMediaTime;
    FFrame: IMediaVideoFrame;
    FApproximate: Boolean;
    FSourceStream: TMediaStreamInfo;
  public
    property RequestedTime: TMediaTime read FRequestedTime;
    property ActualTime: TMediaTime read FActualTime;
    property Frame: IMediaVideoFrame read FFrame;
    property Approximate: Boolean read FApproximate;
    property SourceStream: TMediaStreamInfo read FSourceStream;
  end;

  TMediaImages = class sealed
  public
    class function LoadFile(const AFilename: String): IMediaVideoFrame; overload; static;
    class function LoadFile(const AFilename: String; const ASettings: TMediaImageSettings;
      const AToken: IMediaCancellationToken = nil): IMediaVideoFrame; overload; static;
    class function Render(const AFrame: IMediaVideoFrame; const ASettings: TMediaImageSettings;
      const AToken: IMediaCancellationToken = nil): IMediaVideoFrame; overload; static;
    class function Render(const AFrame: IMediaVideoFrame; const AStream: TMediaStreamInfo; const ASettings: TMediaImageSettings;
      const AToken: IMediaCancellationToken = nil): IMediaVideoFrame; overload; static;
    class function Encode(const AFrame: IMediaVideoFrame; const ASettings: TMediaImageWriteSettings;
      const AToken: IMediaCancellationToken = nil): TBytes; static;
    class procedure SaveFile(const AFrame: IMediaVideoFrame; const AFilename: String; const ASettings: TMediaImageWriteSettings;
      const AToken: IMediaCancellationToken = nil); static;
    class function Screenshot(const AReader: IMediaReader; const APosition: TMediaTime; const ASettings: TMediaImageSettings;
      APolicy: TMediaScreenshotPolicy = mspAccurate; const AToken: IMediaCancellationToken = nil): TMediaScreenshot; static;
    class function ScreenshotFile(const AFilename: String; const APosition: TMediaTime): TMediaScreenshot; overload; static;
    class function ScreenshotFile(const AFilename: String; const APosition: TMediaTime; const ASettings: TMediaScreenshotSettings;
      const AToken: IMediaCancellationToken = nil): TMediaScreenshot; overload; static;
    class function ScreenshotBytes(const ABytes: TBytes; const APosition: TMediaTime; const ASettings: TMediaScreenshotSettings;
      const AToken: IMediaCancellationToken = nil): TMediaScreenshot; static;
  end;

implementation

uses
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Internal.Native,
  TFFmpeg.Media.Internal.Images;

class function TMediaImageSettings.Default: TMediaImageSettings;
begin
  Result:=System.Default(TMediaImageSettings);
end;

procedure TMediaImageSettings.Validate;
begin
  if (FWidth < 0) OR (FHeight < 0) OR (FWidth > MEDIA_MAX_PIXELS) OR (FHeight > MEDIA_MAX_PIXELS) OR
    (Int64(FWidth) * FHeight > MEDIA_MAX_PIXELS) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Image settings', 'Invalid dimensions or 64-million-pixel limit exceeded');
  if NOT (FFit IN [mfFit, mfFill, mfStretch]) OR NOT (FAlphaMode IN [mamComposite, mamPreserve]) OR
    NOT (FGeometry IN [migDisplay, migCoded]) OR (FBackgroundRGB > $FFFFFF) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Image settings', 'Invalid fit, geometry, alpha policy or RGB background');
end;

class function TMediaImageWriteSettings.Default(AFormat: TMediaImageFormat): TMediaImageWriteSettings;
begin
  Result:=System.Default(TMediaImageWriteSettings);
  Result.FFormat:=AFormat;
  Result.FQuality:=90;
end;

procedure TMediaImageWriteSettings.Validate;
begin
  if NOT (FFormat IN [mifAutomatic, mifBMP, mifPNG, mifJPEG]) OR (FQuality < 1) OR (FQuality > 100) OR (FBackgroundRGB > $FFFFFF) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Image write settings', 'Use Default settings with a known format, 1-100 quality and RGB background');
end;

class function TMediaScreenshotSettings.Default: TMediaScreenshotSettings;
begin
  Result:=System.Default(TMediaScreenshotSettings);
  Result.FReader:=TMediaReaderSettings.Default;
  Result.FReader.AudioStreamIndex:=-2;
  Result.FImage:=TMediaImageSettings.Default;
end;

procedure TMediaScreenshotSettings.Validate;
begin
  FReader.Validate;
  FImage.Validate;
  if (FReader.VideoStreamIndex = -2) OR NOT (FPolicy IN [mspAccurate, mspAllowUnknownTimestamp]) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Screenshot settings', 'Select a video stream and a supported screenshot policy');
end;

class function TMediaImages.LoadFile(const AFilename: String): IMediaVideoFrame;
begin
  Result:=LoadFile(AFilename, TMediaImageSettings.Default);
end;

class function TMediaImages.LoadFile(const AFilename: String; const ASettings: TMediaImageSettings;
  const AToken: IMediaCancellationToken): IMediaVideoFrame;
begin
  Result:=LoadImageFile(AFilename, ASettings, AToken);
end;

class function TMediaImages.Render(const AFrame: IMediaVideoFrame; const ASettings: TMediaImageSettings;
  const AToken: IMediaCancellationToken): IMediaVideoFrame;
begin
  Result:=Render(AFrame, System.Default(TMediaStreamInfo), ASettings, AToken);
end;

class function TMediaImages.Render(const AFrame: IMediaVideoFrame; const AStream: TMediaStreamInfo;
  const ASettings: TMediaImageSettings; const AToken: IMediaCancellationToken): IMediaVideoFrame;
begin
  Result:=RenderImage(AFrame, AStream, ASettings, AToken);
end;

class function TMediaImages.Encode(const AFrame: IMediaVideoFrame; const ASettings: TMediaImageWriteSettings;
  const AToken: IMediaCancellationToken): TBytes;
begin
  Result:=EncodeImage(AFrame, ASettings, AToken);
end;

class procedure TMediaImages.SaveFile(const AFrame: IMediaVideoFrame; const AFilename: String;
  const ASettings: TMediaImageWriteSettings; const AToken: IMediaCancellationToken);
begin
  SaveImageFile(AFrame, AFilename, ASettings, AToken);
end;

function ExtractScreenshot(const AReader: IMediaReader; const APosition: TMediaTime; const ASettings: TMediaImageSettings;
  APolicy: TMediaScreenshotPolicy; const AToken: IMediaCancellationToken; AFreshReader: Boolean): TMediaScreenshot;
var
  Operation: TMediaOperation;
  Sample: IMediaSample;
  Frame: IMediaVideoFrame;
  Streams: TMediaStreams;
  Stream: TMediaStreamInfo;
  I: Integer;
  Status: TMediaReadStatus;
begin
  Result:=System.Default(TMediaScreenshot);
  ASettings.Validate;
  if NOT Assigned(AReader) OR NOT APosition.Valid OR (APosition.Microseconds < 0) OR
    NOT (APolicy IN [mspAccurate, mspAllowUnknownTimestamp]) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Screenshot', 'A reader, nonnegative known position and supported policy are required');
  Operation:=TMediaOperation.Create(AToken, ASettings.TimeoutMilliseconds);
  try
    Operation.Check('Screenshot');
    if NOT AFreshReader OR (APosition.Microseconds <> 0) then
      AReader.Seek(APosition);
    while True do
    begin
      Operation.Check('Screenshot');
      Status:=AReader.ReadSample(Sample);
      case Status of
        mrsEndOfInput: raise EFFmpegMediaError.Create(mecPositionUnavailable, 'Screenshot', 'No displayed frame at or after the requested position');
        mrsCancelled: raise EMediaCancelled.Create('Screenshot');
        mrsTimedOut: raise EMediaTimedOut.Create('Screenshot');
      end;
      if NOT Assigned(Sample) then
        raise EFFmpegMediaError.Create(mecInvalidState, 'Screenshot', 'Reader returned an empty sample');
      if NOT Supports(Sample, IMediaVideoFrame, Frame) then
        Continue;
      if NOT Frame.Timestamp.Valid then
      begin
        if APolicy = mspAccurate then
          raise EFFmpegMediaError.Create(mecUnsupported, 'Screenshot', 'Accurate extraction requires displayed-frame timestamps');
        Result.FApproximate:=True;
      end else
      if Frame.Timestamp.Compare(APosition) < 0 then
        Continue;

      Stream:=System.Default(TMediaStreamInfo);
      Streams:=AReader.Info.Streams;
      for I:=0 to Length(Streams) - 1 do
        if Streams[I].Index = Frame.StreamIndex then
          Stream:=Streams[I];
      Result.FRequestedTime:=APosition;
      Result.FActualTime:=Frame.Timestamp;
      Result.FSourceStream:=Stream;
      Result.FFrame:=RenderImageControlled(Frame, Stream, ASettings, Operation);
      Operation.Check('Screenshot');
      Exit;
    end;
  finally
    Operation.Free;
  end;
end;

class function TMediaImages.Screenshot(const AReader: IMediaReader; const APosition: TMediaTime;
  const ASettings: TMediaImageSettings; APolicy: TMediaScreenshotPolicy; const AToken: IMediaCancellationToken): TMediaScreenshot;
begin
  Result:=ExtractScreenshot(AReader, APosition, ASettings, APolicy, AToken, False);
end;

class function TMediaImages.ScreenshotFile(const AFilename: String; const APosition: TMediaTime): TMediaScreenshot;
begin
  Result:=ScreenshotFile(AFilename, APosition, TMediaScreenshotSettings.Default);
end;

class function TMediaImages.ScreenshotFile(const AFilename: String; const APosition: TMediaTime;
  const ASettings: TMediaScreenshotSettings; const AToken: IMediaCancellationToken): TMediaScreenshot;
var
  Reader: IMediaReader;
begin
  Result:=System.Default(TMediaScreenshot);
  ASettings.Validate;
  Reader:=TMediaReader.OpenFile(AFilename, ASettings.Reader, AToken);
  try
    Result:=ExtractScreenshot(Reader, APosition, ASettings.Image, ASettings.Policy, AToken, True);
  finally
    Reader.Close;
  end;
end;

class function TMediaImages.ScreenshotBytes(const ABytes: TBytes; const APosition: TMediaTime;
  const ASettings: TMediaScreenshotSettings; const AToken: IMediaCancellationToken): TMediaScreenshot;
var
  Reader: IMediaReader;
begin
  Result:=System.Default(TMediaScreenshot);
  ASettings.Validate;
  Reader:=TMediaReader.OpenBytes(ABytes, ASettings.Reader, AToken);
  try
    Result:=ExtractScreenshot(Reader, APosition, ASettings.Image, ASettings.Policy, AToken, True);
  finally
    Reader.Close;
  end;
end;

end.
