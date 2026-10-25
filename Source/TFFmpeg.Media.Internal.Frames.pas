unit TFFmpeg.Media.Internal.Frames;

interface

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  libavutil_frame,
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Frames;

function CreateVideoCopy(const ABytes: TBytes; AWidth, AHeight, AStride: Integer; APixelFormat: TMediaPixelFormat;
  const ATimestamp: TMediaTime; AStreamIndex: Integer; AFormatChanged: Boolean): IMediaVideoFrame;
function CreateAudioCopy(const ABytes: TBytes; ASampleCount, ASampleRate: Integer; ASampleFormat: TMediaSampleFormat;
  const AChannelLayout: TMediaChannelLayout; const ATimestamp: TMediaTime; AStreamIndex: Integer;
  AFormatChanged: Boolean): IMediaAudioBuffer;
// Transfers an already converted, independently owned native frame on success.
function TakeVideoFrame(var AFrame: PAVFrame; const ATimestamp, ADuration: TMediaTime; AStreamIndex: Integer;
  AFormatChanged: Boolean): IMediaVideoFrame;
// Caller owns the returned native header/reference. If backing bytes are returned,
// retain them until after freeing the frame; its data borrows those copied bytes.
function ReferenceVideo(const AFrame: IMediaVideoFrame; out ABackingBytes: TBytes): PAVFrame;

implementation

uses
  libavutil_pixfmt,
  TFFmpeg.Media.Errors;

type
  IMediaNativeVideo = interface
    ['{036DE766-2E62-44D7-A669-C4DA47FE3DBA}']
    function BorrowNativeFrame: PAVFrame;
  end;

  TMediaNativeVideo = class(TInterfacedObject, IMediaSample, IMediaVideoFrame, IMediaNativeVideo)
  private
    FFrame: PAVFrame;
    FTimestamp: TMediaTime;
    FDuration: TMediaTime;
    FStreamIndex: Integer;
    FFormatChanged: Boolean;
    FStride: Integer;
    FPixelFormat: TMediaPixelFormat;
  public
    constructor Create(var AFrame: PAVFrame; const ATimestamp, ADuration: TMediaTime; AStreamIndex: Integer; AFormatChanged: Boolean);
    destructor Destroy; override;
    function GetKind: TMediaKind;
    function GetStreamIndex: Integer;
    function GetTimestamp: TMediaTime;
    function GetDuration: TMediaTime;
    function GetFormatChanged: Boolean;
    function CopyBytes: TBytes;
    function GetWidth: Integer;
    function GetHeight: Integer;
    function GetStride: Integer;
    function GetPixelFormat: TMediaPixelFormat;
    function BorrowNativeFrame: PAVFrame;
  end;

  TMediaOwnedSample = class(TInterfacedObject, IMediaSample)
  protected
    FBytes: TBytes;
    FKind: TMediaKind;
    FStreamIndex: Integer;
    FTimestamp: TMediaTime;
    FDuration: TMediaTime;
    FFormatChanged: Boolean;
  public
    constructor Create(const ABytes: TBytes; AKind: TMediaKind; AStreamIndex: Integer; const ATimestamp, ADuration: TMediaTime;
      AFormatChanged: Boolean);
    function GetKind: TMediaKind;
    function GetStreamIndex: Integer;
    function GetTimestamp: TMediaTime;
    function GetDuration: TMediaTime;
    function GetFormatChanged: Boolean;
    function CopyBytes: TBytes;
  end;

  TMediaOwnedVideo = class(TMediaOwnedSample, IMediaVideoFrame)
  private
    FWidth: Integer;
    FHeight: Integer;
    FStride: Integer;
    FPixelFormat: TMediaPixelFormat;
  public
    constructor Create(const ABytes: TBytes; AWidth, AHeight, AStride: Integer; APixelFormat: TMediaPixelFormat;
      const ATimestamp: TMediaTime; AStreamIndex: Integer; AFormatChanged: Boolean);
    function GetWidth: Integer;
    function GetHeight: Integer;
    function GetStride: Integer;
    function GetPixelFormat: TMediaPixelFormat;
  end;

  TMediaOwnedAudio = class(TMediaOwnedSample, IMediaAudioBuffer)
  private
    FSampleCount: Integer;
    FSampleRate: Integer;
    FSampleFormat: TMediaSampleFormat;
    FChannelLayout: TMediaChannelLayout;
  public
    constructor Create(const ABytes: TBytes; ASampleCount, ASampleRate: Integer; ASampleFormat: TMediaSampleFormat;
      const AChannelLayout: TMediaChannelLayout; const ATimestamp: TMediaTime; AStreamIndex: Integer; AFormatChanged: Boolean);
    function GetSampleCount: Integer;
    function GetSampleRate: Integer;
    function GetSampleFormat: TMediaSampleFormat;
    function GetChannelLayout: TMediaChannelLayout;
  end;

constructor TMediaNativeVideo.Create(var AFrame: PAVFrame; const ATimestamp, ADuration: TMediaTime;
  AStreamIndex: Integer; AFormatChanged: Boolean);
var
  BytesPerPixel: Integer;
begin
  inherited Create;
  if NOT Assigned(AFrame) then
    raise EFFmpegMediaError.Create(mecInvalidState, 'Take video', 'Missing converted frame');
  case TAVPixelFormat(AFrame.format) of
    AV_PIX_FMT_RGB24:
    begin
      FPixelFormat:=mpfRGB24;
      BytesPerPixel:=3;
    end;

    AV_PIX_FMT_BGRA:
    begin
      FPixelFormat:=mpfBGRA32;
      BytesPerPixel:=4;
    end;

    else raise EFFmpegMediaError.Create(mecUnsupported, 'Take video', 'Expected converted RGB/BGRA');
  end;
  if (AFrame.width <= 0) OR (AFrame.height <= 0) OR (Int64(AFrame.width) * AFrame.height > MEDIA_MAX_PIXELS) OR
    (Int64(AFrame.width) * AFrame.height * BytesPerPixel > MEDIA_MAX_BUFFER_BYTES) OR
    (AFrame.linesize[0] < Int64(AFrame.width) * BytesPerPixel) OR NOT Assigned(AFrame.data[0]) then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Take video', 'Invalid converted frame geometry or allocation limit exceeded');

  FStride:=AFrame.width * BytesPerPixel;
  FTimestamp:=ATimestamp;
  FDuration:=ADuration;
  FStreamIndex:=AStreamIndex;
  FFormatChanged:=AFormatChanged;
  FFrame:=AFrame;
  AFrame:=nil;
end;

destructor TMediaNativeVideo.Destroy;
begin
  av_frame_free(@FFrame);
  inherited Destroy;
end;

function TMediaNativeVideo.GetKind: TMediaKind;
begin
  Result:=mkVideo;
end;

function TMediaNativeVideo.GetStreamIndex: Integer;
begin
  Result:=FStreamIndex;
end;

function TMediaNativeVideo.GetTimestamp: TMediaTime;
begin
  Result:=FTimestamp;
end;

function TMediaNativeVideo.GetDuration: TMediaTime;
begin
  Result:=FDuration;
end;

function TMediaNativeVideo.GetFormatChanged: Boolean;
begin
  Result:=FFormatChanged;
end;

function TMediaNativeVideo.CopyBytes: TBytes;
var
  Y: Integer;
begin
  Result:=nil;
  SetLength(Result, FStride * FFrame.height);
  // Return only initialized pixels. Native row padding is private storage.
  for Y:=0 to FFrame.height - 1 do
    Move(PByte(NativeUInt(FFrame.data[0]) + NativeUInt(Y) * NativeUInt(FFrame.linesize[0]))^, Result[Y * FStride], FStride);
end;

function TMediaNativeVideo.GetWidth: Integer;
begin
  Result:=FFrame.width;
end;

function TMediaNativeVideo.GetHeight: Integer;
begin
  Result:=FFrame.height;
end;

function TMediaNativeVideo.GetStride: Integer;
begin
  Result:=FStride;
end;

function TMediaNativeVideo.GetPixelFormat: TMediaPixelFormat;
begin
  Result:=FPixelFormat;
end;

function TakeVideoFrame(var AFrame: PAVFrame; const ATimestamp, ADuration: TMediaTime; AStreamIndex: Integer;
  AFormatChanged: Boolean): IMediaVideoFrame;
begin
  Result:=TMediaNativeVideo.Create(AFrame, ATimestamp, ADuration, AStreamIndex, AFormatChanged);
end;

constructor TMediaOwnedSample.Create(const ABytes: TBytes; AKind: TMediaKind; AStreamIndex: Integer;
  const ATimestamp, ADuration: TMediaTime; AFormatChanged: Boolean);
begin
  inherited Create;
  if AStreamIndex < -1 then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Copy sample', 'Stream index must be -1 or nonnegative');
  FBytes:=Copy(ABytes);
  FKind:=AKind;
  FStreamIndex:=AStreamIndex;
  FTimestamp:=ATimestamp;
  FDuration:=ADuration;
  FFormatChanged:=AFormatChanged;
end;

function TMediaOwnedSample.GetKind: TMediaKind;
begin
  Result:=FKind;
end;

function TMediaOwnedSample.GetStreamIndex: Integer;
begin
  Result:=FStreamIndex;
end;

function TMediaOwnedSample.GetTimestamp: TMediaTime;
begin
  Result:=FTimestamp;
end;

function TMediaOwnedSample.GetDuration: TMediaTime;
begin
  Result:=FDuration;
end;

function TMediaOwnedSample.GetFormatChanged: Boolean;
begin
  Result:=FFormatChanged;
end;

function TMediaOwnedSample.CopyBytes: TBytes;
begin
  Result:=Copy(FBytes);
end;

constructor TMediaOwnedVideo.Create(const ABytes: TBytes; AWidth, AHeight, AStride: Integer; APixelFormat: TMediaPixelFormat;
  const ATimestamp: TMediaTime; AStreamIndex: Integer; AFormatChanged: Boolean);
var
  BytesPerPixel: Integer;
  Required: Int64;
begin
  if (AWidth <= 0) OR (AHeight <= 0) OR (Int64(AWidth) * AHeight > MEDIA_MAX_PIXELS) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Copy video', 'Invalid dimensions or pixel limit exceeded');
  case APixelFormat of
    mpfRGB24: BytesPerPixel:=3;
    mpfBGRA32: BytesPerPixel:=4;
    else raise EFFmpegMediaError.Create(mecInvalidSettings, 'Copy video', 'An explicit supported pixel format is required');
  end;
  Required:=Int64(AStride) * AHeight;
  if (AStride < Int64(AWidth) * BytesPerPixel) OR (Required > MEDIA_MAX_BUFFER_BYTES) OR (Required <> Length(ABytes)) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Copy video', 'Buffer size/positive stride mismatch or allocation limit exceeded');

  inherited Create(ABytes, mkVideo, AStreamIndex, ATimestamp, TMediaTime.Unknown, AFormatChanged);
  FWidth:=AWidth;
  FHeight:=AHeight;
  FStride:=AStride;
  FPixelFormat:=APixelFormat;
end;

function TMediaOwnedVideo.GetWidth: Integer;
begin
  Result:=FWidth;
end;

function TMediaOwnedVideo.GetHeight: Integer;
begin
  Result:=FHeight;
end;

function TMediaOwnedVideo.GetStride: Integer;
begin
  Result:=FStride;
end;

function TMediaOwnedVideo.GetPixelFormat: TMediaPixelFormat;
begin
  Result:=FPixelFormat;
end;

constructor TMediaOwnedAudio.Create(const ABytes: TBytes; ASampleCount, ASampleRate: Integer; ASampleFormat: TMediaSampleFormat;
  const AChannelLayout: TMediaChannelLayout; const ATimestamp: TMediaTime; AStreamIndex: Integer; AFormatChanged: Boolean);
var
  BytesPerSample: Integer;
  Required: Int64;
begin
  AChannelLayout.Validate;
  if (ASampleCount <= 0) OR (ASampleRate < 8000) OR (ASampleRate > 384000) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Copy audio', 'Positive sample count and 8-384 kHz sample rate required');
  case ASampleFormat of
    msfS16: BytesPerSample:=2;
    msfFloat32: BytesPerSample:=4;
    else raise EFFmpegMediaError.Create(mecInvalidSettings, 'Copy audio', 'An explicit supported sample format is required');
  end;
  Required:=Int64(ASampleCount) * AChannelLayout.Channels * BytesPerSample;
  if (Required > MEDIA_MAX_BUFFER_BYTES) OR (Required <> Length(ABytes)) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Copy audio', 'Buffer size mismatch or allocation limit exceeded');

  inherited Create(ABytes, mkAudio, AStreamIndex, ATimestamp,
    TMediaTime.FromTicks(ASampleCount, TMediaRate.Create(1, ASampleRate)), AFormatChanged);
  FSampleCount:=ASampleCount;
  FSampleRate:=ASampleRate;
  FSampleFormat:=ASampleFormat;
  FChannelLayout:=AChannelLayout;
end;

function TMediaOwnedAudio.GetSampleCount: Integer;
begin
  Result:=FSampleCount;
end;

function TMediaOwnedAudio.GetSampleRate: Integer;
begin
  Result:=FSampleRate;
end;

function TMediaOwnedAudio.GetSampleFormat: TMediaSampleFormat;
begin
  Result:=FSampleFormat;
end;

function TMediaOwnedAudio.GetChannelLayout: TMediaChannelLayout;
begin
  Result:=FChannelLayout;
end;

function CreateVideoCopy(const ABytes: TBytes; AWidth, AHeight, AStride: Integer; APixelFormat: TMediaPixelFormat;
  const ATimestamp: TMediaTime; AStreamIndex: Integer; AFormatChanged: Boolean): IMediaVideoFrame;
begin
  Result:=TMediaOwnedVideo.Create(ABytes, AWidth, AHeight, AStride, APixelFormat, ATimestamp, AStreamIndex, AFormatChanged);
end;

function CreateAudioCopy(const ABytes: TBytes; ASampleCount, ASampleRate: Integer; ASampleFormat: TMediaSampleFormat;
  const AChannelLayout: TMediaChannelLayout; const ATimestamp: TMediaTime; AStreamIndex: Integer;
  AFormatChanged: Boolean): IMediaAudioBuffer;
begin
  Result:=TMediaOwnedAudio.Create(ABytes, ASampleCount, ASampleRate, ASampleFormat, AChannelLayout,
    ATimestamp, AStreamIndex, AFormatChanged);
end;

function TMediaNativeVideo.BorrowNativeFrame: PAVFrame;
begin
  Result:=FFrame;
end;

function ReferenceVideo(const AFrame: IMediaVideoFrame; out ABackingBytes: TBytes): PAVFrame;
var
  Native: IMediaNativeVideo;
  BytesPerPixel: Integer;
begin
  Result:=nil;
  ABackingBytes:=nil;
  if NOT Assigned(AFrame) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Reference video', 'A video frame is required');
  if Supports(AFrame, IMediaNativeVideo, Native) then
  begin
    Result:=av_frame_clone(Native.BorrowNativeFrame);
    if NOT Assigned(Result) then
      raise EFFmpegMediaError.Create(mecDecode, 'Reference video', 'Cannot retain native frame');
    Exit;
  end;

  case AFrame.PixelFormat of
    mpfRGB24: BytesPerPixel:=3;
    mpfBGRA32: BytesPerPixel:=4;
    else raise EFFmpegMediaError.Create(mecInvalidSettings, 'Reference video', 'An RGB/BGRA frame is required');
  end;
  if (AFrame.Width < 1) OR (AFrame.Height < 1) OR (Int64(AFrame.Width) * AFrame.Height > MEDIA_MAX_PIXELS) OR
    (AFrame.Stride < Int64(AFrame.Width) * BytesPerPixel) OR (Int64(AFrame.Stride) * AFrame.Height > MEDIA_MAX_BUFFER_BYTES) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Reference video', 'Invalid frame geometry/stride or buffer limit exceeded');
  ABackingBytes:=AFrame.CopyBytes;
  if Length(ABackingBytes) <> Int64(AFrame.Stride) * AFrame.Height then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Reference video', 'Frame copy length does not match its geometry');
  Result:=av_frame_alloc;
  if NOT Assigned(Result) then
    raise EFFmpegMediaError.Create(mecDecode, 'Reference video', 'Cannot allocate a native frame header');
  Result.width:=AFrame.Width;
  Result.height:=AFrame.Height;
  Result.linesize[0]:=AFrame.Stride;
  Result.data[0]:=@ABackingBytes[0];
  Result.format:=Ord(AV_PIX_FMT_BGRA);
  if AFrame.PixelFormat = mpfRGB24 then
    Result.format:=Ord(AV_PIX_FMT_RGB24);
  Result.colorspace:=AVCOL_SPC_RGB;
  Result.color_range:=AVCOL_RANGE_JPEG;
  Result.color_primaries:=AVCOL_PRI_BT709;
  Result.color_trc:=AVCOL_TRC_IEC61966_2_1;
end;

end.
