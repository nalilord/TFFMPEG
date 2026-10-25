program CaptureDevice;

{$APPTYPE CONSOLE}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
  System.Diagnostics,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Devices,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Errors;

function ClockMilliseconds: UInt64;
{$IFNDEF FPC}
var
  Ticks, Frequency: Int64;
{$ENDIF}
begin
{$IFDEF FPC}
  Result:=GetTickCount64;
{$ELSE}
  Ticks:=TStopwatch.GetTimeStamp;
  Frequency:=TStopwatch.Frequency;
  Result:=UInt64(Ticks DIV Frequency) * 1000 + UInt64((Ticks MOD Frequency) * 1000 DIV Frequency);
{$ENDIF}
end;

procedure Run;
var
  Listing: TMediaDeviceList;
  Devices: TMediaDeviceInfos;
  Settings: TMediaCaptureSettings;
  Capture: IMediaCapture;
  Captured: TMediaCapturedSample;
  Retained: IMediaSample;
  Bytes: TBytes;
  Streams: TMediaStreams;
  Stats: TMediaCaptureStats;
  VideoIndex, AudioIndex, Seconds, I: Integer;
  Started: UInt64;
begin
  if ParamCount <> 3 then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'CaptureDevice',
      'Usage: CaptureDevice <video list index or -1> <audio list index or -1> <seconds>; run ListDevices first');
  VideoIndex:=StrToInt(ParamStr(1));
  AudioIndex:=StrToInt(ParamStr(2));
  Seconds:=StrToInt(ParamStr(3));
  if (Seconds < 1) OR (Seconds > 3600) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'CaptureDevice', 'Capture duration must be 1-3600 seconds');
  Listing:=TMediaDevices.ListDevices;
  Devices:=Listing.Devices;
  Settings:=TMediaCaptureSettings.Default;
  if (VideoIndex < -1) OR (VideoIndex >= Length(Devices)) OR (AudioIndex < -1) OR (AudioIndex >= Length(Devices)) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'CaptureDevice', 'Device index is outside the current list');
  if VideoIndex >= 0 then
    Settings.VideoDeviceID:=Devices[VideoIndex].ID;
  if AudioIndex >= 0 then
    Settings.AudioDeviceID:=Devices[AudioIndex].ID;
  Retained:=nil;
  Capture:=TMediaDevices.OpenCapture(Settings);
  try
    Streams:=Capture.Info.Streams;
    for I:=0 to Length(Streams) - 1 do
      WriteLn('Negotiated stream ', Streams[I].Index, ': ', Streams[I].CodecName, ' ', Streams[I].Width, 'x', Streams[I].Height,
        ', ', Streams[I].SampleRate, ' Hz, ', Streams[I].ChannelLayout.Channels, ' channels; pixel=', Streams[I].PixelFormatName,
        '; sample=', Streams[I].SampleFormatName, '; bits=', Streams[I].BitsPerSample);
    for I:=0 to Length(Streams) - 1 do
      if Streams[I].FrameRate.Known then
        WriteLn('Stream ', Streams[I].Index, ' rate=', Streams[I].FrameRate.Numerator, '/', Streams[I].FrameRate.Denominator, ' fps');
    Started:=ClockMilliseconds;
    while ClockMilliseconds - Started < UInt64(Seconds) * 1000 do
      if Capture.ReadSample(Captured, 100) = mcrSample then
      begin
        if NOT Assigned(Retained) then
          Retained:=Captured.Sample;
        if Captured.Discontinuity then
          WriteLn('Discontinuity at ', Captured.Sample.Timestamp.Microseconds, ' us');
      end;
    Capture.Stop;
    Stats:=Capture.Stats;
    WriteLn('Received video=', Stats.VideoFramesReceived, ', audio=', Stats.AudioBuffersReceived,
      '; dropped video=', Stats.VideoFramesDropped, ', audio=', Stats.AudioBuffersDropped,
      '; discontinuities=', Stats.Discontinuities, '; peak queue=', Stats.PeakQueuedBytes, ' bytes; stop=', Stats.StopLatencyMilliseconds, ' ms');
    if Stats.AudioVideoDrift.Valid then
      WriteLn('Estimated video/audio sample-clock residual=', Stats.AudioVideoDrift.Microseconds, ' us');
  finally
    Capture.Stop;
    Capture:=nil;
  end;
  if Assigned(Retained) then
  begin
    Bytes:=Retained.CopyBytes;
    WriteLn('Retained sample after capture release: ', Length(Bytes), ' bytes');
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
