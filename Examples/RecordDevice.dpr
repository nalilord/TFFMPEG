program RecordDevice;

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
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Devices,
  TFFmpeg.Media.Recording,
  TFFmpeg.Media.Errors;

type
  TRecordingProgress = class
  private
    FStop: IMediaCancellationSource;
    FCancel: IMediaCancellationSource;
    FAfterMilliseconds: UInt64;
    FAbort: Boolean;
  public
    constructor Create(AAfterMilliseconds: UInt64; AAbort: Boolean);
    procedure Report(const AProgress: TMediaProgress);
    property StopSource: IMediaCancellationSource read FStop;
    property CancelSource: IMediaCancellationSource read FCancel;
  end;

constructor TRecordingProgress.Create(AAfterMilliseconds: UInt64; AAbort: Boolean);
begin
  inherited Create;
  FStop:=TMediaCancellation.CreateSource;
  FCancel:=TMediaCancellation.CreateSource;
  FAfterMilliseconds:=AAfterMilliseconds;
  FAbort:=AAbort;
end;

procedure TRecordingProgress.Report(const AProgress: TMediaProgress);
begin
  WriteLn('Stage=', Ord(AProgress.Stage), '; submitted=', AProgress.Bytes, ' bytes; elapsed=', AProgress.ElapsedMilliseconds, ' ms');
  if (AProgress.Stage = mpsProcessing) AND (FAfterMilliseconds > 0) AND (AProgress.ElapsedMilliseconds >= FAfterMilliseconds) then
    if FAbort then
      FCancel.Cancel
    else
      FStop.Cancel;
end;

procedure Run;
var
  Listing: TMediaDeviceList;
  Devices: TMediaDeviceInfos;
  Settings: TMediaRecordingSettings;
  CaptureSettings: TMediaCaptureSettings;
  Recorded: TMediaRecordingResult;
  Progress: TRecordingProgress;
  VideoIndex, AudioIndex, Seconds, AfterMilliseconds: Integer;
  AbortRequested: Boolean;
begin
  if NOT (ParamCount IN [4, 6]) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'RecordDevice',
      'Usage: RecordDevice <video index or -1> <audio index or -1> <seconds> <output> [--stop-after-ms|--cancel-after-ms <ms>]');
  VideoIndex:=StrToInt(ParamStr(1));
  AudioIndex:=StrToInt(ParamStr(2));
  Seconds:=StrToInt(ParamStr(3));
  if (Seconds < 1) OR (Seconds > 3600) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'RecordDevice', 'Duration must be 1-3600 seconds');
  AfterMilliseconds:=0;
  AbortRequested:=False;
  if ParamCount = 6 then
  begin
    AbortRequested:=ParamStr(5) = '--cancel-after-ms';
    if NOT AbortRequested AND (ParamStr(5) <> '--stop-after-ms') then
      raise EFFmpegMediaError.Create(mecInvalidSettings, 'RecordDevice', 'Unknown stop/cancel option');
    AfterMilliseconds:=StrToInt(ParamStr(6));
    if AfterMilliseconds <= 0 then
      raise EFFmpegMediaError.Create(mecInvalidSettings, 'RecordDevice', 'Stop/cancel time must be positive');
  end;
  Listing:=TMediaDevices.ListDevices;
  Devices:=Listing.Devices;
  if (VideoIndex < -1) OR (VideoIndex >= Length(Devices)) OR (AudioIndex < -1) OR (AudioIndex >= Length(Devices)) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'RecordDevice', 'Device index is outside the current list');
  if VideoIndex < 0 then
    Settings:=TMediaRecordingSettings.OggOpus
  else
  if AudioIndex < 0 then
    Settings:=TMediaRecordingSettings.H264MP4(640, 360, TMediaRate.Create(30, 1))
  else
    Settings:=TMediaRecordingSettings.H264OpusMatroska(640, 360, TMediaRate.Create(30, 1));
  CaptureSettings:=Settings.Capture;
  if VideoIndex >= 0 then
    CaptureSettings.VideoDeviceID:=Devices[VideoIndex].ID;
  if AudioIndex >= 0 then
    CaptureSettings.AudioDeviceID:=Devices[AudioIndex].ID;
  Settings.Capture:=CaptureSettings;
  Settings.Duration:=TMediaTime.FromSeconds(Seconds);
  Progress:=TRecordingProgress.Create(UInt64(AfterMilliseconds), AbortRequested);
  try
    Recorded:=TMediaRecording.WriteFile(ParamStr(4), Settings, Progress.Report, Progress.StopSource.Token, Progress.CancelSource.Token);
    WriteLn('Published: video=', Recorded.VideoFrames, ', audio=', Recorded.AudioSamples, ' at ', Recorded.AudioSampleRate,
      ' Hz; duration=', Recorded.Duration.Microseconds, ' us; stop reason=', Ord(Recorded.StopReason),
      '; capture stop=', Recorded.CaptureStats.StopLatencyMilliseconds, ' ms; estimated audio timing=', Recorded.EstimatedAudioTiming);
    WriteLn('Video cadence changes=', Recorded.CaptureStats.VideoCadenceChanges,
      '; native audio timestamp changes=', Recorded.CaptureStats.AudioTimestampChanges,
      '; audio buffers on sample clock=', Recorded.CaptureStats.AudioBuffersRetimed);
    if Recorded.CaptureStats.AudioClockDrift.Valid then
      WriteLn('Native audio clock residual=', Recorded.CaptureStats.AudioClockDrift.Microseconds, ' us');
    if Recorded.CaptureStats.AudioVideoDrift.Valid then
      WriteLn('Estimated AV clock residual=', Recorded.CaptureStats.AudioVideoDrift.Microseconds, ' us');
  finally
    Progress.Free;
  end;
end;

begin
  try
    Run;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
