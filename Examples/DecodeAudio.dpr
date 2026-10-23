program DecodeAudio;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  cthreads,
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  libavcodec_packet,
  libavutil_dict,
  libavutil_error,
  libavutil_frame,
  libavutil_samplefmt,
  TFFmpeg.Api,
  TFFmpeg.Utils,
  TFFmpeg.Input,
  TFFmpeg.Decoder,
  TFFmpeg.AudioResampler;

procedure Check(Code: Integer);
begin
  if Code < 0 then
    raise Exception.Create(FFmpegErrorText(Code));
end;

procedure Decode(const URL: string);
var
  Input: TFFmpegInput;
  Decoder: TFFmpegDecoder;
  Resampler: TFFmpegAudioResampler;
  Options: PAVDictionary;
  Packet: PAVPacket;
  Frame: PAVFrame;
  Code, ByteCount: Integer;
  Buffer: PByte;
  Frames, PCMBytes: Int64;

  procedure ReceiveFrames;
  var
    ReceiveCode: Integer;
  begin
    while True do
    begin
      ReceiveCode := Decoder.ReceiveFrame(Frame);
      if (ReceiveCode = AVERROR_EAGAIN) or (ReceiveCode = AVERROR_EOF) then
        Break;
      Check(ReceiveCode);
      try
        Check(Resampler.ConvertFrame(Frame, Buffer, ByteCount));
        Inc(Frames);
        Inc(PCMBytes, ByteCount);
        { Consume Buffer[0..ByteCount-1] here, before the next conversion.
          This example counts PCM only; it does not use an audio device. }
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
  try
    Input := TFFmpegInput.Create;
    Decoder := TFFmpegDecoder.Create;
    Resampler := TFFmpegAudioResampler.Create;
    Packet := TFFmpegApi.AllocPacket;
    Frame := TFFmpegApi.AllocFrame;
    if (Packet = nil) or (Frame = nil) then
      raise Exception.Create('Could not allocate packet/frame');
    Check(Input.Open(URL, Options));
    Check(Decoder.Open(Input.Codec, Input.CodecParameters));
    Check(Resampler.OpenFromCodec(Decoder.CodecContext, 48000, 2, AV_SAMPLE_FMT_S16));
    Frames := 0;
    PCMBytes := 0;
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
      Inc(PCMBytes, ByteCount);
    until ByteCount = 0;
    WriteLn('Decoded frames: ', Frames);
    WriteLn('PCM bytes (48 kHz, stereo, signed 16-bit): ', PCMBytes);
    if (Frames = 0) or (PCMBytes = 0) then
      raise Exception.Create('No audio decoded');
  finally
    av_dict_free(@Options);
    TFFmpegApi.FreeFrame(Frame);
    TFFmpegApi.FreePacket(Packet);
    Resampler.Free;
    Decoder.Free;
    Input.Free;
  end;
end;

begin
  try
    if ParamCount <> 1 then
      raise Exception.Create('Usage: DecodeAudio <audio file or URL>');
    Decode(ParamStr(1));
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
