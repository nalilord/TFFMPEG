program FFmpegSmoke;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  cthreads, Classes, SysUtils,
{$ELSE}
  System.Classes, System.SysUtils, System.IOUtils,
{$ENDIF}
  libavcodec_packet,
  libavformat_avio,
  libavutil,
  libavutil_dict,
  libavutil_error,
  libavutil_frame,
  libavutil_samplefmt,
  TFFmpeg.Api,
  TFFmpeg.Utils,
  TFFmpeg.Input,
  TFFmpeg.Decoder,
  TFFmpeg.PCMReader,
  TFFmpeg.AudioResampler;

procedure Require(Value: Boolean; const MessageText: String);
begin
  if NOT Value then
    raise Exception.Create(MessageText);
end;

procedure Check(Code: Integer);
begin
  Require(Code >= 0, FFmpegErrorText(Code));
end;

procedure CreateWave(const FileName: String);
type
  TWaveHeader = packed record
    FRiff: Array[0..3] of AnsiChar;
    FRiffSize: Cardinal;
    FWave: Array[0..3] of AnsiChar;
    FFmt: Array[0..3] of AnsiChar;
    FFmtSize: Cardinal;
    FFormatTag: Word;
    FChannels: Word;
    FSampleRate: Cardinal;
    FByteRate: Cardinal;
    FBlockAlign: Word;
    FBitsPerSample: Word;
    FData: Array[0..3] of AnsiChar;
    FDataSize: Cardinal;
  end;
var
  Header: TWaveHeader;
  Samples: Array[0..2399] of SmallInt;
  I: Integer;
  Stream: TFileStream;
begin
  Header.FRiff:='RIFF';
  Header.FRiffSize:=36 + SizeOf(Samples);
  Header.FWave:='WAVE';
  Header.FFmt:='fmt ';
  Header.FFmtSize:=16;
  Header.FFormatTag:=1;
  Header.FChannels:=1;
  Header.FSampleRate:=24000;
  Header.FByteRate:=48000;
  Header.FBlockAlign:=2;
  Header.FBitsPerSample:=16;
  Header.FData:='data';
  Header.FDataSize:=SizeOf(Samples);

  for I:=0 to High(Samples) do
    Samples[I]:=Round(10000 * Sin(2 * Pi * 440 * I / 24000));

  Stream:=TFileStream.Create(FileName, fmCreate);

  try
    Stream.WriteBuffer(Header, SizeOf(Header));
    Stream.WriteBuffer(Samples, SizeOf(Samples));
  finally
    Stream.Free;
  end;
end;

procedure TestDecode(const FileName: String; AUseMemory: Boolean);
var
  Interrupt: TAVIOInterruptCB;
  Input: TFFmpegInput;
  Decoder: TFFmpegDecoder;
  Resampler: TFFmpegAudioResampler;
  Options: PAVDictionary;
  Packet: PAVPacket;
  Frame: PAVFrame;
  Code, ByteCount, TotalBytes, Frames: Integer;
  Buffer: PByte;
  HasSignal: Boolean;
  Bytes: TBytes;
  Signature: Array[0..3] of AnsiChar;
  Stream: TFileStream;
  Descriptor: UTF8String;

  procedure ConsumePCM;
  var
    I: Integer;
    Sample: PSmallInt;
  begin
    Require(ByteCount >= 0, 'Invalid PCM byte count');
    Require(ByteCount MOD 4 = 0, 'Partial stereo sample');
    Inc(TotalBytes, ByteCount);

    Sample:=PSmallInt(Buffer);
    for I:=1 to ByteCount DIV 2 do
    begin
      HasSignal:=HasSignal OR (Sample^ <> 0);
      Inc(Sample);
    end;
  end;

  procedure ReceiveFrames;
  var
    ReceiveCode: Integer;
  begin
    while True do
    begin
      ReceiveCode:=Decoder.ReceiveFrame(Frame);
      if (ReceiveCode = AVERROR_EAGAIN) OR (ReceiveCode = AVERROR_EOF) then
        Exit;
      Check(ReceiveCode);

      try
        Inc(Frames);
        Check(Resampler.ConvertFrame(Frame, Buffer, ByteCount));
        ConsumePCM;
      finally
        TFFmpegApi.UnrefFrame(Frame);
      end;
    end;
  end;

begin
  Input:=nil;
  Decoder:=nil;
  Resampler:=nil;
  Packet:=nil;
  Frame:=nil;
  Options:=nil;
  Interrupt:=Default(TAVIOInterruptCB);

  try
    Input:=TFFmpegInput.Create;
    Decoder:=TFFmpegDecoder.Create;
    Resampler:=TFFmpegAudioResampler.Create;
    Packet:=TFFmpegApi.AllocPacket;
    Frame:=TFFmpegApi.AllocFrame;
    Require((Packet <> nil) AND (Frame <> nil), 'Allocation failed');

    Require(Input.ReadPacket(Packet) = AVERROR_EINVAL, 'Closed input must reject reads');
    Require(Input.Open(FileName + '.missing', Options) < 0, 'Missing input must fail');
    Require(Input.FormatContext = nil, 'Failed open retained its context');
    Require(Input.Open(FileName, Options, AVMEDIA_TYPE_VIDEO) < 0, 'Audio-only file has no video');
    Require(Input.FormatContext = nil, 'Failed stream selection retained its context');

    Require(Input.OpenFile(FileName + '.missing', Options, Interrupt) < 0, 'Missing local input must fail');
    Require(Input.OpenFile(FileName, Options, Interrupt, AVMEDIA_TYPE_VIDEO) < 0, 'Failed local stream selection must fail');
    Require(Input.FormatContext = nil, 'Failed local open retained its context');

    if AUseMemory then
    begin
      Require(Input.OpenBytes(nil, Options, Interrupt) < 0, 'Empty memory input must fail');
      Bytes:=TBytes.Create(1, 2, 3, 4);
      Require(Input.OpenBytes(Bytes, Options, Interrupt) < 0, 'Malformed memory input must fail');
      Require(Input.FormatContext = nil, 'Failed memory open retained its context');

      Descriptor:=UTF8String('ffconcat version 1.0' + #10 + 'file ''file:' + StringReplace(FileName, '\', '/', [rfReplaceAll]) + '''' + #10);
      Stream:=TFileStream.Create(FileName + '.ffconcat', fmCreate);

      try
        Stream.WriteBuffer(Descriptor[1], Length(Descriptor));
      finally
        Stream.Free;
      end;

      try
        Check(av_dict_set(@Options, 'safe', '0', 0));
        Check(av_dict_set(@Options, 'format_whitelist', 'concat,wav', 0));
        Check(Input.OpenFile(FileName + '.ffconcat', Options, Interrupt));
        Input.Close;
        av_dict_free(@Options);

        SetLength(Bytes, Length(Descriptor));
        Move(Descriptor[1], Bytes[0], Length(Bytes));
        Check(av_dict_set(@Options, 'safe', '0', 0));
        Check(av_dict_set(@Options, 'format_whitelist', 'concat,wav', 0));
        Require(Input.OpenBytes(Bytes, Options, Interrupt) < 0, 'Memory input must reject secondary file references');
        Require(Input.FormatContext = nil, 'Rejected secondary I/O retained its context');
        av_dict_free(@Options);
        WriteLn('PASS: memory input rejects a secondary file reference accepted by file input');
      finally
        DeleteFile(FileName + '.ffconcat');
      end;

      Stream:=TFileStream.Create(FileName, fmOpenRead OR fmShareDenyWrite);

      try
        SetLength(Bytes, Integer(Stream.Size));
        Stream.ReadBuffer(Bytes, Length(Bytes));
      finally
        Stream.Free;
      end;

      Require(Input.OpenBytes(Bytes, Options, Interrupt, AVMEDIA_TYPE_VIDEO) < 0, 'Missing memory stream selection must fail');
      Check(Input.OpenBytes(Bytes, Options, Interrupt));
      FillChar(Bytes[0], Length(Bytes), 0);
      Bytes:=nil;
      Require(DeleteFile(FileName), 'Could not remove memory-input source fixture');
    end else
      Check(Input.OpenFile(FileName, Options, Interrupt));

    Require(Input.CodecParameters^.sample_rate = 24000, 'Wrong input sample rate');
    Require(Input.CodecParameters^.ch_layout.nb_channels = 1, 'Wrong input channels');

    Check(Decoder.Open(Input.Codec, Input.CodecParameters));
    Require(Resampler.OpenFromCodec(Decoder.CodecContext, 48000, 2, AV_SAMPLE_FMT_S16P) = AVERROR_EINVAL,
      'Planar output must be rejected by the interleaved wrapper');
    Check(Resampler.OpenFromCodec(Decoder.CodecContext, 48000, 2, AV_SAMPLE_FMT_S16));
    Require(Resampler.BytesPerSecond = 192000, 'Wrong output byte rate');

    TotalBytes:=0;
    Frames:=0;
    HasSignal:=False;

    while True do
    begin
      Code:=Input.ReadPacket(Packet);
      if Code = AVERROR_EOF then
        Break;
      Check(Code);

      try
        if Packet^.stream_index = Input.StreamIndex then
        begin
          Check(Decoder.SendPacket(Packet));
          ReceiveFrames;
        end;
      finally
        TFFmpegApi.UnrefPacket(Packet);
      end;
    end;

    Check(Decoder.SendPacket(nil));
    ReceiveFrames;

    repeat
      Check(Resampler.Flush(Buffer, ByteCount));
      ConsumePCM;
    until ByteCount = 0;

    Require(Buffer = nil, 'Drained output must not expose a stale buffer');
    Check(Resampler.Flush(Buffer, ByteCount));
    Require((ByteCount = 0) AND (Buffer = nil), 'Repeated flush must remain empty');
    Require(Frames > 0, 'No frames decoded');
    Require(TotalBytes = 19200, 'Expected 4800 stereo PCM16 samples after draining');
    Require(HasSignal, 'Decoded output is silent');

    if AUseMemory then
    begin
      Require(Input.FormatContext.pb.seek(Input.FormatContext.pb.opaque, High(Int64), 1) < 0, 'Overflowing memory seek must fail');
      Require(Input.FormatContext.pb.seek(Input.FormatContext.pb.opaque, Low(Int64), 2) < 0, 'Negative memory seek must fail');
      Require(Input.FormatContext.pb.seek(Input.FormatContext.pb.opaque, 0, 0) = 0, 'Memory seek to start failed');
      Require(Input.FormatContext.pb.read_packet(Input.FormatContext.pb.opaque, @Signature[0], 4) = 4, 'Memory read after seek failed');
      Require((Signature[0] = 'R') AND (Signature[1] = 'I') AND (Signature[2] = 'F') AND (Signature[3] = 'F'), 'Caller mutation changed owned memory input');
      Require(NOT FileExists(FileName), 'Memory decoder reopened or recreated its source');
      CreateWave(FileName);
      WriteLn('PASS: owned memory input survives caller mutation/source deletion and rejects invalid seeks');
    end;

    Input.Close;
    Input.Close;
    Require((Input.StreamIndex = -1) AND (Input.Codec = nil), 'Close did not clear state');
    Check(Input.Open(FileName, Options));
    Require(Input.SelectedStream <> nil, 'Reopen failed');
    WriteLn('PASS: input failures/reopen, decode/drain, 24 kHz mono -> 48 kHz stereo: ', TotalBytes, ' bytes');
  finally
    av_dict_free(@Options);
    TFFmpegApi.FreeFrame(Frame);
    TFFmpegApi.FreePacket(Packet);
    Resampler.Free;
    Decoder.Free;
    Input.Free;
  end;
end;

function CancelPCM(AOpaque: Pointer): Integer; cdecl;
begin
  Result:=Ord(PBoolean(AOpaque)^);
end;

procedure TestPCMReader(const AFilename: String);
var
  Reader: TFFmpegPCMReader;
  Source: TFileStream;
  Bytes, Chunk, SavedChunk: TBytes;
  Interrupt: TAVIOInterruptCB;
  Cancelled, HasSignal: Boolean;
  Code, Total, I: Integer;
  Sample: PSmallInt;
begin
  Source:=TFileStream.Create(AFilename, fmOpenRead OR fmShareDenyWrite);

  try
    SetLength(Bytes, Integer(Source.Size));
    Source.ReadBuffer(Bytes, Length(Bytes));
  finally
    Source.Free;
  end;

  Reader:=TFFmpegPCMReader.Create;
  Interrupt:=Default(TAVIOInterruptCB);
  Interrupt.callback:=CancelPCM;
  Interrupt.opaque:=@Cancelled;
  Cancelled:=False;

  try
    Require(Reader.Read(Chunk) = AVERROR_EINVAL, 'Closed PCM reader must reject reads');
    Require(Reader.OpenBytes(Bytes, 0, 2, Interrupt) < 0, 'Invalid PCM output format must fail');
    Check(Reader.OpenBytes(Bytes, 48000, 2, Interrupt));

    FillChar(Bytes[0], Length(Bytes), 0);
    Bytes:=nil;

    Total:=0;
    HasSignal:=False;

    repeat
      Code:=Reader.Read(Chunk);
      if Code = AVERROR_EOF then
        Break;
      Check(Code);
      Require((Length(Chunk) > 0) AND (Length(Chunk) MOD 4 = 0), 'PCM reader returned partial or empty stereo frames');
      Inc(Total, Length(Chunk));
      Sample:=PSmallInt(@Chunk[0]);
      for I:=1 to Length(Chunk) DIV 2 do
      begin
        HasSignal:=HasSignal OR (Abs(Integer(Sample^)) > 100);
        Inc(Sample);
      end;
      if Length(SavedChunk) = 0 then
        SavedChunk:=Chunk;
    until False;

    Require((Total = 19200) AND HasSignal, 'PCM reader lost samples, resampler tail or audio signal');
    Require((Reader.Read(Chunk) = AVERROR_EOF) AND (Length(Chunk) = 0), 'PCM reader drain must remain empty');
    Require(Length(SavedChunk) > 0, 'Owned PCM chunk was lost');

    Cancelled:=True;
    Require((Reader.Read(Chunk) = AVERROR_EXIT) AND (Length(Chunk) = 0), 'PCM cancellation must return no chunk');
    Require(Reader.OpenBytes(SavedChunk, 48000, 2, Interrupt) = AVERROR_EXIT, 'Cancelled PCM open must fail');
    Require(Reader.Read(Chunk) = AVERROR_EINVAL, 'Failed PCM open retained active state');

    Reader.Close;
    Reader.Close;
    WriteLn('PASS: PCM reader owns chunks, drains exact samples, resamples and cancels without stale output');
  finally
    Reader.Free;
  end;
end;

var
  FileName: String;
  Id: TGUID;
begin
  try
    Require(CreateGUID(Id) = 0, 'Could not create test filename');
{$IFDEF FPC}
    FileName:=IncludeTrailingPathDelimiter(GetTempDir);
{$ELSE}
    FileName:=IncludeTrailingPathDelimiter(TPath.GetTempPath);
{$ENDIF}
    FileName:=FileName + 'TFFmpeg-' + GUIDToString(Id) + '.wav';

    try
      CreateWave(FileName);
      TestDecode(FileName, False);
      TestDecode(FileName, True);
      TestPCMReader(FileName);
    finally
      DeleteFile(FileName);
    end;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      ExitCode:=1;
    end;
  end;
end.
