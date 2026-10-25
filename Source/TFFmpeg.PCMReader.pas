unit TFFmpeg.PCMReader;

interface

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  libavcodec_packet,
  libavcodec_codec_id,
  libavformat_avio,
  libavutil_frame,
  libavutil_channel_layout,
  TFFmpeg.Input,
  TFFmpeg.Decoder,
  TFFmpeg.AudioResampler;

type
  // Thread-confined streaming decode of owned encoded bytes to interleaved S16.
  // Read returns an owned PCM chunk, zero on success or a negative AVERROR.
  TFFmpegPCMReader = class
  private
    FInput: TFFmpegInput;
    FDecoder: TFFmpegDecoder;
    FResampler: TFFmpegAudioResampler;
    FPacket: PAVPacket;
    FFrame: PAVFrame;
    FInterrupt: TAVIOInterruptCB;
    FOutputRate: Integer;
    FOutputChannels: Integer;
    FDrainSent: Boolean;
    FDecoderEOF: Boolean;
    FResamplerOpen: Boolean;
    FOpened: Boolean;
    FInputRate: Integer;
    FInputFormat: Integer;
    FInputChannels: Integer;
    FInputLayout: TAVChannelLayout;
    function Interrupted: Boolean;
    function GetSourceCodecID: TAVCodecID;
    function GetSourceSampleRate: Integer;
    function GetSourceChannels: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    function OpenBytes(const ABytes: TBytes; AOutputRate, AOutputChannels: Integer; const AInterrupt: TAVIOInterruptCB): Integer;
    function Read(out ABytes: TBytes): Integer;
    procedure Close;
    property SourceCodecID: TAVCodecID read GetSourceCodecID;
    property SourceSampleRate: Integer read GetSourceSampleRate;
    property SourceChannels: Integer read GetSourceChannels;
  end;

implementation

uses
  libavutil,
  libavutil_dict,
  libavutil_error,
  libavutil_samplefmt;

constructor TFFmpegPCMReader.Create;
begin
  inherited;
  FInput:=TFFmpegInput.Create;
  FDecoder:=TFFmpegDecoder.Create;
  FResampler:=TFFmpegAudioResampler.Create;
end;

destructor TFFmpegPCMReader.Destroy;
begin
  Close;
  FResampler.Free;
  FDecoder.Free;
  FInput.Free;
  inherited;
end;

procedure TFFmpegPCMReader.Close;
begin
  av_frame_free(@FFrame);
  av_packet_free(@FPacket);

  if Assigned(FResampler) then
    FResampler.Close;
  if Assigned(FDecoder) then
    FDecoder.Close;
  if Assigned(FInput) then
    FInput.Close;
  av_channel_layout_uninit(@FInputLayout);

  FInterrupt:=Default(TAVIOInterruptCB);
  FDrainSent:=False;
  FDecoderEOF:=False;
  FResamplerOpen:=False;
  FOpened:=False;
end;

function TFFmpegPCMReader.Interrupted: Boolean;
begin
  Result:=False;

  if Assigned(FInterrupt.callback) then
    Result:=FInterrupt.callback(FInterrupt.opaque) <> 0;
end;

function TFFmpegPCMReader.GetSourceCodecID: TAVCodecID;
begin
  Result:=AV_CODEC_ID_NONE;

  if FOpened then
    Result:=FInput.CodecParameters.codec_id;
end;

function TFFmpegPCMReader.GetSourceSampleRate: Integer;
begin
  Result:=0;

  if FOpened then
    Result:=FInput.CodecParameters.sample_rate;
end;

function TFFmpegPCMReader.GetSourceChannels: Integer;
begin
  Result:=0;

  if FOpened then
    Result:=FInput.CodecParameters.ch_layout.nb_channels;
end;

function TFFmpegPCMReader.OpenBytes(const ABytes: TBytes; AOutputRate, AOutputChannels: Integer; const AInterrupt: TAVIOInterruptCB): Integer;
var
  Options: PAVDictionary;
begin
  Close;
  Result:=AVERROR_EINVAL;
  if (AOutputRate < 8000) OR (AOutputRate > 192000) OR (AOutputChannels < 1) OR (AOutputChannels > 2) then
    Exit;

  FInterrupt:=AInterrupt;
  FOutputRate:=AOutputRate;
  FOutputChannels:=AOutputChannels;

  if Interrupted then
  begin
    Close;
    Exit(AVERROR_EXIT);
  end;

  Options:=nil;

  try
    Result:=FInput.OpenBytes(ABytes, Options, AInterrupt);
    if Result >= 0 then
      Result:=FDecoder.Open(FInput.Codec, FInput.CodecParameters);

    if Result >= 0 then
    begin
      FPacket:=av_packet_alloc;
      FFrame:=av_frame_alloc;
      if NOT Assigned(FPacket) OR NOT Assigned(FFrame) then
        Result:=AVERROR_ENOMEM;
    end;
  finally
    av_dict_free(@Options);
  end;

  if Result < 0 then
    Close
  else
    FOpened:=True;
end;

function TFFmpegPCMReader.Read(out ABytes: TBytes): Integer;
var
  Code, Count: Integer;
  Buffer: PByte;
begin
  ABytes:=nil;
  Result:=AVERROR_EINVAL;
  if NOT FOpened then
    Exit;

  while True do
  begin
    if Interrupted then
      Exit(AVERROR_EXIT);

    if FDecoderEOF then
    begin
      if NOT FResamplerOpen then
        Exit(AVERROR_EOF);

      Code:=FResampler.Flush(Buffer, Count);
      if Code < 0 then
        Exit(Code);
      if Count = 0 then
        Exit(AVERROR_EOF);
    end else
    begin
      Code:=FDecoder.ReceiveFrame(FFrame);
      if Code = AVERROR_EOF then
      begin
        FDecoderEOF:=True;
        Continue;
      end;

      if Code = AVERROR_EAGAIN then
      begin
        if FDrainSent then
          Exit(AVERROR_EINVAL);

        Code:=FInput.ReadPacket(FPacket);
        if Code = AVERROR_EOF then
        begin
          Code:=FDecoder.SendPacket(nil);
          if Code < 0 then
            Exit(Code);
          FDrainSent:=True;
        end else
        begin
          if Code < 0 then
            Exit(Code);

          try
            if FPacket.stream_index = FInput.StreamIndex then
            begin
              Code:=FDecoder.SendPacket(FPacket);
              if Code < 0 then
                Exit(Code);
            end;
          finally
            av_packet_unref(FPacket);
          end;
        end;
        Continue;
      end;
      if Code < 0 then
        Exit(Code);

      try
        if NOT FResamplerOpen then
        begin
          FInputRate:=FFrame.sample_rate;
          FInputFormat:=FFrame.format;
          FInputChannels:=FFrame.ch_layout.nb_channels;

          Code:=av_channel_layout_copy(@FInputLayout, @FFrame.ch_layout);
          if Code < 0 then
            Exit(Code);

          Code:=FResampler.OpenFromCodec(FDecoder.CodecContext, FOutputRate, FOutputChannels, AV_SAMPLE_FMT_S16);
          if Code < 0 then
            Exit(Code);
          FResamplerOpen:=True;
        end;

        if (FFrame.sample_rate <> FInputRate) OR (FFrame.format <> FInputFormat) OR (FFrame.ch_layout.nb_channels <> FInputChannels) OR
          (av_channel_layout_compare(@FInputLayout, @FFrame.ch_layout) <> 0) then
          Exit(AVERROR_EINVAL);

        Code:=FResampler.ConvertFrame(FFrame, Buffer, Count);
        if Code < 0 then
          Exit(Code);
      finally
        av_frame_unref(FFrame);
      end;

      if Count = 0 then
        Continue;
    end;

    if (Count < 0) OR (Count MOD (FOutputChannels * 2) <> 0) OR NOT Assigned(Buffer) then
      Exit(AVERROR_EINVAL);

    SetLength(ABytes, Count);
    Move(Buffer^, ABytes[0], Count);

    Exit(0);
  end;
end;

end.
