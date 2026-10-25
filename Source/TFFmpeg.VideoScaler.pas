unit TFFmpeg.VideoScaler;

interface

uses
  libavutil_frame,
  libavutil_pixfmt,
  libswscale;

type
  TFFmpegVideoScaler = class sealed
  public
    // Borrows ASource. On success caller owns ADestination; on failure it is nil.
    // The destination has independent storage, including when no resize is needed.
    class function Scale(ASource: PAVFrame; AWidth, AHeight: Integer; AFormat: TAVPixelFormat;
      out ADestination: PAVFrame; AFlags: Integer = SWS_AREA): Integer; static;
  end;

implementation

uses
  libavutil_error,
  libavutil_imgutils;

class function TFFmpegVideoScaler.Scale(ASource: PAVFrame; AWidth, AHeight: Integer; AFormat: TAVPixelFormat;
  out ADestination: PAVFrame; AFlags: Integer): Integer;
var
  Context: PSwsContext;
  Frame: PAVFrame;
  Rows: Integer;
  ColorSpace, SourceRange: Integer;
  BufferSize: Integer;
begin
  Result:=AVERROR_EINVAL;
  ADestination:=nil;
  if NOT Assigned(ASource) OR (ASource.width <= 0) OR (ASource.height <= 0) OR (AWidth <= 0) OR (AHeight <= 0) OR NOT Assigned(ASource.data[0]) then
    Exit;

  // Bound this convenience allocator; callers requiring larger frames can use the raw API.
  if (Int64(ASource.width) * ASource.height > 67108864) OR (Int64(AWidth) * AHeight > 67108864) then
    Exit;
  if (sws_isSupportedInput(TAVPixelFormat(ASource.format)) <= 0) OR (sws_isSupportedOutput(AFormat) <= 0) then
    Exit;

  // av_frame_get_buffer can pad both dimensions, not just each row's byte
  // count. Include a conservative bound plus per-plane padding before allocation.
  BufferSize:=av_image_get_buffer_size(AFormat, (AWidth + 31) AND NOT 31, (AHeight + 31) AND NOT 31, 32);
  if BufferSize < 0 then
    Exit(BufferSize);
  if BufferSize > 256 * 1024 * 1024 - 4096 then
    Exit;

  Context:=sws_getContext(ASource.width, ASource.height, TAVPixelFormat(ASource.format), AWidth, AHeight, AFormat, AFlags, nil, nil, nil);
  if NOT Assigned(Context) then
    Exit(AVERROR_ENOMEM);

  Frame:=nil;

  try
    if AFormat IN [AV_PIX_FMT_RGB24, AV_PIX_FMT_BGR24, AV_PIX_FMT_BGRA, AV_PIX_FMT_RGBA] then
    begin
      ColorSpace:=SWS_CS_DEFAULT;
      case ASource.colorspace of
        AVCOL_SPC_BT709: ColorSpace:=SWS_CS_ITU709;
        AVCOL_SPC_FCC: ColorSpace:=SWS_CS_FCC;
        AVCOL_SPC_SMPTE240M: ColorSpace:=SWS_CS_SMPTE240M;
        AVCOL_SPC_BT2020_NCL: ColorSpace:=SWS_CS_BT2020;
      end;
      SourceRange:=Ord(ASource.color_range = AVCOL_RANGE_JPEG);
      Result:=sws_setColorspaceDetails(Context, sws_getCoefficients(ColorSpace), SourceRange,
        sws_getCoefficients(ColorSpace), 1, 0, 1 SHL 16, 1 SHL 16);
      if Result < 0 then
        Exit;
    end;

    Frame:=av_frame_alloc;
    if NOT Assigned(Frame) then
      Exit(AVERROR_ENOMEM);

    Frame.width:=AWidth;
    Frame.height:=AHeight;
    Frame.format:=Ord(AFormat);
    Result:=av_frame_get_buffer(Frame, 32);
    if Result < 0 then
      Exit;

    Rows:=sws_scale(Context, @ASource.data[0], @ASource.linesize[0], 0, ASource.height, @Frame.data[0], @Frame.linesize[0]);
    if Rows <> AHeight then
    begin
      Result:=AVERROR_EINVAL;
      if Rows < 0 then
        Result:=Rows;
      Exit;
    end;

    // Preserve timing, but not source color-space tags that may no longer describe RGB output.
    Frame.pts:=ASource.pts;
    Frame.duration:=ASource.duration;
    Frame.sample_aspect_ratio.num:=1;
    Frame.sample_aspect_ratio.den:=1;
    if AFormat IN [AV_PIX_FMT_RGB24, AV_PIX_FMT_BGR24, AV_PIX_FMT_BGRA, AV_PIX_FMT_RGBA] then
    begin
      Frame.colorspace:=AVCOL_SPC_RGB;
      Frame.color_range:=AVCOL_RANGE_JPEG;
      Frame.color_primaries:=ASource.color_primaries;
      Frame.color_trc:=ASource.color_trc;
    end;

    ADestination:=Frame;
    Frame:=nil;

    Result:=0;
  finally
    av_frame_free(@Frame);
    sws_freeContext(Context);
  end;
end;

end.
