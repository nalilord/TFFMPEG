unit TFFmpeg.Resample;

interface

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  FFTypes,
  libavcodec,
  libavutil,
  libavutil_channel_layout,
  libavutil_mem,
  libavutil_opt,
  libavutil_samplefmt,
  libswresample;

type
  TFFmpegResampleApi = class sealed
  public
    class function AllocContext: PSwrContext; static;
    class function BytesPerSample(SampleFormat: TAVSampleFormat): Integer; static;
    class function ConfigureFromCodecContext(SwrContext: PSwrContext; CodecContext: PAVCodecContext;
      const OutputLayout: TAVChannelLayout; OutputSampleRate: Integer; OutputSampleFormat: TAVSampleFormat): Integer; static;
    class function Convert(SwrContext: PSwrContext; OutputBuffer: PPByte;
      OutputSampleCapacity: Integer; InputData: PPByte; InputSampleCount: Integer): Integer; static;
    class procedure DefaultChannelLayout(var Layout: TAVChannelLayout; Channels: Integer); static;
    class procedure EnsureAudioBufferCapacity(var Buffer: PByte; var Capacity: Integer; RequiredBytes: Integer); static;
    class procedure FreeAudioBuffer(var Buffer: PByte; var Capacity: Integer); static;
    class procedure FreeContext(var SwrContext: PSwrContext); static;
    class function Flush(SwrContext: PSwrContext; OutputBuffer: PPByte; OutputSampleCapacity: Integer): Integer; static;
    class function GetBufferSize(Channels, SampleCount: Integer; SampleFormat: TAVSampleFormat): Integer; static;
    class function GetOutSamples(SwrContext: PSwrContext; InputSampleCount: Integer): Integer; static;
    class function Init(SwrContext: PSwrContext): Integer; static;
    class procedure UninitChannelLayout(var Layout: TAVChannelLayout); static;
  end;

implementation

class function TFFmpegResampleApi.AllocContext: PSwrContext;
begin
  Result:=swr_alloc();
end;

class function TFFmpegResampleApi.BytesPerSample(SampleFormat: TAVSampleFormat): Integer;
begin
  Result:=av_get_bytes_per_sample(SampleFormat);
end;

class function TFFmpegResampleApi.ConfigureFromCodecContext(SwrContext: PSwrContext; CodecContext: PAVCodecContext; const OutputLayout: TAVChannelLayout;
  OutputSampleRate: Integer; OutputSampleFormat: TAVSampleFormat): Integer;
begin
  Result:=av_opt_set_chlayout(SwrContext, 'in_chlayout', @CodecContext^.ch_layout, 0);
  if Result < 0 then
    Exit;

  Result:=av_opt_set_int(SwrContext, 'in_sample_rate', CodecContext^.sample_rate, 0);
  if Result < 0 then
    Exit;

  Result:=av_opt_set_sample_fmt(SwrContext, 'in_sample_fmt', CodecContext^.sample_fmt, 0);
  if Result < 0 then
    Exit;

  Result:=av_opt_set_chlayout(SwrContext, 'out_chlayout', @OutputLayout, 0);
  if Result < 0 then
    Exit;

  Result:=av_opt_set_int(SwrContext, 'out_sample_rate', OutputSampleRate, 0);
  if Result < 0 then
    Exit;

  Result:=av_opt_set_sample_fmt(SwrContext, 'out_sample_fmt', OutputSampleFormat, 0);
end;

class function TFFmpegResampleApi.Convert(SwrContext: PSwrContext; OutputBuffer: PPByte;
  OutputSampleCapacity: Integer; InputData: PPByte; InputSampleCount: Integer): Integer;
begin
  Result:=swr_convert(SwrContext, OutputBuffer, OutputSampleCapacity, InputData, InputSampleCount);
end;

class procedure TFFmpegResampleApi.DefaultChannelLayout(var Layout: TAVChannelLayout; Channels: Integer);
begin
  av_channel_layout_default(@Layout, Channels);
end;

class procedure TFFmpegResampleApi.EnsureAudioBufferCapacity(var Buffer: PByte; var Capacity: Integer; RequiredBytes: Integer);
begin
  if RequiredBytes <= Capacity then
    Exit;

  FreeAudioBuffer(Buffer, Capacity);
  Capacity:=RequiredBytes * 2;
  Buffer:=av_malloc(Capacity);
  if NOT Assigned(Buffer) then
    raise Exception.Create('Could not allocate resampler buffer');
end;

class procedure TFFmpegResampleApi.FreeAudioBuffer(var Buffer: PByte; var Capacity: Integer);
begin
  if Assigned(Buffer) then
    av_freep(@Buffer);

  Capacity:=0;
end;

class procedure TFFmpegResampleApi.FreeContext(var SwrContext: PSwrContext);
begin
  if Assigned(SwrContext) then
    swr_free(@SwrContext);
end;

class function TFFmpegResampleApi.Flush(SwrContext: PSwrContext; OutputBuffer: PPByte; OutputSampleCapacity: Integer): Integer;
begin
  Result:=swr_convert(SwrContext, OutputBuffer, OutputSampleCapacity, nil, 0);
end;

class function TFFmpegResampleApi.GetBufferSize(Channels, SampleCount: Integer; SampleFormat: TAVSampleFormat): Integer;
begin
  Result:=av_samples_get_buffer_size(nil, Channels, SampleCount, SampleFormat, 1);
end;

class function TFFmpegResampleApi.GetOutSamples(SwrContext: PSwrContext; InputSampleCount: Integer): Integer;
begin
  Result:=swr_get_out_samples(SwrContext, InputSampleCount);
end;

class function TFFmpegResampleApi.Init(SwrContext: PSwrContext): Integer;
begin
  Result:=swr_init(SwrContext);
end;

class procedure TFFmpegResampleApi.UninitChannelLayout(var Layout: TAVChannelLayout);
begin
  av_channel_layout_uninit(@Layout);
end;

end.
