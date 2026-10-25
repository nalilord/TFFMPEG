unit TFFmpeg.AudioResampler;

interface

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  libavcodec,
  libavutil,
  libavutil_channel_layout,
  libavutil_error,
  libavutil_frame,
  libavutil_samplefmt,
  libswresample,
  TFFmpeg.Resample;

type
  TFFmpegAudioResampler = class
  private
    FSwrContext: PSwrContext;
    FOutputLayout: TAVChannelLayout;
    FOutputSampleRate: Integer;
    FOutputChannels: Integer;
    FOutputSampleFormat: TAVSampleFormat;
    FBuffer: PByte;
    FBufferCapacity: Integer;
    procedure EnsureBufferCapacity(RequiredBytes: Integer);
  public
    constructor Create;
    destructor Destroy; override;

    function OpenFromCodec(CodecContext: PAVCodecContext; OutputSampleRate, OutputChannels: Integer; OutputSampleFormat: TAVSampleFormat): Integer;
    procedure Close;
    function ConvertFrame(Frame: PAVFrame; out Buffer: PByte; out ByteCount: Integer): Integer;
    function Flush(out Buffer: PByte; out ByteCount: Integer): Integer;
    function BytesPerSecond: Integer;

    property OutputSampleRate: Integer read FOutputSampleRate;
    property OutputChannels: Integer read FOutputChannels;
    property OutputSampleFormat: TAVSampleFormat read FOutputSampleFormat;
  end;

implementation

procedure TFFmpegAudioResampler.Close;
begin
  TFFmpegResampleApi.FreeContext(FSwrContext);
  TFFmpegResampleApi.UninitChannelLayout(FOutputLayout);
  TFFmpegResampleApi.FreeAudioBuffer(FBuffer, FBufferCapacity);
end;

function TFFmpegAudioResampler.ConvertFrame(Frame: PAVFrame; out Buffer: PByte; out ByteCount: Integer): Integer;
var
  OutBytes: Integer;
  OutSamples: Integer;
begin
  Buffer:=nil;
  ByteCount:=0;

  if NOT Assigned(FSwrContext) OR NOT Assigned(Frame) then
    Exit(AVERROR_EINVAL);

  OutSamples:=TFFmpegResampleApi.GetOutSamples(FSwrContext, Frame^.nb_samples);
  if OutSamples < 0 then
    Exit(OutSamples);

  OutBytes:=TFFmpegResampleApi.GetBufferSize(FOutputChannels, OutSamples, FOutputSampleFormat);
  if OutBytes < 0 then
    Exit(OutBytes);

  EnsureBufferCapacity(OutBytes);
  Result:=TFFmpegResampleApi.Convert(FSwrContext, @FBuffer, OutSamples, Frame^.extended_data, Frame^.nb_samples);
  if Result <= 0 then
    Exit;

  ByteCount:=TFFmpegResampleApi.GetBufferSize(FOutputChannels, Result, FOutputSampleFormat);
  if ByteCount < 0 then
  begin
    Result:=ByteCount;
    ByteCount:=0;
    Exit;
  end;

  Buffer:=FBuffer;
end;

constructor TFFmpegAudioResampler.Create;
begin
  inherited Create;
  FOutputSampleFormat:=AV_SAMPLE_FMT_S16;
end;

destructor TFFmpegAudioResampler.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TFFmpegAudioResampler.EnsureBufferCapacity(RequiredBytes: Integer);
begin
  TFFmpegResampleApi.EnsureAudioBufferCapacity(FBuffer, FBufferCapacity, RequiredBytes);
end;

function TFFmpegAudioResampler.BytesPerSecond: Integer;
begin
  Result:=FOutputSampleRate * FOutputChannels * TFFmpegResampleApi.BytesPerSample(FOutputSampleFormat);
end;

function TFFmpegAudioResampler.Flush(out Buffer: PByte; out ByteCount: Integer): Integer;
var
  OutSamples: Integer;
  OutBytes: Integer;
begin
  Buffer:=nil;
  ByteCount:=0;

  if NOT Assigned(FSwrContext) then
    Exit(AVERROR_EINVAL);

  OutSamples:=TFFmpegResampleApi.GetOutSamples(FSwrContext, 0);
  if OutSamples <= 0 then
    Exit(OutSamples);

  OutBytes:=TFFmpegResampleApi.GetBufferSize(FOutputChannels, OutSamples, FOutputSampleFormat);
  if OutBytes < 0 then
    Exit(OutBytes);

  EnsureBufferCapacity(OutBytes);
  Result:=TFFmpegResampleApi.Flush(FSwrContext, @FBuffer, OutSamples);
  if Result <= 0 then
    Exit;

  ByteCount:=TFFmpegResampleApi.GetBufferSize(FOutputChannels, Result, FOutputSampleFormat);
  if ByteCount < 0 then
  begin
    Result:=ByteCount;
    ByteCount:=0;
    Exit;
  end;

  Buffer:=FBuffer;
end;

function TFFmpegAudioResampler.OpenFromCodec(CodecContext: PAVCodecContext; OutputSampleRate, OutputChannels: Integer;
  OutputSampleFormat: TAVSampleFormat): Integer;
begin
  Close;

  { This wrapper returns one interleaved buffer, not an array of planes. }
  if NOT Assigned(CodecContext) OR (OutputSampleRate <= 0) OR (OutputChannels <= 0) OR (av_sample_fmt_is_planar(OutputSampleFormat) <> 0) OR
    (TFFmpegResampleApi.BytesPerSample(OutputSampleFormat) <= 0) then
    Exit(AVERROR_EINVAL);

  FOutputSampleRate:=OutputSampleRate;
  FOutputChannels:=OutputChannels;
  FOutputSampleFormat:=OutputSampleFormat;
  TFFmpegResampleApi.DefaultChannelLayout(FOutputLayout, OutputChannels);

  FSwrContext:=TFFmpegResampleApi.AllocContext;
  if NOT Assigned(FSwrContext) then
    Exit(AVERROR_ENOMEM);

  Result:=TFFmpegResampleApi.ConfigureFromCodecContext(FSwrContext, CodecContext, FOutputLayout, OutputSampleRate, FOutputSampleFormat);
  if Result < 0 then
  begin
    Close;
    Exit;
  end;

  Result:=TFFmpegResampleApi.Init(FSwrContext);
  if Result < 0 then
    Close;
end;

end.
