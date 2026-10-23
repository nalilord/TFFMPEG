unit TFFmpeg.Input;

interface

uses
  libavcodec_codec,
  libavcodec_codec_par,
  libavcodec_packet,
  libavformat,
  libavformat_avio,
  libavutil,
  libavutil_dict;

type
  { Owns the format context; stream and codec pointers are borrowed.
    Options remain caller-owned (FFmpeg consumes recognized entries).
    One instance per worker; do not read/close it concurrently. }
  TFFmpegInput = class
  private
    FFormatContext: PAVFormatContext;
    FStreamIndex: Integer;
    FCodec: PAVCodec;
    FFileIO: PAVIOContext;
  public
    constructor Create;
    destructor Destroy; override;
    function Open(const URL: string; var Options: PAVDictionary;
      MediaType: TAVMediaType = AVMEDIA_TYPE_AUDIO): Integer;
    // Opens one literal local filename, avoiding URL/image-sequence inference.
    // The caller can restrict demuxers through format_whitelist in Options.
    function OpenFile(const AFilename: string; var AOptions: PAVDictionary;
      const AInterrupt: TAVIOInterruptCB; AMediaType: TAVMediaType = AVMEDIA_TYPE_AUDIO): Integer;
    procedure Close;
    function ReadPacket(Packet: PAVPacket): Integer;
    function SelectedStream: PAVStream;
    function CodecParameters: PAVCodecParameters;
    property FormatContext: PAVFormatContext read FFormatContext;
    property StreamIndex: Integer read FStreamIndex;
    property Codec: PAVCodec read FCodec;
  end;

implementation

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  libavutil_error,
  TFFmpeg.Api,
  TFFmpeg.Utils;

constructor TFFmpegInput.Create;
begin
  inherited Create;
  FStreamIndex := -1;
end;

destructor TFFmpegInput.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TFFmpegInput.Close;
begin
  if Assigned(FFormatContext) then
    TFFmpegApi.CloseInput(FFormatContext);
  avio_closep(@FFileIO);
  FStreamIndex := -1;
  FCodec := nil;
end;

function TFFmpegInput.OpenFile(const AFilename: string; var AOptions: PAVDictionary;
  const AInterrupt: TAVIOInterruptCB; AMediaType: TAVMediaType): Integer;
var
  Filename: UTF8String;
begin
  Close;
  Result:=AVERROR_ENOENT;
  if NOT FileExists(AFilename) then
    Exit;
  Filename:=StringToUTF8String(ExpandFileName(AFilename));
  FFormatContext:=avformat_alloc_context;
  if NOT Assigned(FFormatContext) then
    Exit(AVERROR_ENOMEM);
  FFormatContext.interrupt_callback:=AInterrupt;
  FFormatContext.max_streams:=256;
  Result:=av_dict_set(@AOptions, 'protocol_whitelist', 'file', 0);
  if Result >= 0 then
    Result:=avio_open2(@FFileIO, PAnsiChar(Filename), AVIO_FLAG_READ, @FFormatContext.interrupt_callback, @AOptions);
  if Result >= 0 then
  begin
    FFormatContext.pb:=FFileIO;
    FFormatContext.flags:=FFormatContext.flags OR AVFMT_FLAG_CUSTOM_IO;
    // avio_open2 may consume its options; retain the same protocol restriction
    // at the demuxer boundary for any secondary I/O it attempts.
    Result:=av_dict_set(@AOptions, 'protocol_whitelist', 'file', 0);
    if Result >= 0 then
      Result:=avformat_open_input(@FFormatContext, nil, nil, @AOptions);
  end;
  if Result >= 0 then
    Result:=avformat_find_stream_info(FFormatContext, nil);
  if Result >= 0 then
  begin
    Result:=av_find_best_stream(FFormatContext, AMediaType, -1, -1, @FCodec, 0);
    if Result >= 0 then
      FStreamIndex:=Result;
  end;
  if Result < 0 then
    Close
  else
    Result:=0;
end;

function TFFmpegInput.Open(const URL: string; var Options: PAVDictionary;
  MediaType: TAVMediaType): Integer;
begin
  Close;
  Result := TFFmpegApi.OpenInput(FFormatContext, StringToUTF8String(URL), Options);
  if Result >= 0 then
    Result := TFFmpegApi.FindStreamInfo(FFormatContext);
  if Result >= 0 then
  begin
    Result := av_find_best_stream(FFormatContext, MediaType, -1, -1, @FCodec, 0);
    if Result >= 0 then
      FStreamIndex := Result;
  end;
  if Result < 0 then
    Close
  else
    Result := 0;
end;

function TFFmpegInput.ReadPacket(Packet: PAVPacket): Integer;
begin
  if not Assigned(FFormatContext) then
    Exit(AVERROR_EINVAL);
  Result := TFFmpegApi.ReadFrame(FFormatContext, Packet);
end;

function TFFmpegInput.SelectedStream: PAVStream;
begin
  if Assigned(FFormatContext) and (FStreamIndex >= 0) then
    Result := PPtrIdx(FFormatContext^.streams, FStreamIndex)
  else
    Result := nil;
end;

function TFFmpegInput.CodecParameters: PAVCodecParameters;
var
  Stream: PAVStream;
begin
  Stream := SelectedStream;
  if Assigned(Stream) then
    Result := Stream^.codecpar
  else
    Result := nil;
end;

end.
