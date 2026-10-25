program MediaImageSmoke;

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
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Images,
  TFFmpeg.Media.Capabilities,
  MediaTestSupport;

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

type
  TImageFaultToken = class(TInterfacedObject, IMediaCancellationToken)
  private
    FDirectory: String;
    FCancel: Boolean;
    FTriggered: Boolean;
  public
    constructor Create(const ADirectory: String; ACancel: Boolean);
    function IsCancellationRequested: Boolean;
    procedure ThrowIfCancellationRequested(const AOperation: String);
  end;

constructor TImageFaultToken.Create(const ADirectory: String; ACancel: Boolean);
begin
  inherited Create;
  FDirectory:=ADirectory;
  FCancel:=ACancel;
end;

function TImageFaultToken.IsCancellationRequested: Boolean;
var
  Search: TSearchRec;
  Name: String;
begin
  Result:=FTriggered AND FCancel;
  if FTriggered then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(FDirectory) + '*.tffmpeg-*.tmp', faAnyFile, Search) = 0 then
  begin
    Name:=IncludeTrailingPathDelimiter(FDirectory) + Search.Name;
    FindClose(Search);
    FTriggered:=True;
    if FCancel then
      Result:=True
    else
      Check(DeleteFile(Name), 'Could not inject an output IO failure');
  end;
end;

procedure TImageFaultToken.ThrowIfCancellationRequested(const AOperation: String);
begin
  if IsCancellationRequested then
    raise EMediaCancelled.Create(AOperation);
end;

function Fixture(const AName: String): String;
begin
  Result:=ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + 'fixtures' + PathDelim + AName);
end;

function ReadBytes(const AFilename: String): TBytes;
var
  Stream: TFileStream;
begin
  Result:=nil;
  Stream:=TFileStream.Create(AFilename, fmOpenRead OR fmShareDenyWrite);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then
      Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

procedure CheckPixel(const AFrame: IMediaVideoFrame; AX, AY, ARed, AGreen, ABlue, AAlpha: Integer; ATolerance: Integer = 0);
var
  Bytes: TBytes;
  Offset: Integer;
begin
  Check(AFrame.PixelFormat = mpfBGRA32, 'Expected BGRA image');
  Bytes:=AFrame.CopyBytes;
  Offset:=AY * AFrame.Stride + AX * 4;
  Check((Abs(Integer(Bytes[Offset]) - ABlue) <= ATolerance) AND (Abs(Integer(Bytes[Offset + 1]) - AGreen) <= ATolerance) AND
    (Abs(Integer(Bytes[Offset + 2]) - ARed) <= ATolerance) AND (Abs(Integer(Bytes[Offset + 3]) - AAlpha) <= ATolerance),
    Format('Pixel (%d,%d) actual RGBA %d,%d,%d,%d expected %d,%d,%d,%d',
    [AX, AY, Bytes[Offset + 2], Bytes[Offset + 1], Bytes[Offset], Bytes[Offset + 3], ARed, AGreen, ABlue, AAlpha]));
end;

procedure TestRender;
var
  Frame, Rendered: IMediaVideoFrame;
  Settings: TMediaImageSettings;
  Stream: TMediaStreamInfo;
  Matrix: Array[0..8] of Double;
  Bytes: TBytes;
  I: Integer;
  Failed: Boolean;
begin
  Frame:=TMediaImages.LoadFile(Fixture('colors.bmp'));
  Check((Frame.Width = 3) AND (Frame.Height = 2), 'BMP dimensions');
  CheckPixel(Frame, 0, 0, 255, 0, 0, 255);
  CheckPixel(Frame, 2, 1, 255, 255, 0, 255);
  Settings:=TMediaImageSettings.Default;
  Settings.Width:=6;
  Settings.Height:=6;
  Settings.BackgroundRGB:=$123456;
  Rendered:=TMediaImages.Render(Frame, Settings);
  Check((Rendered.Width = 6) AND (Rendered.Height = 6), 'Fit dimensions');
  CheckPixel(Rendered, 2, 0, $12, $34, $56, 255);
  CheckPixel(Rendered, 2, 5, $12, $34, $56, 255);
  Settings.Fit:=mfFill;
  Rendered:=TMediaImages.Render(Frame, Settings);
  CheckPixel(Rendered, 3, 0, 0, 255, 0, 255);
  Settings.Fit:=mfStretch;
  Rendered:=TMediaImages.Render(Frame, Settings);
  CheckPixel(Rendered, 0, 0, 255, 0, 0, 255);

  Settings:=TMediaImageSettings.Default;
  Stream:=Default(TMediaStreamInfo);
  for I:=0 to 8 do
    Matrix[I]:=0;
  Matrix[1]:=-1;
  Matrix[3]:=1;
  Matrix[8]:=1;
  Stream.DisplayTransform:=TMediaDisplayTransform.Create(Matrix);
  Rendered:=TMediaImages.Render(Frame, Stream, Settings);
  Check((Rendered.Width = 2) AND (Rendered.Height = 3), 'Quarter-turn dimensions');
  CheckPixel(Rendered, 0, 0, 0, 0, 255, 255);
  CheckPixel(Rendered, 1, 2, 255, 255, 255, 255);
  Matrix[0]:=-1;
  Matrix[1]:=0;
  Matrix[3]:=0;
  Matrix[4]:=1;
  Stream.DisplayTransform:=TMediaDisplayTransform.Create(Matrix);
  Rendered:=TMediaImages.Render(Frame, Stream, Settings);
  CheckPixel(Rendered, 0, 0, 0, 0, 255, 255);
  CheckPixel(Rendered, 2, 1, 255, 255, 255, 255);
  Stream.DisplayTransform:=Default(TMediaDisplayTransform);
  Stream.PixelAspect:=TMediaRate.Create(2, 1);
  Rendered:=TMediaImages.Render(Frame, Stream, Settings);
  Check((Rendered.Width = 6) AND (Rendered.Height = 2), 'Pixel-aspect display correction');
  Settings.Geometry:=migCoded;
  Rendered:=TMediaImages.Render(Frame, Stream, Settings);
  Check((Rendered.Width = 3) AND (Rendered.Height = 2), 'Coded geometry bypasses display policy');

  SetLength(Bytes, 4);
  Bytes[2]:=255;
  Bytes[3]:=128;
  Frame:=TMediaFrames.CopyVideo(Bytes, 1, 1, 4, mpfBGRA32, TMediaTime.Unknown);
  Settings:=TMediaImageSettings.Default;
  Settings.BackgroundRGB:=$0000FF;
  Rendered:=TMediaImages.Render(Frame, Settings);
  CheckPixel(Rendered, 0, 0, 128, 0, 127, 255);
  Settings.AlphaMode:=mamPreserve;
  Rendered:=TMediaImages.Render(Frame, Settings);
  CheckPixel(Rendered, 0, 0, 255, 0, 0, 128);
  Settings.Width:=High(Integer);
  Failed:=False;
  try
    TMediaImages.Render(Frame, Settings);
  except
    on E: EFFmpegMediaError do
      Failed:=E.Category = mecInvalidSettings;
  end;
  Check(Failed, 'Image allocation settings must fail before allocation');
  WriteLn('PASS: fit/fill/stretch, background, straight alpha, quarter-turn/mirror and pixel-aspect geometry');
end;

procedure TestImagesAndFiles;
var
  Directory: TMediaTestDirectory;
  Source, Loaded: IMediaVideoFrame;
  WriteSettings: TMediaImageWriteSettings;
  Settings: TMediaImageSettings;
  FormatValue: TMediaImageFormat;
  Bytes, Sentinel: TBytes;
  Stream: TFileStream;
  Name, Extension: String;
  I: Integer;
  Failed: Boolean;
  Cancellation: IMediaCancellationSource;
  FaultToken: IMediaCancellationToken;
  Search: TSearchRec;
begin
  Directory:=TMediaTestDirectory.Create;
  try
    Source:=TMediaImages.LoadFile(Fixture('colors.bmp'));
    for FormatValue:=mifBMP to mifJPEG do
    begin
      case FormatValue of
        mifBMP: Extension:='.bmp';
        mifPNG: Extension:='.png';
        mifJPEG: Extension:='.jpg';
      end;
      Name:=Directory.FileName('roundtrip' + Extension);
      WriteSettings:=TMediaImageWriteSettings.Default(FormatValue);
      if (FormatValue = mifPNG) AND NOT TMediaCapabilities.HasEncoder('png') then
      begin
        Failed:=False;
        try
          TMediaImages.SaveFile(Source, Name, WriteSettings);
        except
          on E: EFFmpegMediaError do
            Failed:=E.Category = mecUnsupported;
        end;
        Check(Failed AND NOT FileExists(Name), 'Missing PNG encoder must report unsupported and clean output');
        raise Exception.Create('Required PNG encoder unavailable; use an FFmpeg runtime built with zlib');
      end;
      TMediaImages.SaveFile(Source, Name, WriteSettings);
      Loaded:=TMediaImages.LoadFile(Name);
      Check((Loaded.Width = 3) AND (Loaded.Height = 2), 'Image roundtrip dimensions');
      Bytes:=ReadBytes(Name);
      if FormatValue = mifBMP then
      begin
        Check((Bytes[0] = Ord('B')) AND (Bytes[1] = Ord('M')) AND (PInteger(@Bytes[18])^ = 3) AND
          (PInteger(@Bytes[22])^ = 2) AND (PWord(@Bytes[28])^ = 24), 'Independent BMP header');
        CheckPixel(Loaded, 0, 0, 255, 0, 0, 255);
        CheckPixel(Loaded, 2, 1, 255, 255, 0, 255);
      end else
      if FormatValue = mifPNG then
      begin
        Check((Bytes[0] = 137) AND (Bytes[1] = 80) AND (Bytes[19] = 3) AND (Bytes[23] = 2), 'Independent PNG signature/IHDR');
        CheckPixel(Loaded, 0, 0, 255, 0, 0, 255);
      end else
        Check((Bytes[0] = $FF) AND (Bytes[1] = $D8) AND (Bytes[Length(Bytes) - 2] = $FF) AND
          (Bytes[Length(Bytes) - 1] = $D9), 'JPEG start/end markers');
    end;

    Name:=Directory.FileName('existing.bmp');
    SetLength(Sentinel, 3);
    Sentinel[0]:=7;
    Sentinel[1]:=8;
    Sentinel[2]:=9;
    Stream:=TFileStream.Create(Name, fmCreate);
    try
      Stream.WriteBuffer(Sentinel[0], Length(Sentinel));
    finally
      Stream.Free;
    end;
    WriteSettings:=TMediaImageWriteSettings.Default;
    Failed:=False;
    try
      TMediaImages.SaveFile(Source, Name, WriteSettings);
    except
      on E: EFFmpegMediaError do
        Failed:=E.Category = mecInputOutput;
    end;
    Bytes:=ReadBytes(Name);
    Check(Failed AND (Length(Bytes) = 3) AND CompareMem(@Bytes[0], @Sentinel[0], 3), 'Overwrite disabled preserves existing bytes');
    WriteSettings.Overwrite:=True;
    Cancellation:=TMediaCancellation.CreateSource;
    Cancellation.Cancel;
    Failed:=False;
    try
      TMediaImages.SaveFile(Source, Name, WriteSettings, Cancellation.Token);
    except
      on E: EMediaCancelled do
        Failed:=True;
    end;
    Bytes:=ReadBytes(Name);
    Check(Failed AND CompareMem(@Bytes[0], @Sentinel[0], 3), 'Cancelled image save preserves destination');
    Failed:=False;
    try
      TMediaImages.SaveFile(nil, Name, WriteSettings);
    except
      on E: EFFmpegMediaError do
        Failed:=E.Category = mecInvalidSettings;
    end;
    Bytes:=ReadBytes(Name);
    Check(Failed AND CompareMem(@Bytes[0], @Sentinel[0], 3), 'Failed encode preserves existing destination');
    for I:=0 to 1 do
    begin
      FaultToken:=TImageFaultToken.Create(Directory.Path, I = 0);
      Failed:=False;
      try
        TMediaImages.SaveFile(Source, Name, WriteSettings, FaultToken);
      except
        on E: EMediaCancelled do
          Failed:=I = 0;
        on E: EFFmpegMediaError do
          Failed:=(I = 1) AND (E.Category = mecInputOutput);
      end;
      Bytes:=ReadBytes(Name);
      Check(Failed AND (Length(Bytes) = 3) AND CompareMem(@Bytes[0], @Sentinel[0], 3), 'Cancel/IO failure after reservation preserves destination');
      if FindFirst(IncludeTrailingPathDelimiter(Directory.Path) + '*.tffmpeg-*.tmp', faAnyFile, Search) = 0 then
      begin
        FindClose(Search);
        raise Exception.Create('Image failure left a sibling temporary file');
      end;
    end;
    TMediaImages.SaveFile(Source, Name, WriteSettings);
    Loaded:=TMediaImages.LoadFile(Name);
    CheckPixel(Loaded, 0, 0, 255, 0, 0, 255);

    if TMediaCapabilities.HasEncoder('png') then
    begin
      SetLength(Bytes, 4);
      Bytes[0]:=0;
      Bytes[1]:=0;
      Bytes[2]:=255;
      Bytes[3]:=128;
      Source:=TMediaFrames.CopyVideo(Bytes, 1, 1, 4, mpfBGRA32, TMediaTime.Unknown);
      Name:=Directory.FileName('alpha.png');
      TMediaImages.SaveFile(Source, Name, TMediaImageWriteSettings.Default(mifPNG));
      Settings:=TMediaImageSettings.Default;
      Settings.AlphaMode:=mamPreserve;
      Loaded:=TMediaImages.LoadFile(Name, Settings);
      CheckPixel(Loaded, 0, 0, 255, 0, 0, 128);
    end;
    SetLength(Bytes, 16 * 16 * 4);
    for I:=0 to 16 * 16 - 1 do
    begin
      Bytes[I * 4]:=0;
      Bytes[I * 4 + 1]:=0;
      Bytes[I * 4 + 2]:=255;
      Bytes[I * 4 + 3]:=128;
    end;
    Source:=TMediaFrames.CopyVideo(Bytes, 16, 16, 64, mpfBGRA32, TMediaTime.Unknown);
    WriteSettings:=TMediaImageWriteSettings.Default(mifJPEG);
    WriteSettings.BackgroundRGB:=$0000FF;
    Name:=Directory.FileName('jpeg-matte.jpg');
    TMediaImages.SaveFile(Source, Name, WriteSettings);
    Loaded:=TMediaImages.LoadFile(Name);
    CheckPixel(Loaded, 8, 8, 128, 0, 127, 255, 3);
    for I:=0 to 9 do
    begin
      Loaded:=TMediaImages.LoadFile(Fixture('colors.bmp'));
      Bytes:=TMediaImages.Encode(Loaded, TMediaImageWriteSettings.Default(mifBMP));
      Check(Length(Bytes) > 54, 'Repeated image close/reopen/encode');
    end;
  finally
    Directory.Free;
  end;
  WriteLn('PASS: supported image codecs, binary headers, alpha retention, repeated cycles and destination preservation');
end;

begin
  try
    TestRender;
    TestImagesAndFiles;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
