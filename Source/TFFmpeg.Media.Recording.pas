unit TFFmpeg.Media.Recording;

interface

uses
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Devices,
  TFFmpeg.Media.Writer,
  TFFmpeg.Media.Images;

type
  TMediaRecordingStop = (mrrDuration, mrrRequested);

  TMediaRecordingSettings = record
  private
    FCapture: TMediaCaptureSettings;
    FOutput: TMediaWriterSettings;
    FImage: TMediaImageSettings;
    FDuration: TMediaTime;
    FProgressIntervalMilliseconds: Cardinal;
  public
    class function H264MP4(AWidth, AHeight: Integer; const AFrameRate: TMediaRate): TMediaRecordingSettings; static;
    class function H264OpusMatroska(AWidth, AHeight: Integer; const AFrameRate: TMediaRate): TMediaRecordingSettings; static;
    class function OggOpus(AChannels: Integer = 2): TMediaRecordingSettings; static;
    procedure Validate;
    property Capture: TMediaCaptureSettings read FCapture write FCapture;
    property Output: TMediaWriterSettings read FOutput write FOutput;
    property Image: TMediaImageSettings read FImage write FImage;
    property Duration: TMediaTime read FDuration write FDuration;
    property ProgressIntervalMilliseconds: Cardinal read FProgressIntervalMilliseconds write FProgressIntervalMilliseconds;
  end;

  TMediaRecordingResult = record
  private
    FVideoFrames: Int64;
    FAudioSamples: Int64;
    FAudioSampleRate: Integer;
    FEstimatedAudioTiming: Boolean;
    FDuration: TMediaTime;
    FElapsedMilliseconds: UInt64;
    FStopReason: TMediaRecordingStop;
    FVideoEncoderName: String;
    FAudioEncoderName: String;
    FNegotiated: TMediaInfo;
    FCaptureStats: TMediaCaptureStats;
  public
    property VideoFrames: Int64 read FVideoFrames write FVideoFrames;
    property AudioSamples: Int64 read FAudioSamples write FAudioSamples;
    property EstimatedAudioTiming: Boolean read FEstimatedAudioTiming write FEstimatedAudioTiming;
    property AudioSampleRate: Integer read FAudioSampleRate write FAudioSampleRate;
    property Duration: TMediaTime read FDuration write FDuration;
    property ElapsedMilliseconds: UInt64 read FElapsedMilliseconds write FElapsedMilliseconds;
    property StopReason: TMediaRecordingStop read FStopReason write FStopReason;
    property VideoEncoderName: String read FVideoEncoderName write FVideoEncoderName;
    property AudioEncoderName: String read FAudioEncoderName write FAudioEncoderName;
    property Negotiated: TMediaInfo read FNegotiated write FNegotiated;
    property CaptureStats: TMediaCaptureStats read FCaptureStats write FCaptureStats;
  end;

  TMediaRecording = class sealed
  public
    // Stop finalizes valid queued media; cancellation aborts unpublished output.
    class function WriteFile(const AFilename: String; const ASettings: TMediaRecordingSettings;
      AProgress: TMediaProgressCallback = nil; const AStopToken: IMediaCancellationToken = nil;
      const ACancelToken: IMediaCancellationToken = nil): TMediaRecordingResult; static;
  end;

implementation

uses
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Internal.Recording;

class function TMediaRecordingSettings.H264MP4(AWidth, AHeight: Integer; const AFrameRate: TMediaRate): TMediaRecordingSettings;
var
  Options: TMediaOptions;
  Video: TMediaVideoEncoding;
begin
  Result:=Default(TMediaRecordingSettings);
  Result.FCapture:=TMediaCaptureSettings.Default;
  Result.FCapture.Policy:=mcpRecording;
  Result.FCapture.AudioTiming:=mcatSampleClock;
  Result.FCapture.AudioTimestampToleranceMilliseconds:=100;
  Result.FCapture.UseVideoDeviceTimestamps:=True;
  Result.FCapture.MaxVideoFrames:=32;
  Result.FCapture.MaxAudioBuffers:=128;
  Result.FCapture.MaxQueueBytes:=128 * 1024 * 1024;
  Result.FOutput:=TMediaWriterSettings.H264MP4(AWidth, AHeight, AFrameRate);
  Result.FOutput.Timing:=mwtPreserve;
  Result.FOutput.TimeoutMilliseconds:=5000;
  SetLength(Options, 1);
  Options[0]:=TMediaOption.Create(mosEncoder, 'preset', 'veryfast');
  Video:=Result.FOutput.Video;
  Video.Options:=Options;
  Result.FOutput.Video:=Video;
  Result.FImage:=TMediaImageSettings.Default;
  Result.FImage.TimeoutMilliseconds:=5000;
  Result.FProgressIntervalMilliseconds:=100;
end;

class function TMediaRecordingSettings.H264OpusMatroska(AWidth, AHeight: Integer; const AFrameRate: TMediaRate): TMediaRecordingSettings;
begin
  Result:=H264MP4(AWidth, AHeight, AFrameRate);
  Result.FOutput.MuxerName:='matroska';
  Result.FCapture.UseVideoDeviceTimestamps:=False;
  Result.FOutput.Audio:=TMediaAudioEncoding.Opus;
end;

class function TMediaRecordingSettings.OggOpus(AChannels: Integer): TMediaRecordingSettings;
begin
  Result:=H264MP4(2, 2, TMediaRate.Create(30, 1));
  Result.FOutput:=TMediaWriterSettings.OggOpus(AChannels);
  Result.FOutput.TimeoutMilliseconds:=5000;
  Result.FOutput.Timing:=mwtPreserve;
  Result.FCapture.Channels:=AChannels;
end;

procedure TMediaRecordingSettings.Validate;
begin
  FCapture.Validate;
  FOutput.Validate;
  FImage.Validate;
  if (FCapture.Policy <> mcpRecording) OR (FOutput.Timing <> mwtPreserve) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Record device', 'Recording requires strict capture and preserved timestamps');
  if FOutput.Video.Enabled <> (FCapture.VideoDeviceID <> '') then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Record device', 'Enable exactly the selected video device output');
  if FOutput.Audio.Enabled <> (FCapture.AudioDeviceID <> '') then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Record device', 'Enable exactly the selected audio device output');
  if FOutput.Audio.Enabled AND ((FCapture.SampleRate <> FOutput.Audio.SampleRate) OR (FCapture.Channels <> FOutput.Audio.Channels)) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Record device', 'Capture and encoded audio must use the same fixed rate/channel count');
  if FDuration.Valid AND (FDuration.Microseconds <= 0) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Record device', 'Timed recording requires a positive duration');
  if (FImage.AlphaMode <> mamComposite) OR
    (FOutput.Video.Enabled AND (((FImage.Width <> 0) AND (FImage.Width <> FOutput.Video.Width)) OR
    ((FImage.Height <> 0) AND (FImage.Height <> FOutput.Video.Height)))) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Record device', 'Render dimensions must match video output with composite alpha');
end;

class function TMediaRecording.WriteFile(const AFilename: String; const ASettings: TMediaRecordingSettings;
  AProgress: TMediaProgressCallback; const AStopToken, ACancelToken: IMediaCancellationToken): TMediaRecordingResult;
begin
  Result:=WriteCaptureRecording(AFilename, ASettings, nil, AProgress, AStopToken, ACancelToken);
end;

end.
