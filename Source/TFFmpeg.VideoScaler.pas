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
  libavutil_error;

class function TFFmpegVideoScaler.Scale(ASource: PAVFrame; AWidth, AHeight: Integer; AFormat: TAVPixelFormat;
  out ADestination: PAVFrame; AFlags: Integer): Integer;
var
  Context: PSwsContext;
  Frame: PAVFrame;
  Rows: Integer;
begin
  Result:=AVERROR_EINVAL;
  ADestination:=nil;
  if NOT Assigned(ASource) OR (ASource.width <= 0) OR (ASource.height <= 0) OR
    (AWidth <= 0) OR (AHeight <= 0) OR NOT Assigned(ASource.data[0]) then
    Exit;
  // Bound this convenience allocator; callers requiring larger frames can use the raw API.
  if (Int64(ASource.width) * ASource.height > 67108864) OR (Int64(AWidth) * AHeight > 67108864) then
    Exit;
  if (sws_isSupportedInput(TAVPixelFormat(ASource.format)) <= 0) OR (sws_isSupportedOutput(AFormat) <= 0) then
    Exit;
  Context:=sws_getContext(ASource.width, ASource.height, TAVPixelFormat(ASource.format),
    AWidth, AHeight, AFormat, AFlags, nil, nil, nil);
  if NOT Assigned(Context) then
    Exit(AVERROR_ENOMEM);
  Frame:=nil;
  try
    Frame:=av_frame_alloc;
    if NOT Assigned(Frame) then
      Exit(AVERROR_ENOMEM);
    Frame.width:=AWidth;
    Frame.height:=AHeight;
    Frame.format:=Ord(AFormat);
    Result:=av_frame_get_buffer(Frame, 32);
    if Result < 0 then
      Exit;
    Rows:=sws_scale(Context, @ASource.data[0], @ASource.linesize[0], 0, ASource.height,
      @Frame.data[0], @Frame.linesize[0]);
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
    ADestination:=Frame;
    Frame:=nil;
    Result:=0;
  finally
    av_frame_free(@Frame);
    sws_freeContext(Context);
  end;
end;

end.
