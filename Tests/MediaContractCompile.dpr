program MediaContractCompile;

{$APPTYPE CONSOLE}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Writer,
  TFFmpeg.Media.Devices,
  TFFmpeg.Media.Recording,
  TFFmpeg.Media.Capabilities;

var
  Settings: TMediaInputSettings;
  WriterSettings: TMediaWriterSettings;
  CaptureSettings: TMediaCaptureSettings;
  RecordingSettings: TMediaRecordingSettings;
  Source: IMediaCancellationSource;
  Token: IMediaCancellationToken;
  Video: IMediaVideoFrame;
  Audio: IMediaAudioBuffer;
  Sample: IMediaSample;
  Bytes: TBytes;
begin
  Settings:=TMediaInputSettings.Default;
  Settings.Validate;
  WriterSettings:=TMediaWriterSettings.PCMWave(48000, 1);
  WriterSettings.Validate;
  RecordingSettings:=TMediaRecordingSettings.H264MP4(16, 16, TMediaRate.Create(30, 1));
  CaptureSettings:=RecordingSettings.Capture;
  CaptureSettings.VideoDeviceID:='dshow:video:contract-only';
  RecordingSettings.Capture:=CaptureSettings;
  RecordingSettings.Duration:=TMediaTime.FromSeconds(1);
  RecordingSettings.Validate;
  Source:=TMediaCancellation.CreateSource;
  Token:=Source.Token;
  Token.ThrowIfCancellationRequested('Contract consumer');

  SetLength(Bytes, 4);
  Video:=TMediaFrames.CopyVideo(Bytes, 1, 1, 4, mpfBGRA32, TMediaTime.FromSeconds(0));
  Sample:=Video;
  Audio:=TMediaFrames.CopyAudio(Bytes, 2, 48000, msfS16, TMediaChannelLayout.Mono, Sample.Timestamp);
  WriteLn('Public contract consumer: ', Audio.SampleCount, ' samples; runtime ', TMediaCapabilities.RuntimeVersion);
end.
