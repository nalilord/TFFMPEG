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
  TFFmpeg.AudioResampler;

procedure Require(Value: Boolean; const MessageText: string);
begin
  if not Value then
    raise Exception.Create(MessageText);
end;

procedure Check(Code: Integer);
begin
  Require(Code >= 0, FFmpegErrorText(Code));
end;

procedure CreateWave(const FileName: string);
type
  TWaveHeader = packed record
    Riff: array[0..3] of AnsiChar;
    RiffSize: Cardinal;
    Wave: array[0..3] of AnsiChar;
    Fmt: array[0..3] of AnsiChar;
    FmtSize: Cardinal;
    FormatTag, Channels: Word;
    SampleRate, ByteRate: Cardinal;
    BlockAlign, BitsPerSample: Word;
    Data: array[0..3] of AnsiChar;
    DataSize: Cardinal;
  end;
var
  Header: TWaveHeader;
  Samples: array[0..2399] of SmallInt;
  I: Integer;
  Stream: TFileStream;
begin
  Header.Riff := 'RIFF';
  Header.RiffSize := 36 + SizeOf(Samples);
  Header.Wave := 'WAVE';
  Header.Fmt := 'fmt ';
  Header.FmtSize := 16;
  Header.FormatTag := 1;
  Header.Channels := 1;
  Header.SampleRate := 24000;
  Header.ByteRate := 48000;
  Header.BlockAlign := 2;
  Header.BitsPerSample := 16;
  Header.Data := 'data';
  Header.DataSize := SizeOf(Samples);
  for I := 0 to High(Samples) do
    Samples[I] := Round(10000 * Sin(2 * Pi * 440 * I / 24000));
  Stream := TFileStream.Create(FileName, fmCreate);
  try
    Stream.WriteBuffer(Header, SizeOf(Header));
    Stream.WriteBuffer(Samples, SizeOf(Samples));
  finally
    Stream.Free;
  end;
end;

procedure TestDecode(const FileName: string);
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

  procedure ConsumePCM;
  var
    I: Integer;
    Sample: PSmallInt;
  begin
    Require(ByteCount >= 0, 'Invalid PCM byte count');
    Require(ByteCount mod 4 = 0, 'Partial stereo sample');
    Inc(TotalBytes, ByteCount);
    Sample := PSmallInt(Buffer);
    for I := 1 to ByteCount div 2 do
    begin
      HasSignal := HasSignal or (Sample^ <> 0);
      Inc(Sample);
    end;
  end;

  procedure ReceiveFrames;
  var
    ReceiveCode: Integer;
  begin
    while True do
    begin
      ReceiveCode := Decoder.ReceiveFrame(Frame);
      if (ReceiveCode = AVERROR_EAGAIN) or (ReceiveCode = AVERROR_EOF) then
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
  Input := nil;
  Decoder := nil;
  Resampler := nil;
  Packet := nil;
  Frame := nil;
  Options := nil;
  Interrupt:=Default(TAVIOInterruptCB);
  try
    Input := TFFmpegInput.Create;
    Decoder := TFFmpegDecoder.Create;
    Resampler := TFFmpegAudioResampler.Create;
    Packet := TFFmpegApi.AllocPacket;
    Frame := TFFmpegApi.AllocFrame;
    Require((Packet <> nil) and (Frame <> nil), 'Allocation failed');
    Require(Input.ReadPacket(Packet) = AVERROR_EINVAL, 'Closed input must reject reads');
    Require(Input.Open(FileName + '.missing', Options) < 0, 'Missing input must fail');
    Require(Input.FormatContext = nil, 'Failed open retained its context');
    Require(Input.Open(FileName, Options, AVMEDIA_TYPE_VIDEO) < 0, 'Audio-only file has no video');
    Require(Input.FormatContext = nil, 'Failed stream selection retained its context');
    Require(Input.OpenFile(FileName + '.missing', Options, Interrupt) < 0, 'Missing local input must fail');
    Require(Input.OpenFile(FileName, Options, Interrupt, AVMEDIA_TYPE_VIDEO) < 0, 'Failed local stream selection must fail');
    Require(Input.FormatContext = nil, 'Failed local open retained its context');
    Check(Input.OpenFile(FileName, Options, Interrupt));
    Require(Input.CodecParameters^.sample_rate = 24000, 'Wrong input sample rate');
    Require(Input.CodecParameters^.ch_layout.nb_channels = 1, 'Wrong input channels');
    Check(Decoder.Open(Input.Codec, Input.CodecParameters));
    Require(Resampler.OpenFromCodec(Decoder.CodecContext, 48000, 2, AV_SAMPLE_FMT_S16P) = AVERROR_EINVAL,
      'Planar output must be rejected by the interleaved wrapper');
    Check(Resampler.OpenFromCodec(Decoder.CodecContext, 48000, 2, AV_SAMPLE_FMT_S16));
    Require(Resampler.BytesPerSecond = 192000, 'Wrong output byte rate');
    TotalBytes := 0;
    Frames := 0;
    HasSignal := False;
    while True do
    begin
      Code := Input.ReadPacket(Packet);
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
    Require((ByteCount = 0) and (Buffer = nil), 'Repeated flush must remain empty');
    Require(Frames > 0, 'No frames decoded');
    Require(TotalBytes = 19200, 'Expected 4800 stereo PCM16 samples after draining');
    Require(HasSignal, 'Decoded output is silent');
    Input.Close;
    Input.Close;
    Require((Input.StreamIndex = -1) and (Input.Codec = nil), 'Close did not clear state');
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

var
  FileName: string;
  Id: TGUID;
begin
  try
    Require(CreateGUID(Id) = 0, 'Could not create test filename');
{$IFDEF FPC}
    FileName := IncludeTrailingPathDelimiter(GetTempDir);
{$ELSE}
    FileName := IncludeTrailingPathDelimiter(TPath.GetTempPath);
{$ENDIF}
    FileName := FileName + 'TFFmpeg-' + GUIDToString(Id) + '.wav';
    try
      CreateWave(FileName);
      TestDecode(FileName);
    finally
      DeleteFile(FileName);
    end;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
