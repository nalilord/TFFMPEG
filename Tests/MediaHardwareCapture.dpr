program MediaHardwareCapture;

{$APPTYPE CONSOLE}
{$R+}
{$Q+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
{$IFDEF FPC}
  Classes,
  SysUtils,
{$ELSE}
  System.Classes,
  System.SysUtils,
  System.Diagnostics,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Devices;

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

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

procedure Consume(const ACapture: IMediaCapture; AMilliseconds: Cardinal; out ARetained: IMediaSample);
var
  Item: TMediaCapturedSample;
  Started: UInt64;
  Status: TMediaCaptureReadStatus;
begin
  ARetained:=nil;
  Started:=ClockMilliseconds;
  repeat
    Status:=ACapture.ReadSample(Item, 100);
    Check(Status IN [mcrSample, mcrTimedOut], 'Unexpected capture terminal status');
    if (Status = mcrSample) AND NOT Assigned(ARetained) then
      ARetained:=Item.Sample;
  until ClockMilliseconds - Started >= AMilliseconds;
  Check(Assigned(ARetained), 'The source returned no public sample');
end;

procedure StopAndReport(const ACapture: IMediaCapture; const ALabel: String);
var
  Stats: TMediaCaptureStats;
begin
  ACapture.Stop;
  Stats:=ACapture.Stats;
  WriteLn(ALabel, ': video=', Stats.VideoFramesReceived, '; audio=', Stats.AudioBuffersReceived,
    '; video drops=', Stats.VideoFramesDropped, '; audio drops=', Stats.AudioBuffersDropped,
    '; cadence changes=', Stats.VideoCadenceChanges, '; audio timestamp changes=', Stats.AudioTimestampChanges,
    '; stop=', Stats.StopLatencyMilliseconds, ' ms');
  Check(Stats.StopLatencyMilliseconds < 2000, 'Measured stop/join exceeded two seconds');
  Flush(Output);
end;

procedure CheckSession(const ASettings: TMediaCaptureSettings; const ALabel: String);
var
  Capture: IMediaCapture;
  Retained: IMediaSample;
  Streams: TMediaStreams;
  Bytes: TBytes;
  I: Integer;
begin
  Capture:=TMediaDevices.OpenCapture(ASettings);
  try
    Streams:=Capture.Info.Streams;
    for I:=0 to Length(Streams) - 1 do
      WriteLn('Negotiated ', Streams[I].CodecName, ' ', Streams[I].Width, 'x', Streams[I].Height,
        '; rate=', Streams[I].SampleRate, '; channels=', Streams[I].ChannelLayout.Channels,
        '; pixel=', Streams[I].PixelFormatName, '; PCM bits=', Streams[I].BitsPerSample);
    Consume(Capture, 500, Retained);
    StopAndReport(Capture, ALabel);
  finally
    Capture.Stop;
    Capture:=nil;
  end;
  Bytes:=Retained.CopyBytes;
  Check(Length(Bytes) > 0, 'Retained storage survived context release');
end;

procedure CheckBusy(const ASettings: TMediaCaptureSettings);
var
  Primary, Secondary: IMediaCapture;
  Retained: IMediaSample;
  Failed: Boolean;
begin
  Secondary:=nil;
  Primary:=TMediaDevices.OpenCapture(ASettings);
  try
    Consume(Primary, 100, Retained);
    Failed:=False;
    try
      Secondary:=TMediaDevices.OpenCapture(ASettings);
    except
      on E: EFFmpegMediaError do
      begin
        Check(E.Category IN [mecInputOutput, mecUnsupported], 'Busy device error category');
        Failed:=True;
        WriteLn('BUSY_REJECTED: ', E.Message);
      end;
    end;
    if Assigned(Secondary) then
    begin
      StopAndReport(Secondary, 'Driver permits shared open');
      Secondary:=nil;
    end;
    Consume(Primary, 300, Retained);
    Check(Primary.State = mcsCapturing, 'Primary survives a second-open attempt');
    if NOT Failed then
      WriteLn('SHARED_OPEN_SUPPORTED');
    StopAndReport(Primary, 'Primary after second-open attempt');
  finally
    if Assigned(Secondary) then
      Secondary.Stop;
    Primary.Stop;
  end;
end;

procedure CheckUnplug(const ASettings: TMediaCaptureSettings; const AReadyFile: String);
var
  Capture: IMediaCapture;
  Item: TMediaCapturedSample;
  Retained: IMediaSample;
  Marker: TFileStream;
  Started: UInt64;
  Failed: Boolean;
  Bytes: TBytes;
begin
  Check((AReadyFile <> '') AND NOT FileExists(AReadyFile), 'Choose an absent owned ready-marker path');
  Capture:=TMediaDevices.OpenCapture(ASettings);
  try
    Consume(Capture, 300, Retained);
    Marker:=TFileStream.Create(AReadyFile, fmCreate);
    Marker.Free;
    WriteLn('UNPLUG_READY: disconnect the selected camera USB cable now; capture is active');
    Flush(Output);
    Started:=ClockMilliseconds;
    Failed:=False;
    try
      while ClockMilliseconds - Started < 300000 do
        Capture.ReadSample(Item, 1000);
    except
      on E: EFFmpegMediaError do
      begin
        Check(E.Category IN [mecInputOutput, mecDecode, mecTimedOut], 'Disconnect error category');
        WriteLn('UNPLUG_ERROR: ', E.Message, '; elapsed since ready=', ClockMilliseconds - Started, ' ms');
        Failed:=True;
      end;
    end;
    Check(Failed, 'No disconnect error observed within the armed interval');
    StopAndReport(Capture, 'After physical disconnect');
    Check(Capture.State = mcsFailed, 'Disconnect remains terminal');
  finally
    Capture.Stop;
    Capture:=nil;
  end;
  Bytes:=Retained.CopyBytes;
  Check(Length(Bytes) > 0, 'Retained sample survives physical disconnect');
  WriteLn('PASS: physical disconnect, contained error, worker join and retained storage');
end;

procedure Run;
var
  Devices: TMediaDeviceInfos;
  Settings, Single: TMediaCaptureSettings;
  Query: TMediaDeviceModes;
  Modes: TMediaDeviceModeArray;
  Mode: TMediaDeviceMode;
  Index, AudioIndex, I: Integer;
  Failed: Boolean;
  Capture: IMediaCapture;
begin
  Check(ParamCount IN [3, 4], 'Usage: MediaHardwareCapture <video index> <audio index> <check|unplug> [absent ready-marker path]');
  Devices:=TMediaDevices.ListDevices.Devices;
  Index:=StrToInt(ParamStr(1));
  AudioIndex:=StrToInt(ParamStr(2));
  Check((Index >= 0) AND (Index < Length(Devices)) AND (AudioIndex >= 0) AND (AudioIndex < Length(Devices)), 'Current device indexes');
  Check((Devices[Index].Kind = mkVideo) AND (Devices[AudioIndex].Kind = mkAudio), 'Video/audio device roles');
  Settings:=TMediaCaptureSettings.Default;
  Settings.VideoDeviceID:=Devices[Index].ID;
  Settings.AudioDeviceID:=Devices[AudioIndex].ID;
  WriteLn('Physical target: ', Devices[Index].DisplayName, ' / ', Devices[AudioIndex].DisplayName);
  Query:=TMediaDevices.QueryModes(Settings.VideoDeviceID);
  Modes:=Query.Modes;
  Check((Query.Status = mdqsAvailable) AND (Length(Modes) > 0), 'Camera mode discovery');
  // The hardware run requests a known raw mode explicitly, so negotiation is
  // exercised separately from driver-default preview and recording examples.
  for I:=0 to Length(Modes) - 1 do
    if (Modes[I].Kind = mkVideo) AND (Modes[I].Width > 0) AND (Modes[I].FormatName = 'yuyv422') then
    begin
      Settings.VideoMode:=Modes[I];
      Break;
    end;
  Query:=TMediaDevices.QueryModes(Settings.AudioDeviceID);
  Modes:=Query.Modes;
  Check((Query.Status = mdqsAvailable) AND (Length(Modes) > 0), 'Microphone mode discovery');
  for I:=0 to Length(Modes) - 1 do
    if (Modes[I].Kind = mkAudio) AND (Modes[I].FormatName = 'pcm_s16le') then
    begin
      Settings.AudioMode:=Modes[I];
      Break;
    end;
  if ParamStr(3) = 'unplug' then
  begin
    Check(ParamCount = 4, 'Unplug mode requires the ready-marker path');
    CheckUnplug(Settings, ParamStr(4));
    Exit;
  end;
  Check(ParamStr(3) = 'check', 'Unknown hardware validation mode');
  Single:=Settings;
  Single.AudioDeviceID:='';
  CheckSession(Single, 'Camera only');
  Single:=Settings;
  Single.VideoDeviceID:='';
  CheckSession(Single, 'Microphone only');
  CheckSession(Settings, 'Combined');
  CheckBusy(Settings);
  for I:=0 to 4 do
    CheckSession(Settings, 'Stop/reopen ' + IntToStr(I + 1));
  Single:=Settings;
  Mode:=Single.VideoMode;
  Mode.Width:=13;
  Mode.Height:=13;
  Single.VideoMode:=Mode;
  Failed:=False;
  Capture:=nil;
  try
    try
      Capture:=TMediaDevices.OpenCapture(Single);
    except
      on E: EFFmpegMediaError do
      begin
        Failed:=E.Category IN [mecInputOutput, mecUnsupported];
        WriteLn('UNSUPPORTED_MODE_REJECTED: ', E.Message);
      end;
    end;
  finally
    if Assigned(Capture) then
      Capture.Stop;
    Capture:=nil;
  end;
  Check(Failed, 'Unsupported physical mode reports a contained error');
  CheckSession(Settings, 'Reopen after rejected mode');
  Single:=Settings;
  Single.VideoDeviceID:='dshow:video:missing-device';
  Failed:=False;
  try
    Capture:=TMediaDevices.OpenCapture(Single);
  except
    on E: EFFmpegMediaError do
      Failed:=E.Category = mecInputOutput;
  end;
  Check(Failed, 'Missing device reports a contained IO error');
  WriteLn('PASS: physical discovery, explicit negotiation, video/audio/combined samples, busy behavior, retained storage and repeated stop/reopen');
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
