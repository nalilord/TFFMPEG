unit TFFmpeg.Input;

interface

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
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
    FMemoryIO: PAVIOContext;
    FBytes: TBytes;
    FBytePosition: Int64;
    FMemoryInterrupt: TAVIOInterruptCB;
    function OpenFileInput(const AFilename: String; var AOptions: PAVDictionary; const AInterrupt: TAVIOInterruptCB;
      AMediaType: TAVMediaType; ASelectStream: Boolean): Integer;
    function OpenBytesInput(const ABytes: TBytes; var AOptions: PAVDictionary; const AInterrupt: TAVIOInterruptCB;
      AMediaType: TAVMediaType; ASelectStream: Boolean): Integer;
  public
    constructor Create;
    destructor Destroy; override;
    function Open(const URL: String; var Options: PAVDictionary; MediaType: TAVMediaType = AVMEDIA_TYPE_AUDIO): Integer;
    // Opens one literal local filename, avoiding URL/image-sequence inference.
    // The caller can restrict demuxers through format_whitelist in Options.
    function OpenFile(const AFilename: String; var AOptions: PAVDictionary;
      const AInterrupt: TAVIOInterruptCB; AMediaType: TAVMediaType = AVMEDIA_TYPE_AUDIO): Integer;
    // Copies bytes into owned, seekable input. Secondary protocol I/O is disabled.
    function OpenBytes(const ABytes: TBytes; var AOptions: PAVDictionary;
      const AInterrupt: TAVIOInterruptCB; AMediaType: TAVMediaType = AVMEDIA_TYPE_AUDIO): Integer;
    // Probe without selecting an application decoder; all stream pointers remain borrowed.
    function ProbeFile(const AFilename: String; var AOptions: PAVDictionary; const AInterrupt: TAVIOInterruptCB): Integer;
    function ProbeBytes(const ABytes: TBytes; var AOptions: PAVDictionary; const AInterrupt: TAVIOInterruptCB): Integer;
    // Explicit URL/protocol input, without application stream selection. TLS
    // verification defaults on; an explicit tls_verify option must be 0 or 1.
    function ProbeURL(const AURL: String; var AOptions: PAVDictionary; const AInterrupt: TAVIOInterruptCB;
      const AProtocols: String = 'http,https,tcp,tls'): Integer;
    // The caller registers its device backend and owns the COM apartment.
    // NONBLOCK avoids DirectShow's uninterruptible empty-packet wait; callers
    // must retry EAGAIN while checking their cancellation/deadline state.
    function ProbeDevice(const ADeviceName, AFormatName: String; var AOptions: PAVDictionary;
      const AInterrupt: TAVIOInterruptCB): Integer;
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
  libavutil_error,
  libavutil_mem,
  TFFmpeg.Api,
  TFFmpeg.Utils;

constructor TFFmpegInput.Create;
begin
  inherited Create;
  FStreamIndex:=-1;
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

  if Assigned(FMemoryIO) then
  begin
    av_freep(@FMemoryIO.buffer);
    avio_context_free(@FMemoryIO);
  end;

  FBytes:=nil;
  FBytePosition:=0;
  FMemoryInterrupt:=Default(TAVIOInterruptCB);
  FStreamIndex:=-1;
  FCodec:=nil;
end;

function ReadMemory(AOpaque: Pointer; ABuffer: PByte; ASize: Integer): Integer; cdecl;
var
  Input: TFFmpegInput;
  Count: Int64;
begin
  Result:=AVERROR_EIO;

  try
    Input:=TFFmpegInput(AOpaque);
    if Assigned(Input.FMemoryInterrupt.callback) AND (Input.FMemoryInterrupt.callback(Input.FMemoryInterrupt.opaque) <> 0) then
      Exit(AVERROR_EXIT);
    if (ASize <= 0) OR NOT Assigned(ABuffer) then
      Exit(AVERROR_EINVAL);

    Count:=Length(Input.FBytes) - Input.FBytePosition;
    if Count <= 0 then
      Exit(AVERROR_EOF);
    if Count > ASize then
      Count:=ASize;

    Move(Input.FBytes[Integer(Input.FBytePosition)], ABuffer^, Integer(Count));
    Inc(Input.FBytePosition, Count);

    Result:=Integer(Count);
  except
    // Exceptions must never cross FFmpeg's C callback boundary.
    Result:=AVERROR_EIO;
  end;
end;

function SeekMemory(AOpaque: Pointer; AOffset: Int64; AWhence: Integer): Int64; cdecl;
var
  Input: TFFmpegInput;
  Base, Target: Int64;
begin
  Result:=AVERROR_EINVAL;

  try
    Input:=TFFmpegInput(AOpaque);
    if AWhence = AVSEEK_SIZE then
      Exit(Length(Input.FBytes));

    case AWhence AND NOT AVSEEK_FORCE of
      0: Base:=0;
      1: Base:=Input.FBytePosition;
      2: Base:=Length(Input.FBytes);
      else Exit;
    end;

    if (AOffset < -Base) OR (AOffset > Int64(Length(Input.FBytes)) - Base) then
      Exit;

    Target:=Base + AOffset;
    Input.FBytePosition:=Target;

    Result:=Target;
  except
    Result:=AVERROR_EIO;
  end;
end;

function TFFmpegInput.OpenBytes(const ABytes: TBytes; var AOptions: PAVDictionary; const AInterrupt: TAVIOInterruptCB; AMediaType: TAVMediaType): Integer;
begin
  Result:=OpenBytesInput(ABytes, AOptions, AInterrupt, AMediaType, True);
end;

function TFFmpegInput.ProbeBytes(const ABytes: TBytes; var AOptions: PAVDictionary; const AInterrupt: TAVIOInterruptCB): Integer;
begin
  Result:=OpenBytesInput(ABytes, AOptions, AInterrupt, AVMEDIA_TYPE_UNKNOWN, False);
end;

function TFFmpegInput.OpenBytesInput(const ABytes: TBytes; var AOptions: PAVDictionary; const AInterrupt: TAVIOInterruptCB;
  AMediaType: TAVMediaType; ASelectStream: Boolean): Integer;
var
  Buffer: PByte;
begin
  Close;
  Result:=AVERROR_EINVAL;
  if (Length(ABytes) = 0) OR (Length(ABytes) > High(Integer)) then
    Exit;

  FBytes:=Copy(ABytes);
  FMemoryInterrupt:=AInterrupt;

  FFormatContext:=avformat_alloc_context;
  if NOT Assigned(FFormatContext) then
  begin
    Close;
    Exit(AVERROR_ENOMEM);
  end;

  Buffer:=av_malloc(32768);
  if Assigned(Buffer) then
  begin
    FMemoryIO:=avio_alloc_context(Buffer, 32768, 0, Self, ReadMemory, nil, SeekMemory);
    if NOT Assigned(FMemoryIO) then
      av_free(Buffer);
  end;
  if NOT Assigned(FMemoryIO) then
  begin
    Close;
    Exit(AVERROR_ENOMEM);
  end;

  FFormatContext.pb:=FMemoryIO;
  FFormatContext.flags:=FFormatContext.flags OR AVFMT_FLAG_CUSTOM_IO;
  FFormatContext.interrupt_callback:=AInterrupt;
  FFormatContext.max_streams:=256;

  // A demuxer must not resolve references outside these captured bytes.
  Result:=av_dict_set(@AOptions, 'protocol_whitelist', '', 0);
  if Result >= 0 then
    Result:=avformat_open_input(@FFormatContext, nil, nil, @AOptions);

  if Result >= 0 then
    Result:=avformat_find_stream_info(FFormatContext, nil);

  if (Result >= 0) AND ASelectStream then
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

function TFFmpegInput.OpenFile(const AFilename: String; var AOptions: PAVDictionary; const AInterrupt: TAVIOInterruptCB; AMediaType: TAVMediaType): Integer;
begin
  Result:=OpenFileInput(AFilename, AOptions, AInterrupt, AMediaType, True);
end;

function TFFmpegInput.ProbeFile(const AFilename: String; var AOptions: PAVDictionary; const AInterrupt: TAVIOInterruptCB): Integer;
begin
  Result:=OpenFileInput(AFilename, AOptions, AInterrupt, AVMEDIA_TYPE_UNKNOWN, False);
end;

function TFFmpegInput.OpenFileInput(const AFilename: String; var AOptions: PAVDictionary; const AInterrupt: TAVIOInterruptCB;
  AMediaType: TAVMediaType; ASelectStream: Boolean): Integer;
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

  if (Result >= 0) AND ASelectStream then
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

function TFFmpegInput.Open(const URL: String; var Options: PAVDictionary; MediaType: TAVMediaType): Integer;
begin
  Close;

  Result:=TFFmpegApi.OpenInput(FFormatContext, StringToUTF8String(URL), Options);
  if Result >= 0 then
    Result:=TFFmpegApi.FindStreamInfo(FFormatContext);

  if Result >= 0 then
  begin
    Result:=av_find_best_stream(FFormatContext, MediaType, -1, -1, @FCodec, 0);
    if Result >= 0 then
      FStreamIndex:=Result;
  end;

  if Result < 0 then
    Close
  else
    Result:=0;
end;

function TFFmpegInput.ProbeURL(const AURL: String; var AOptions: PAVDictionary; const AInterrupt: TAVIOInterruptCB;
  const AProtocols: String): Integer;
var
  URL, Protocols, Verify: UTF8String;
  Entry: PAVDictionaryEntry;
begin
  Result:=AVERROR_EINVAL;
  Close;
  if (AURL = '') OR (AProtocols = '') OR (Pos(#0, AURL) > 0) OR (Pos(#0, AProtocols) > 0) then
    Exit;
  Entry:=av_dict_get(AOptions, 'tls_verify', nil, 0);
  if Assigned(Entry) AND (String(Entry.value) <> '0') AND (String(Entry.value) <> '1') then
    Exit;
  Verify:='1';
  if Assigned(Entry) then
    Verify:=UTF8String(Entry.value);
  URL:=StringToUTF8String(AURL);
  Protocols:=StringToUTF8String(AProtocols);
  FFormatContext:=avformat_alloc_context;
  if NOT Assigned(FFormatContext) then
    Exit(AVERROR_ENOMEM);
  FFormatContext.interrupt_callback:=AInterrupt;
  FFormatContext.max_streams:=256;
  Result:=av_dict_set(@AOptions, 'protocol_whitelist', PAnsiChar(Protocols), 0);
  if Result >= 0 then
  begin
    // Canonicalize the policy key before native AVOption matching (case-sensitive).
    av_dict_set(@AOptions, 'tls_verify', nil, 0);
    Result:=av_dict_set(@AOptions, 'tls_verify', PAnsiChar(Verify), 0);
  end;
  if Result >= 0 then
    Result:=avformat_open_input(@FFormatContext, PAnsiChar(URL), nil, @AOptions);
  // HTTP retains options for a possible HTTPS redirect. Plain HTTP may leave
  // this validated policy option unconsumed; it is owned/consumed by this wrapper.
  av_dict_set(@AOptions, 'tls_verify', nil, 0);
  if Result >= 0 then
    Result:=avformat_find_stream_info(FFormatContext, nil);
  if Result < 0 then
    Close
  else
    Result:=0;
end;

function TFFmpegInput.ProbeDevice(const ADeviceName, AFormatName: String; var AOptions: PAVDictionary;
  const AInterrupt: TAVIOInterruptCB): Integer;
var
  DeviceName, FormatName: UTF8String;
  InputFormat: PAVInputFormat;
begin
  Result:=AVERROR_EINVAL;
  Close;
  if (ADeviceName = '') OR (AFormatName = '') OR (Pos(#0, ADeviceName) > 0) OR (Pos(#0, AFormatName) > 0) then
    Exit;
  DeviceName:=StringToUTF8String(ADeviceName);
  FormatName:=StringToUTF8String(AFormatName);
  InputFormat:=av_find_input_format(PAnsiChar(FormatName));
  if NOT Assigned(InputFormat) then
    Exit(AVERROR_ENOSYS);
  FFormatContext:=avformat_alloc_context;
  if NOT Assigned(FFormatContext) then
    Exit(AVERROR_ENOMEM);
  FFormatContext.interrupt_callback:=AInterrupt;
  FFormatContext.max_streams:=2;
  FFormatContext.flags:=FFormatContext.flags OR AVFMT_FLAG_NONBLOCK;
  Result:=avformat_open_input(@FFormatContext, PAnsiChar(DeviceName), InputFormat, @AOptions);
  if Result >= 0 then
  begin
    FFormatContext.flags:=FFormatContext.flags OR AVFMT_FLAG_NONBLOCK;
    Result:=avformat_find_stream_info(FFormatContext, nil);
  end;
  if Result < 0 then
    Close
  else
    Result:=0;
end;

function TFFmpegInput.ReadPacket(Packet: PAVPacket): Integer;
begin
  if NOT Assigned(FFormatContext) then
    Exit(AVERROR_EINVAL);

  Result:=TFFmpegApi.ReadFrame(FFormatContext, Packet);
end;

function TFFmpegInput.SelectedStream: PAVStream;
begin
  if Assigned(FFormatContext) AND (FStreamIndex >= 0) then
    Result:=PPtrIdx(FFormatContext^.streams, FStreamIndex)
  else
    Result:=nil;
end;

function TFFmpegInput.CodecParameters: PAVCodecParameters;
var
  Stream: PAVStream;
begin
  Stream:=SelectedStream;
  if Assigned(Stream) then
    Result:=Stream^.codecpar
  else
    Result:=nil;
end;

end.
