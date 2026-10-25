unit TFFmpeg.Output;

interface

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  libavcodec,
  libavcodec_packet,
  libavformat,
  libavformat_avio,
  libavutil_dict,
  libavutil_rational;

type
  // Thread-confined file muxer. Owns format/IO and a reusable packet reference.
  // Context/stream pointers are borrowed. Close/destruction abort without trailer.
  // Callers configure global headers before encoder open, then add opened codecs.
  TFFmpegOutput = class
  private
    FFormatContext: PAVFormatContext;
    FFilename: UTF8String;
    FEncoderTimeBases: Array of TAVRational;
    FPacket: PAVPacket;
    FHeaderWritten: Boolean;
    FFinished: Boolean;
    FFailed: Boolean;
    function GetRequiresGlobalHeader: Boolean;
  public
    destructor Destroy; override;
    function Allocate(const AMuxerName, AFilename: String): Integer;
    function AddStream(ACodecContext: PAVCodecContext; out AStreamIndex: Integer): Integer;
    // AOptions remains caller-owned; native code consumes recognized entries.
    // Interrupt state is borrowed until Close or successful Finish closes IO.
    function WriteHeader(var AOptions: PAVDictionary; const AInterrupt: TAVIOInterruptCB): Integer;
    // Borrows APacket. Retains/rescales a private reference, preserving caller data,
    // PTS and DTS. Native interleaving consumes only the private packet reference.
    function WritePacket(APacket: PAVPacket; AStreamIndex: Integer): Integer;
    function Finish: Integer;
    procedure Close;
    property FormatContext: PAVFormatContext read FFormatContext;
    property RequiresGlobalHeader: Boolean read GetRequiresGlobalHeader;
    property HeaderWritten: Boolean read FHeaderWritten;
    property Finished: Boolean read FFinished;
    property Failed: Boolean read FFailed;
  end;

implementation

uses
  libavcodec_codec_par,
  libavutil_error,
  TFFmpeg.Utils;

destructor TFFmpegOutput.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TFFmpegOutput.Close;
begin
  if Assigned(FFormatContext) then
  begin
    avio_closep(@FFormatContext.pb);
    avformat_free_context(FFormatContext);
    FFormatContext:=nil;
  end;
  av_packet_free(@FPacket);
  FEncoderTimeBases:=nil;
  FFilename:='';
  FHeaderWritten:=False;
  FFinished:=False;
  FFailed:=False;
end;

function TFFmpegOutput.GetRequiresGlobalHeader: Boolean;
begin
  Result:=False;
  if Assigned(FFormatContext) AND Assigned(FFormatContext.oformat) then
    Result:=(FFormatContext.oformat.flags AND AVFMT_GLOBALHEADER) <> 0;
end;

function TFFmpegOutput.Allocate(const AMuxerName, AFilename: String): Integer;
var
  Name: UTF8String;
begin
  Result:=AVERROR_EINVAL;
  Close;
  if (AMuxerName = '') OR (AFilename = '') OR (Pos(#0, AMuxerName) > 0) OR (Pos(#0, AFilename) > 0) then
    Exit;
  Name:=StringToUTF8String(AMuxerName);
  FFilename:=StringToUTF8String(ExpandFileName(AFilename));
  Result:=avformat_alloc_output_context2(@FFormatContext, nil, PAnsiChar(Name), PAnsiChar(FFilename));
  if (Result >= 0) AND NOT Assigned(FFormatContext) then
    Result:=AVERROR_ENOMEM;
  if Result >= 0 then
    if NOT Assigned(FFormatContext.oformat) OR ((FFormatContext.oformat.flags AND AVFMT_NOFILE) <> 0) then
      Result:=AVERROR_EINVAL;
  if Result >= 0 then
  begin
    // Bound interleaving by media time instead of waiting indefinitely for a
    // shorter stream. High-level writers separately bound samples and packets.
    FFormatContext.max_interleave_delta:=1000000;
    FPacket:=av_packet_alloc;
    if NOT Assigned(FPacket) then
      Result:=AVERROR_ENOMEM;
  end;
  if Result < 0 then
    Close;
end;

function TFFmpegOutput.AddStream(ACodecContext: PAVCodecContext; out AStreamIndex: Integer): Integer;
var
  Stream: PAVStream;
begin
  Result:=AVERROR_EINVAL;
  AStreamIndex:=-1;
  if NOT Assigned(FFormatContext) OR NOT Assigned(ACodecContext) OR FHeaderWritten OR FFinished OR FFailed OR
    (ACodecContext.time_base.num <= 0) OR (ACodecContext.time_base.den <= 0) OR (FFormatContext.nb_streams >= 256) then
    Exit;
  if avformat_query_codec(FFormatContext.oformat, ACodecContext.codec_id, 0) = 0 then
    Exit;
  Stream:=avformat_new_stream(FFormatContext, nil);
  if NOT Assigned(Stream) then
    Exit(AVERROR_ENOMEM);
  Result:=avcodec_parameters_from_context(Stream.codecpar, ACodecContext);
  if Result < 0 then
  begin
    FFailed:=True;
    Exit;
  end;
  Stream.time_base:=ACodecContext.time_base;
  Stream.avg_frame_rate:=ACodecContext.framerate;
  SetLength(FEncoderTimeBases, FFormatContext.nb_streams);
  FEncoderTimeBases[Stream.index]:=ACodecContext.time_base;
  AStreamIndex:=Stream.index;
  Result:=0;
end;

function TFFmpegOutput.WriteHeader(var AOptions: PAVDictionary; const AInterrupt: TAVIOInterruptCB): Integer;
var
  IOOptions: PAVDictionary;
begin
  Result:=AVERROR_EINVAL;
  if NOT Assigned(FFormatContext) OR FHeaderWritten OR FFinished OR FFailed OR (FFormatContext.nb_streams = 0) then
    Exit;
  FFormatContext.interrupt_callback:=AInterrupt;
  IOOptions:=nil;
  try
    Result:=av_dict_set(@IOOptions, 'protocol_whitelist', 'file', 0);
    if Result >= 0 then
      Result:=avio_open2(@FFormatContext.pb, PAnsiChar(FFilename), AVIO_FLAG_WRITE, @FFormatContext.interrupt_callback, @IOOptions);
    if Result >= 0 then
      Result:=avformat_write_header(FFormatContext, @AOptions);
    if (Result >= 0) AND Assigned(FFormatContext.pb) AND (FFormatContext.pb.error < 0) then
      Result:=FFormatContext.pb.error;
    FHeaderWritten:=Result >= 0;
    FFailed:=Result < 0;
  finally
    av_dict_free(@IOOptions);
  end;
end;

function TFFmpegOutput.WritePacket(APacket: PAVPacket; AStreamIndex: Integer): Integer;
var
  Stream: PAVStream;
begin
  Result:=AVERROR_EINVAL;
  if NOT FHeaderWritten OR FFinished OR FFailed OR NOT Assigned(FFormatContext) OR NOT Assigned(APacket) OR
    (AStreamIndex < 0) OR (AStreamIndex >= Length(FEncoderTimeBases)) then
    Exit;
  Stream:=PPtrIdx(FFormatContext.streams, AStreamIndex);
  av_packet_unref(FPacket);
  Result:=av_packet_ref(FPacket, APacket);
  if Result < 0 then
  begin
    FFailed:=True;
    Exit;
  end;
  try
    FPacket.stream_index:=AStreamIndex;
    FPacket.pos:=-1;
    // Header creation may renegotiate stream.time_base. Always read it here;
    // never manufacture DTS from PTS or discard valid encoder delay/reordering.
    av_packet_rescale_ts(FPacket, FEncoderTimeBases[AStreamIndex], Stream.time_base);
    Result:=av_interleaved_write_frame(FFormatContext, FPacket);
    if (Result >= 0) AND Assigned(FFormatContext.pb) AND (FFormatContext.pb.error < 0) then
      Result:=FFormatContext.pb.error;
    if Result < 0 then
      FFailed:=True;
  finally
    av_packet_unref(FPacket);
  end;
end;

function TFFmpegOutput.Finish: Integer;
var
  IOCode, CloseCode: Integer;
begin
  Result:=AVERROR_EINVAL;
  if FFinished then
    Exit(0);
  if NOT Assigned(FFormatContext) OR NOT FHeaderWritten OR FFailed then
    Exit;
  Result:=av_write_trailer(FFormatContext);
  IOCode:=0;
  if Assigned(FFormatContext.pb) then
    IOCode:=FFormatContext.pb.error;
  CloseCode:=avio_closep(@FFormatContext.pb);
  if (Result >= 0) AND (IOCode < 0) then
    Result:=IOCode;
  if (Result >= 0) AND (CloseCode < 0) then
    Result:=CloseCode;
  FFinished:=Result >= 0;
  FFailed:=Result < 0;
end;

end.
