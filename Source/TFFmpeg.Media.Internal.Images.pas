unit TFFmpeg.Media.Internal.Images;

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
  TFFmpeg.Media.Images,
  TFFmpeg.Media.Internal.Native;

function LoadImageFile(const AFilename: String; const ASettings: TMediaImageSettings; const AToken: IMediaCancellationToken): IMediaVideoFrame;
function RenderImage(const AFrame: IMediaVideoFrame; const AStream: TMediaStreamInfo; const ASettings: TMediaImageSettings;
  const AToken: IMediaCancellationToken): IMediaVideoFrame;
function RenderImageControlled(const AFrame: IMediaVideoFrame; const AStream: TMediaStreamInfo;
  const ASettings: TMediaImageSettings; AOperation: TMediaOperation): IMediaVideoFrame;
function EncodeImage(const AFrame: IMediaVideoFrame; const ASettings: TMediaImageWriteSettings;
  const AToken: IMediaCancellationToken): TBytes;
procedure SaveImageFile(const AFrame: IMediaVideoFrame; const AFilename: String; const ASettings: TMediaImageWriteSettings;
  const AToken: IMediaCancellationToken);

implementation

uses
{$IFDEF FPC}
  Classes,
  Math,
{$ELSE}
  System.Classes,
  System.Math,
{$ENDIF}
  libavcodec,
  libavcodec_codec_id,
  libavcodec_packet,
  libavutil,
  libavutil_error,
  libavutil_frame,
  libavutil_imgutils,
  libavutil_pixfmt,
  libavutil_rational,
  TFFmpeg.Encoder,
  TFFmpeg.StillImage,
  TFFmpeg.VideoScaler,
  TFFmpeg.Utils,
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Internal.Frames,
  TFFmpeg.Media.Internal.Files;

procedure CheckCode(ACode: Integer; ACategory: TMediaErrorCategory; const AOperation: String);
begin
  if ACode < 0 then
    raise EFFmpegMediaError.Create(ACategory, AOperation, FFmpegErrorText(ACode), ACode);
end;

procedure CheckSDR(AFrame: PAVFrame);
begin
  if AFrame.color_trc IN [AVCOL_TRC_SMPTE2084, AVCOL_TRC_ARIB_STD_B67] then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Render image', 'HDR to SDR requires unsupported tone mapping');
  if NOT (AFrame.colorspace IN [AVCOL_SPC_RGB, AVCOL_SPC_BT709, AVCOL_SPC_UNSPECIFIED, AVCOL_SPC_FCC,
    AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M, AVCOL_SPC_SMPTE240M, AVCOL_SPC_BT2020_NCL]) then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Render image', 'Unsupported source color matrix');
end;

procedure CheckDimensions(AWidth, AHeight: Integer);
begin
  if (AWidth < 1) OR (AHeight < 1) OR (Int64(AWidth) * AHeight > MEDIA_MAX_PIXELS) OR
    (Int64(AWidth) * AHeight * 4 > MEDIA_MAX_BUFFER_BYTES) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Render image', 'Image dimensions exceed the configured pixel/storage limit');
end;

function Dimension(AValue: Double): Integer;
begin
  Result:=0;
  if IsNan(AValue) OR IsInfinite(AValue) OR (AValue < 0) OR (AValue > MEDIA_MAX_PIXELS) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Render image', 'Display dimensions are not representable within the pixel limit');
  Result:=Max(1, Integer(Round(AValue)));
end;

procedure Orientation(const ATransform: TMediaDisplayTransform; out A, B, C, D: Integer);
var
  I: Integer;
  Values: Array[0..8] of Double;
begin
  A:=1;
  B:=0;
  C:=0;
  D:=1;
  if NOT ATransform.Known then
    Exit;
  for I:=0 to 8 do
    Values[I]:=ATransform.Values[I];
  if (Abs(Values[2]) > 0.00001) OR (Abs(Values[5]) > 0.00001) OR (Abs(Values[8] - 1) > 0.00001) then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Render image', 'Perspective display transforms are unsupported');
  if (Abs(Values[0]) > 1.00001) OR (Abs(Values[1]) > 1.00001) OR (Abs(Values[3]) > 1.00001) OR (Abs(Values[4]) > 1.00001) then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Render image', 'Only quarter-turn rotations and mirroring are supported');
  A:=Round(Values[0]);
  B:=Round(Values[1]);
  C:=Round(Values[3]);
  D:=Round(Values[4]);
  if (Abs(Values[0] - A) > 0.00001) OR (Abs(Values[1] - B) > 0.00001) OR (Abs(Values[3] - C) > 0.00001) OR
    (Abs(Values[4] - D) > 0.00001) OR (A * A + C * C <> 1) OR (B * B + D * D <> 1) OR (A * B + C * D <> 0) then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Render image', 'Only orthogonal quarter-turn rotations and mirroring are supported');
end;

function AllocateImage(AWidth, AHeight: Integer): PAVFrame;
var
  Required, Code: Integer;
begin
  Result:=nil;
  CheckDimensions(AWidth, AHeight);
  Required:=av_image_get_buffer_size(AV_PIX_FMT_BGRA, (AWidth + 31) AND NOT 31, (AHeight + 31) AND NOT 31, 32);
  CheckCode(Required, mecDecode, 'Allocate image');
  if Required > MEDIA_MAX_BUFFER_BYTES - 4096 then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Allocate image', 'Aligned native image storage exceeds 256 MiB');
  Result:=av_frame_alloc;
  if NOT Assigned(Result) then
    raise EFFmpegMediaError.Create(mecDecode, 'Allocate image', 'Cannot allocate image header');
  Result.width:=AWidth;
  Result.height:=AHeight;
  Result.format:=Ord(AV_PIX_FMT_BGRA);
  Code:=av_frame_get_buffer(Result, 32);
  if Code < 0 then
  begin
    av_frame_free(@Result);
    CheckCode(Code, mecDecode, 'Allocate image');
  end;
end;

function RenderImageControlled(const AFrame: IMediaVideoFrame; const AStream: TMediaStreamInfo;
  const ASettings: TMediaImageSettings; AOperation: TMediaOperation): IMediaVideoFrame;
var
  Source, Scaled, Destination: PAVFrame;
  Backing: TBytes;
  DisplayWidth, DisplayHeight, ScaleFactor, SwapValue: Double;
  Width, Height, ContentWidth, ContentHeight, ScaleWidth, ScaleHeight: Integer;
  A, B, C, D, MinX, MinY, OffsetX, OffsetY: Integer;
  X, Y, U, V, SourceX, SourceY, Channel, Alpha: Integer;
  Pixel, Target: PByte;
  Background: Array[0..2] of Byte;
begin
  Result:=nil;
  ASettings.Validate;
  AOperation.Check('Render image');
  Source:=ReferenceVideo(AFrame, Backing);
  Scaled:=nil;
  Destination:=nil;
  try
    CheckSDR(Source);
    if SameText(AStream.Color.Transfer, 'smpte2084') OR SameText(AStream.Color.Transfer, 'arib-std-b67') then
      raise EFFmpegMediaError.Create(mecUnsupported, 'Render image', 'HDR to SDR requires unsupported tone mapping');
    DisplayWidth:=Source.width;
    DisplayHeight:=Source.height;
    A:=1;
    B:=0;
    C:=0;
    D:=1;
    if ASettings.Geometry = migDisplay then
    begin
      if AStream.PixelAspect.Known then
        DisplayWidth:=DisplayWidth * AStream.PixelAspect.Numerator / AStream.PixelAspect.Denominator;
      Orientation(AStream.DisplayTransform, A, B, C, D);
    end;
    if A = 0 then
    begin
      SwapValue:=DisplayWidth;
      DisplayWidth:=DisplayHeight;
      DisplayHeight:=SwapValue;
    end;
    Width:=ASettings.Width;
    Height:=ASettings.Height;
    if (Width = 0) AND (Height = 0) then
    begin
      Width:=Dimension(DisplayWidth);
      Height:=Dimension(DisplayHeight);
    end else
    if Width = 0 then
      Width:=Dimension(Height * DisplayWidth / DisplayHeight)
    else
    if Height = 0 then
      Height:=Dimension(Width * DisplayHeight / DisplayWidth);
    CheckDimensions(Width, Height);
    ContentWidth:=Width;
    ContentHeight:=Height;
    if ASettings.Fit <> mfStretch then
    begin
      ScaleFactor:=Min(Width / DisplayWidth, Height / DisplayHeight);
      if ASettings.Fit = mfFill then
        ScaleFactor:=Max(Width / DisplayWidth, Height / DisplayHeight);
      ContentWidth:=Dimension(DisplayWidth * ScaleFactor);
      ContentHeight:=Dimension(DisplayHeight * ScaleFactor);
      if ASettings.Fit = mfFit then
      begin
        ContentWidth:=Min(Width, ContentWidth);
        ContentHeight:=Min(Height, ContentHeight);
      end else
      begin
        ContentWidth:=Max(Width, ContentWidth);
        ContentHeight:=Max(Height, ContentHeight);
      end;
    end;
    CheckDimensions(ContentWidth, ContentHeight);
    ScaleWidth:=ContentWidth;
    ScaleHeight:=ContentHeight;
    if A = 0 then
    begin
      ScaleWidth:=ContentHeight;
      ScaleHeight:=ContentWidth;
    end;
    CheckCode(TFFmpegVideoScaler.Scale(Source, ScaleWidth, ScaleHeight, AV_PIX_FMT_BGRA, Scaled), mecDecode, 'Resize image');
    AOperation.Check('Render image');
    Destination:=AllocateImage(Width, Height);
    OffsetX:=(Width - ContentWidth) DIV 2;
    OffsetY:=(Height - ContentHeight) DIV 2;
    MinX:=Min(0, A * (ScaleWidth - 1)) + Min(0, C * (ScaleHeight - 1));
    MinY:=Min(0, B * (ScaleWidth - 1)) + Min(0, D * (ScaleHeight - 1));
    Background[0]:=ASettings.BackgroundRGB AND $FF;
    Background[1]:=(ASettings.BackgroundRGB SHR 8) AND $FF;
    Background[2]:=(ASettings.BackgroundRGB SHR 16) AND $FF;
    for Y:=0 to Height - 1 do
    begin
      AOperation.Check('Render image');
      Target:=PByte(NativeUInt(Destination.data[0]) + NativeUInt(Y) * NativeUInt(Destination.linesize[0]));
      for X:=0 to Width - 1 do
      begin
        U:=X - OffsetX;
        V:=Y - OffsetY;
        if (U < 0) OR (V < 0) OR (U >= ContentWidth) OR (V >= ContentHeight) then
        begin
          for Channel:=0 to 2 do
            Target[Channel]:=Background[Channel];
          Target[3]:=255;
        end else
        begin
          SourceX:=A * (U + MinX) + B * (V + MinY);
          SourceY:=C * (U + MinX) + D * (V + MinY);
          Pixel:=PByte(NativeUInt(Scaled.data[0]) + NativeUInt(SourceY) * NativeUInt(Scaled.linesize[0]) + NativeUInt(SourceX) * 4);
          Alpha:=Pixel[3];
          if ASettings.AlphaMode = mamPreserve then
            Move(Pixel^, Target^, 4)
          else
          begin
            for Channel:=0 to 2 do
              Target[Channel]:=(Integer(Pixel[Channel]) * Alpha + Integer(Background[Channel]) * (255 - Alpha) + 127) DIV 255;
            Target[3]:=255;
          end;
        end;
        Inc(Target, 4);
      end;
    end;
    Destination.colorspace:=AVCOL_SPC_RGB;
    Destination.color_range:=AVCOL_RANGE_JPEG;
    Destination.color_primaries:=Source.color_primaries;
    Destination.color_trc:=Source.color_trc;
    Destination.sample_aspect_ratio.num:=1;
    Destination.sample_aspect_ratio.den:=1;
    // Display transforms are already applied. Do not copy their native side data.
    Result:=TakeVideoFrame(Destination, AFrame.Timestamp, AFrame.Duration, AFrame.StreamIndex, AFrame.FormatChanged);
  finally
    av_frame_free(@Destination);
    av_frame_free(@Scaled);
    av_frame_free(@Source);
  end;
end;

function RenderImage(const AFrame: IMediaVideoFrame; const AStream: TMediaStreamInfo; const ASettings: TMediaImageSettings;
  const AToken: IMediaCancellationToken): IMediaVideoFrame;
var
  Operation: TMediaOperation;
begin
  Result:=nil;
  Operation:=TMediaOperation.Create(AToken, ASettings.TimeoutMilliseconds);
  try
    Result:=RenderImageControlled(AFrame, AStream, ASettings, Operation);
  finally
    Operation.Free;
  end;
end;

function LoadImageFile(const AFilename: String; const ASettings: TMediaImageSettings; const AToken: IMediaCancellationToken): IMediaVideoFrame;
var
  Operation: TMediaOperation;
  Source, Converted: PAVFrame;
  Frame: IMediaVideoFrame;
  Stream: TMediaStreamInfo;
  Code: Integer;
begin
  Result:=nil;
  ASettings.Validate;
  if (AFilename = '') OR (Pos(#0, AFilename) > 0) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Load image', 'A literal local filename without NUL is required');
  Operation:=TMediaOperation.Create(AToken, ASettings.TimeoutMilliseconds);
  Source:=nil;
  Converted:=nil;
  try
    Operation.Check('Load image');
    Code:=TFFmpegStillImage.DecodeFile(AFilename, Operation.Interrupt, Source);
    Operation.Check('Load image');
    if Code = AVERROR_DECODER_NOT_FOUND then
      raise EFFmpegMediaError.Create(mecUnsupported, 'Load image', 'Required image decoder is unavailable', Code);
    if (Code = AVERROR_ENOENT) OR (Code = AVERROR_EIO) then
      CheckCode(Code, mecInputOutput, 'Load image');
    CheckCode(Code, mecDecode, 'Load image');
    CheckSDR(Source);
    Stream:=Default(TMediaStreamInfo);
    if (Source.sample_aspect_ratio.num > 0) AND (Source.sample_aspect_ratio.den > 0) then
      Stream.PixelAspect:=TMediaRate.Create(Source.sample_aspect_ratio.num, Source.sample_aspect_ratio.den);
    Stream.DisplayTransform:=FrameDisplayMatrix(Source);
    CheckCode(TFFmpegVideoScaler.Scale(Source, Source.width, Source.height, AV_PIX_FMT_BGRA, Converted), mecDecode, 'Decode image pixels');
    Frame:=TakeVideoFrame(Converted, TMediaTime.Unknown, TMediaTime.Unknown, -1, False);
    Result:=RenderImageControlled(Frame, Stream, ASettings, Operation);
    Operation.Check('Load image');
  finally
    av_frame_free(@Converted);
    av_frame_free(@Source);
    Operation.Free;
  end;
end;

function ResolveFormat(AFormat: TMediaImageFormat; const AFilename: String): TMediaImageFormat;
var
  Extension: String;
begin
  Result:=AFormat;
  if AFormat <> mifAutomatic then
    Exit;
  Extension:=LowerCase(ExtractFileExt(AFilename));
  if Extension = '.bmp' then
    Result:=mifBMP
  else
  if Extension = '.png' then
    Result:=mifPNG
  else
  if (Extension = '.jpg') OR (Extension = '.jpeg') then
    Result:=mifJPEG
  else
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Save image', 'Choose BMP/PNG/JPEG explicitly or use a recognized image extension');
end;

function EncodeControlled(const AFrame: IMediaVideoFrame; const ASettings: TMediaImageWriteSettings; AOperation: TMediaOperation): TBytes;
var
  Encoder: TFFmpegEncoder;
  Source, Converted: PAVFrame;
  Packet: PAVPacket;
  Backing: TBytes;
  Encoded: TBytes;
  CodecID: TAVCodecID;
  PixelFormat: TAVPixelFormat;
  Code, X, Y, LengthBefore: Integer;
  AlphaNeeded: Boolean;
  Row: PByte;
  RenderSettings: TMediaImageSettings;
  OpaqueFrame: IMediaVideoFrame;

  function Receive: Integer;
  var
    NextLength: Int64;
  begin
    Result:=AVERROR_EAGAIN;
    while True do
    begin
      AOperation.Check('Encode image');
      Result:=Encoder.ReceivePacket(Packet);
      if (Result = AVERROR_EAGAIN) OR (Result = AVERROR_EOF) then
        Exit;
      CheckCode(Result, mecEncode, 'Receive image packet');
      try
        NextLength:=Int64(Length(Encoded)) + Packet.size;
        if (Packet.size < 0) OR (NextLength > MEDIA_MAX_BUFFER_BYTES) then
          raise EFFmpegMediaError.Create(mecEncode, 'Encode image', 'Encoded image storage limit exceeded');
        LengthBefore:=Length(Encoded);
        SetLength(Encoded, Integer(NextLength));
        if Packet.size > 0 then
          Move(Packet.data^, Encoded[LengthBefore], Packet.size);
      finally
        av_packet_unref(Packet);
      end;
    end;
  end;

begin
  Result:=nil;
  ASettings.Validate;
  CodecID:=AV_CODEC_ID_NONE;
  PixelFormat:=AV_PIX_FMT_NONE;
  case ASettings.ImageFormat of
    mifBMP:
    begin
      CodecID:=AV_CODEC_ID_BMP;
      PixelFormat:=AV_PIX_FMT_BGR24;
    end;

    mifPNG:
    begin
      CodecID:=AV_CODEC_ID_PNG;
      PixelFormat:=AV_PIX_FMT_RGBA;
    end;

    mifJPEG:
    begin
      CodecID:=AV_CODEC_ID_MJPEG;
      PixelFormat:=AV_PIX_FMT_YUVJ420P;
    end;

    else raise EFFmpegMediaError.Create(mecInvalidSettings, 'Encode image', 'Encoding requires an explicit BMP/PNG/JPEG format');
  end;
  AOperation.Check('Encode image');
  Encoder:=TFFmpegEncoder.Create;
  Source:=nil;
  Converted:=nil;
  Packet:=nil;
  try
    Code:=Encoder.Allocate(CodecID);
    if Code = AVERROR_ENCODER_NOT_FOUND then
      raise EFFmpegMediaError.Create(mecUnsupported, 'Encode image', 'Required image encoder is unavailable', Code);
    CheckCode(Code, mecEncode, 'Allocate image encoder');
    Source:=ReferenceVideo(AFrame, Backing);
    CheckSDR(Source);
    AlphaNeeded:=False;
    if (ASettings.ImageFormat <> mifPNG) AND (Source.format = Ord(AV_PIX_FMT_BGRA)) then
      for Y:=0 to Source.height - 1 do
      begin
        AOperation.Check('Encode image');
        Row:=PByte(NativeUInt(Source.data[0]) + NativeUInt(Y) * NativeUInt(Source.linesize[0]));
        for X:=0 to Source.width - 1 do
          if Row[X * 4 + 3] <> 255 then
            AlphaNeeded:=True;
      end;
    if AlphaNeeded then
    begin
      RenderSettings:=TMediaImageSettings.Default;
      RenderSettings.Geometry:=migCoded;
      RenderSettings.BackgroundRGB:=ASettings.BackgroundRGB;
      OpaqueFrame:=RenderImageControlled(AFrame, Default(TMediaStreamInfo), RenderSettings, AOperation);
      av_frame_free(@Source);
      Source:=ReferenceVideo(OpaqueFrame, Backing);
    end;
    CheckCode(TFFmpegVideoScaler.Scale(Source, Source.width, Source.height, PixelFormat, Converted), mecEncode, 'Prepare image pixels');
    Encoder.CodecContext.width:=Converted.width;
    Encoder.CodecContext.height:=Converted.height;
    Encoder.CodecContext.pix_fmt:=PixelFormat;
    Encoder.CodecContext.time_base.num:=1;
    Encoder.CodecContext.time_base.den:=25;
    Encoder.CodecContext.color_range:=AVCOL_RANGE_JPEG;
    Encoder.CodecContext.colorspace:=AVCOL_SPC_RGB;
    if ASettings.ImageFormat = mifJPEG then
    begin
      Encoder.CodecContext.colorspace:=AVCOL_SPC_BT470BG;
      Encoder.CodecContext.flags:=Encoder.CodecContext.flags OR AV_CODEC_FLAG_QSCALE;
      Encoder.CodecContext.global_quality:=(2 + (100 - ASettings.Quality) * 29 DIV 99) * FF_QP2LAMBDA;
      Converted.quality:=Encoder.CodecContext.global_quality;
    end;
    Encoder.CodecContext.color_primaries:=Source.color_primaries;
    Encoder.CodecContext.color_trc:=Source.color_trc;
    Converted.pts:=0;
    Converted.duration:=1;
    CheckCode(Encoder.Open, mecEncode, 'Open image encoder');
    Packet:=av_packet_alloc;
    if NOT Assigned(Packet) then
      raise EFFmpegMediaError.Create(mecEncode, 'Encode image', 'Cannot allocate an encoded packet');
    repeat
      Code:=Encoder.SendFrame(Converted);
      if Code = AVERROR_EAGAIN then
        if Receive = AVERROR_EAGAIN then
          raise EFFmpegMediaError.Create(mecEncode, 'Encode image', 'Encoder send/receive made no progress');
    until Code <> AVERROR_EAGAIN;
    CheckCode(Code, mecEncode, 'Send image frame');
    if Receive <> AVERROR_EOF then
    begin
      repeat
        Code:=Encoder.SendFrame(nil);
        if Code = AVERROR_EAGAIN then
          if Receive = AVERROR_EAGAIN then
            raise EFFmpegMediaError.Create(mecEncode, 'Drain image encoder', 'Encoder send/receive made no progress');
      until Code <> AVERROR_EAGAIN;
      CheckCode(Code, mecEncode, 'Drain image encoder');
      if Receive <> AVERROR_EOF then
        raise EFFmpegMediaError.Create(mecEncode, 'Drain image encoder', 'Encoder failed to complete image drain');
    end;
    if Length(Encoded) = 0 then
      raise EFFmpegMediaError.Create(mecEncode, 'Encode image', 'Encoder produced no image data');
    AOperation.Check('Encode image');
    Result:=Encoded;
  finally
    av_packet_free(@Packet);
    av_frame_free(@Converted);
    av_frame_free(@Source);
    Encoder.Free;
  end;
end;

function EncodeImage(const AFrame: IMediaVideoFrame; const ASettings: TMediaImageWriteSettings;
  const AToken: IMediaCancellationToken): TBytes;
var
  Operation: TMediaOperation;
begin
  Result:=nil;
  Operation:=TMediaOperation.Create(AToken, ASettings.TimeoutMilliseconds);
  try
    Result:=EncodeControlled(AFrame, ASettings, Operation);
  finally
    Operation.Free;
  end;
end;

procedure SaveImageFile(const AFrame: IMediaVideoFrame; const AFilename: String; const ASettings: TMediaImageWriteSettings;
  const AToken: IMediaCancellationToken);
var
  Operation: TMediaOperation;
  Output: TMediaLocalOutput;
  Settings: TMediaImageWriteSettings;
  Bytes: TBytes;
  Stream: TFileStream;
  Position, Count: Integer;
begin
  ASettings.Validate;
  Settings:=ASettings;
  Settings.ImageFormat:=ResolveFormat(Settings.ImageFormat, AFilename);
  Operation:=TMediaOperation.Create(AToken, Settings.TimeoutMilliseconds);
  try
    Operation.Check('Save image');
    Output:=TMediaLocalOutput.Create(AFilename, Settings.Overwrite);
    try
      Bytes:=EncodeControlled(AFrame, Settings, Operation);
      try
        Stream:=TFileStream.Create(Output.Temporary, fmOpenWrite OR fmShareExclusive);
        try
          Position:=0;
          while Position < Length(Bytes) do
          begin
            Operation.Check('Save image');
            Count:=Min(65536, Length(Bytes) - Position);
            Stream.WriteBuffer(Bytes[Position], Count);
            Inc(Position, Count);
          end;
        finally
          Stream.Free;
        end;
      except
        on E: EFFmpegMediaError do
          raise;
        on E: Exception do
          raise EFFmpegMediaError.Create(mecInputOutput, 'Save image', E.Message);
      end;
      Operation.Check('Save image');
      Output.Publish;
    finally
      Output.Free;
    end;
  finally
    Operation.Free;
  end;
end;

end.
