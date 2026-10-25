program FFmpegAPISmoke;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  libavcodec, libavcodec_codec, libavcodec_codec_id,
  libavformat, libavutil, libavutil_pixfmt,
  libavfilter, libavdevice, libswscale, libswresample;

procedure Require(Value: Boolean; const MessageText: String);
begin
  if NOT Value then
    raise Exception.Create(MessageText);
end;

procedure Run;
var
  Graph: PAVFilterGraph;
  Filter: PAVFilterContext;
  Format, CopyFormat: PAVFormatContext;
  ProgramInfo: PAVProgram;
  Scaler: PSwsContext;
  SourcePixels, DestPixels: Array[0..63] of Byte;
  SourcePlanes, DestPlanes: Array[0..3] of PByte;
  SourceStrides, DestStrides: Array[0..3] of Integer;
  I: Integer;
begin
  Require(avcodec_version = LIBAVCODEC_VERSION_INT, 'avcodec version');
  Require(avformat_version = LIBAVFORMAT_VERSION_INT, 'avformat version');
  Require(avutil_version = LIBAVUTIL_VERSION_INT, 'avutil version');
  Require(avfilter_version = LIBAVFILTER_VERSION_INT, 'avfilter version');
  Require(avdevice_version = LIBAVDEVICE_VERSION_INT, 'avdevice version');
  Require(swscale_version = LIBSWSCALE_VERSION_INT, 'swscale version');
  Require(swresample_version = LIBSWRESAMPLE_VERSION_INT, 'swresample version');

  Require(avcodec_find_decoder(AV_CODEC_ID_WEBP_ANIM) <> nil, 'New codec ID lookup');
  Require(String(AnsiString(avcodec_find_decoder(AV_CODEC_ID_HEVC).name)) = 'hevc', 'Shifted codec ID lookup');

  Graph:=avfilter_graph_alloc;
  Require(Graph <> nil, 'Filter graph allocation');

  try
    Filter:=nil;
    Require(avfilter_graph_create_filter(@Filter, avfilter_get_by_name('anull'), 'pass', nil, nil, Graph) >= 0, 'Create audio filter');
    Require((Graph.nb_filters = 1) AND (Filter.filter <> nil), 'Filter graph records');
  finally
    avfilter_graph_free(@Graph);
  end;

  Format:=avformat_alloc_context;
  CopyFormat:=avformat_alloc_context;

  try
    Require((Format <> nil) AND (CopyFormat <> nil), 'Format allocation');
    Require(avformat_new_stream(Format, nil) <> nil, 'Source stream');
    Require(avformat_new_stream(CopyFormat, nil) <> nil, 'Target stream');

    ProgramInfo:=av_new_program(Format, 42);
    Require(ProgramInfo <> nil, 'Program allocation');
    Require(av_program_add_stream_index2(Format, 42, 0) = 0, 'Add program stream');
    Require(ProgramInfo.nb_stream_indexes = 1, 'Program stream count');
    Require(av_program_copy(CopyFormat, Format, 42, AVFMT_PROGCOPY_MATCH_BY_INDEX) >= 0, 'Copy program');
    Require(CopyFormat.nb_programs = 1, 'Copied program count');
  finally
    avformat_free_context(CopyFormat);
    avformat_free_context(Format);
  end;

  Require(sws_getCoefficients(SWS_CS_ITU709) <> nil, 'Coefficient pointer');

  FillChar(SourcePlanes, SizeOf(SourcePlanes), 0);
  FillChar(DestPlanes, SizeOf(DestPlanes), 0);
  FillChar(SourceStrides, SizeOf(SourceStrides), 0);
  FillChar(DestStrides, SizeOf(DestStrides), 0);
  FillChar(SourcePixels, SizeOf(SourcePixels), 0);
  FillChar(DestPixels, SizeOf(DestPixels), 0);

  for I:=0 to 3 do
    SourcePixels[I * 3]:=255;
  SourcePlanes[0]:=@SourcePixels[0];
  DestPlanes[0]:=@DestPixels[0];
  SourceStrides[0]:=6;
  DestStrides[0]:=6;

  Scaler:=sws_getContext(2, 2, AV_PIX_FMT_RGB24, 2, 2, AV_PIX_FMT_BGR24, SWS_POINT, nil, nil, nil);
  Require(Scaler <> nil, 'Scaler allocation');

  try
    Require(sws_scale(Scaler, @SourcePlanes[0], @SourceStrides[0], 0, 2, @DestPlanes[0], @DestStrides[0]) = 2, 'RGB to BGR conversion');
    for I:=0 to 3 do
      Require((DestPixels[I * 3] = 0) AND (DestPixels[I * 3 + 1] = 0) AND (DestPixels[I * 3 + 2] = 255), 'Converted pixel');
  finally
    sws_freeContext(Scaler);
  end;

  WriteLn('PASS: seven runtime versions, codec IDs, filters, program APIs, RGB conversion');
end;

begin
  try
    Run;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      ExitCode:=1;
    end;
  end;
end.
