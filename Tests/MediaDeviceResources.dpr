program MediaDeviceResources;

{$APPTYPE CONSOLE}
{$R+}
{$Q+}

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
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Devices,
  MediaResourceSupport;

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

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

procedure CaptureCycle(const ASettings: TMediaCaptureSettings; ADurationMilliseconds: UInt64; AForceQueuePressure: Boolean);
var
  Capture: IMediaCapture;
  Item: TMediaCapturedSample;
  Retained: IMediaSample;
  Bytes: TBytes;
  Stats: TMediaCaptureStats;
  Current: TMediaResourceSnapshot;
  Started, LastSnapshot, PeakPrivate: UInt64;
begin
  Retained:=nil;
  PeakPrivate:=0;
  Capture:=TMediaDevices.OpenCapture(ASettings);
  try
    Started:=ClockMilliseconds;
    LastSnapshot:=Started;
    if AForceQueuePressure then
      Sleep(3000);
    while ClockMilliseconds - Started < ADurationMilliseconds do
    begin
      if Capture.ReadSample(Item, 100) = mcrSample then
        if NOT Assigned(Retained) then
          Retained:=Item.Sample;
      Stats:=Capture.Stats;
      Check(Stats.VideoQueueFrames <= ASettings.MaxVideoFrames, 'Live video count bound');
      Check(Stats.AudioQueueBuffers <= ASettings.MaxAudioBuffers, 'Live audio count bound');
      Check(Stats.PeakQueuedBytes <= ASettings.MaxQueueBytes, 'Live logical sample byte bound');
      if ClockMilliseconds - LastSnapshot >= 1000 then
      begin
        Current:=TMediaResourceSnapshot.Capture;
        if Current.PrivateBytes > PeakPrivate then
          PeakPrivate:=Current.PrivateBytes;
        LastSnapshot:=ClockMilliseconds;
      end;
    end;
    Capture.Stop;
    Stats:=Capture.Stats;
    Check(Stats.StopLatencyMilliseconds < 1000, 'Measured source stop latency stays below one second');
    if ASettings.VideoDeviceID <> '' then
      Check(Stats.VideoFramesReceived > 0, 'Live source produced video');
    if ASettings.AudioDeviceID <> '' then
      Check(Stats.AudioBuffersReceived > 0, 'Live source produced audio');
    if AForceQueuePressure then
    begin
      if ASettings.VideoDeviceID <> '' then
        Check(Stats.VideoFramesDropped > 0, 'Forced slow consumer drops preview video explicitly');
      if ASettings.AudioDeviceID <> '' then
        Check(Stats.AudioBuffersDropped > 0, 'Forced slow consumer reports independent audio loss');
      WriteLn('Live pressure: video received=', Stats.VideoFramesReceived, ', dropped=', Stats.VideoFramesDropped,
        '; audio received=', Stats.AudioBuffersReceived, ', dropped=', Stats.AudioBuffersDropped,
        '; source discontinuities=', Stats.Discontinuities, '; peak queue=', Stats.PeakQueuedBytes,
        '; peak observed private=', PeakPrivate, '; stop=', Stats.StopLatencyMilliseconds, ' ms');
      if Stats.AudioVideoDrift.Valid then
        WriteLn('Estimated clock residual=', Stats.AudioVideoDrift.Microseconds, ' us');
      Flush(Output);
    end;
  finally
    Capture.Stop;
    Capture:=nil;
  end;
  if Assigned(Retained) then
  begin
    Bytes:=Retained.CopyBytes;
    Check(Length(Bytes) > 0, 'Live retained buffer survives context release');
  end;
end;

procedure Run;
var
  Devices: TMediaDeviceInfos;
  Settings: TMediaCaptureSettings;
  Baseline, Current: TMediaResourceSnapshot;
  VideoIndex, AudioIndex, Seconds, I: Integer;
begin
  if ParamCount <> 3 then
    raise Exception.Create('Usage: MediaDeviceResources <video listing index or -1> <audio index or -1> <seconds >= 30>');
  Devices:=TMediaDevices.ListDevices.Devices;
  VideoIndex:=StrToInt(ParamStr(1));
  AudioIndex:=StrToInt(ParamStr(2));
  Seconds:=StrToInt(ParamStr(3));
  Check((Seconds >= 30) AND (Seconds <= 3600), 'Choose a bounded 30-3600 second live run');
  Check((VideoIndex >= -1) AND (VideoIndex < Length(Devices)) AND (AudioIndex >= -1) AND (AudioIndex < Length(Devices)), 'Current listing indexes');
  Settings:=TMediaCaptureSettings.Default;
  Settings.MaxVideoFrames:=3;
  Settings.MaxAudioBuffers:=2;
  Settings.MaxQueueBytes:=12 * 1024 * 1024;
  Settings.AudioOverflow:=maoDropOldest;
  if VideoIndex >= 0 then
    Settings.VideoDeviceID:=Devices[VideoIndex].ID;
  if AudioIndex >= 0 then
    Settings.AudioDeviceID:=Devices[AudioIndex].ID;
  Settings.Validate;
  for I:=0 to 2 do
    CaptureCycle(Settings, 100, False);
  Baseline:=TMediaResourceSnapshot.Capture;
  Baseline.Print('Capture after three warmup cycles');
  CaptureCycle(Settings, UInt64(Seconds) * 1000, True);
  Current:=TMediaResourceSnapshot.Capture;
  Current.Print('After sustained live preview and forced queue pressure');
  for I:=0 to 7 do
  begin
    Sleep(250);
    Current:=TMediaResourceSnapshot.Capture;
    Current.Print('Closed-source settle ' + IntToStr((I + 1) * 250) + ' ms');
  end;
  Current.CheckGrowth(Baseline, 64 * 1024 * 1024, 8, 'Sustained live capture');
  for I:=0 to 9 do
  begin
    CaptureCycle(Settings, 100, False);
    Current:=TMediaResourceSnapshot.Capture;
    Current.Print('Closed source cycle ' + IntToStr(I + 1));
    Current.CheckGrowth(Baseline, 64 * 1024 * 1024, 8, 'Repeated native open/stop ' + IntToStr(I));
  end;
  Current.Print('After ten more native capture lifecycles');
  WriteLn('PASS: bounded live capture/drop policies, retained buffers, measured stop and process resource growth');
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
