program VideoScalerSmoke;

{$APPTYPE CONSOLE}
{$POINTERMATH ON}

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  libavutil_frame,
  libavutil_pixfmt,
  libavutil_error,
  libswscale,
  TFFmpeg.VideoScaler,
  TFFmpeg.StillImage;

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

procedure Run;
const
  COLORS: Array[0..3, 0..2] of Byte = ((0, 0, 255), (0, 255, 0), (255, 0, 0), (255, 255, 255));
var
  Source, Dest: PAVFrame;
  Row: PByte;
  X, Y, C, I: Integer;
  Bytes: TBytes;
  PixelOffset, RowSize: Integer;
begin
  Source:=av_frame_alloc;
  Dest:=nil;

  try
    Check(Assigned(Source), 'source allocation failed');

    Source.width:=2;
    Source.height:=2;
    Source.format:=Ord(AV_PIX_FMT_BGR24);
    Source.pts:=123;
    Source.duration:=40;
    Check(av_frame_get_buffer(Source, 32) = 0, 'source buffer allocation failed');

    for Y:=0 to 1 do
      for X:=0 to 1 do
        for C:=0 to 2 do
          Source.data[0][Y * Source.linesize[0] + X * 3 + C]:=COLORS[Y * 2 + X, C];

    for I:=1 to 100 do
    begin
      Check(TFFmpegVideoScaler.Scale(Source, 4, 4, AV_PIX_FMT_BGR24, Dest, SWS_POINT) = 0, 'scaling failed');

      try
        Check((Dest.width = 4) AND (Dest.height = 4) AND (Dest.pts = 123) AND (Dest.duration = 40), 'frame metadata mismatch');
        for Y:=0 to 3 do
        begin
          Row:=Dest.data[0] + Y * Dest.linesize[0];
          for X:=0 to 3 do
            for C:=0 to 2 do
              Check(Row[X * 3 + C] = COLORS[(Y DIV 2) * 2 + X DIV 2, C], 'nearest-neighbor color/orientation mismatch');
        end;

        Dest.data[0][2]:=0;
        Check(Source.data[0][2] = 255, 'destination aliases source pixels');
      finally
        av_frame_free(@Dest);
      end;
    end;

    Check((TFFmpegVideoScaler.Scale(nil, 2, 2, AV_PIX_FMT_BGR24, Dest) = AVERROR_EINVAL) AND NOT Assigned(Dest), 'nil source was not rejected');
    Check((TFFmpegVideoScaler.Scale(Source, 0, 2, AV_PIX_FMT_BGR24, Dest) = AVERROR_EINVAL) AND NOT Assigned(Dest), 'empty destination was not rejected');
    Check((TFFmpegVideoScaler.Scale(Source, High(Integer), High(Integer), AV_PIX_FMT_BGR24, Dest) = AVERROR_EINVAL) AND
      NOT Assigned(Dest), 'unbounded destination was not rejected');
    Check((TFFmpegVideoScaler.Scale(Source, 1, 10000000, AV_PIX_FMT_BGRA, Dest) < 0) AND
      NOT Assigned(Dest), 'native stride/dimension padding exceeded the storage limit');

    Check(TFFmpegVideoScaler.Scale(Source, 2, 2, AV_PIX_FMT_BGRA, Dest) = 0, 'same-size format conversion failed');
    Check((Dest.data[0][2] = 255) AND (Dest.data[0][3] = 255), 'RGB conversion/opaque alpha mismatch');

    Check(TFFmpegStillImage.EncodeBMP(Source, 2, 2, Bytes) = 0, 'BMP encoding failed');
    Check((Length(Bytes) >= 70) AND (Bytes[0] = Ord('B')) AND (Bytes[1] = Ord('M')) AND (PInteger(@Bytes[18])^ = 2) AND (PInteger(@Bytes[22])^ = 2) AND
      (PWord(@Bytes[28])^ = 24) AND (PInteger(@Bytes[30])^ = 0), 'independent BMP header mismatch');

    PixelOffset:=PInteger(@Bytes[10])^;
    RowSize:=8;
    Check((PixelOffset >= 54) AND (PixelOffset + RowSize * 2 = Length(Bytes)), 'BMP row padding or size mismatch');

    for Y:=0 to 1 do
      for X:=0 to 1 do
        for C:=0 to 2 do
          Check(Bytes[PixelOffset + (1 - Y) * RowSize + X * 3 + C] = COLORS[Y * 2 + X, C], 'BMP colors/orientation mismatch');

    Dest.data[0][3]:=128;
    Check(TFFmpegStillImage.EncodeBMP(Dest, 2, 2, Bytes, $0000FF) = 0, 'alpha flattening failed');

    PixelOffset:=PInteger(@Bytes[10])^;
    Check((Bytes[PixelOffset + RowSize] = 127) AND (Bytes[PixelOffset + RowSize + 1] = 0) AND
      (Bytes[PixelOffset + RowSize + 2] = 128), 'alpha is not composited onto the requested RGB background');
  finally
    av_frame_free(@Dest);
    av_frame_free(@Source);
  end;
end;

begin
  try
    Run;
    WriteLn('Native video scaler pixels, ownership, bounds and repeated calls passed.');
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      ExitCode:=1;
    end;
  end;
end.
