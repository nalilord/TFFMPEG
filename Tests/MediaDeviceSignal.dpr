program MediaDeviceSignal;

{$APPTYPE CONSOLE}
{$R+}
{$Q+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
{$IFDEF FPC}
  SysUtils,
  Math,
{$ELSE}
  System.SysUtils,
  System.Math,
  System.Diagnostics,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Frames,
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

procedure Run;
var
  Devices: TMediaDeviceInfos;
  Settings: TMediaCaptureSettings;
  Capture: IMediaCapture;
  Item: TMediaCapturedSample;
  Audio: IMediaAudioBuffer;
  Bytes: TBytes;
  PreviousEnd: TMediaTime;
  Stats: TMediaCaptureStats;
  Index, Seconds, I, Level, Peak: Integer;
  Value: SmallInt;
  SampleCount, SumSquares, Nonzero: UInt64;
  Started: UInt64;
begin
  if ParamCount <> 2 then
    raise Exception.Create('Usage: MediaDeviceSignal <current audio listing index> <seconds 1-60>; preview metrics only');
  Index:=StrToInt(ParamStr(1));
  Seconds:=StrToInt(ParamStr(2));
  Devices:=TMediaDevices.ListDevices.Devices;
  if (Index < 0) OR (Index >= Length(Devices)) OR (Seconds < 1) OR (Seconds > 60) then
    raise Exception.Create('Select a current audio index and a bounded 1-60 second run');
  if Devices[Index].Kind <> mkAudio then
    raise Exception.Create('The selected device is not audio');
  Settings:=TMediaCaptureSettings.Default;
  Settings.AudioDeviceID:=Devices[Index].ID;
  Capture:=TMediaDevices.OpenCapture(Settings);
  Peak:=0;
  SampleCount:=0;
  SumSquares:=0;
  Nonzero:=0;
  PreviousEnd:=TMediaTime.Unknown;
  WriteLn('Device: ', Devices[Index].DisplayName);
  try
    Started:=ClockMilliseconds;
    while ClockMilliseconds - Started < UInt64(Seconds) * 1000 do
      if Capture.ReadSample(Item, 100) = mcrSample then
      begin
        if NOT Supports(Item.Sample, IMediaAudioBuffer, Audio) then
          raise Exception.Create('Capture did not return public PCM');
        Bytes:=Audio.CopyBytes;
        if (Audio.SampleFormat <> msfS16) OR (Length(Bytes) MOD 2 <> 0) then
          raise Exception.Create('Expected packed S16 preview data');
        Write('PCM samples/channel=', Audio.SampleCount, '; timestamp=', Audio.Timestamp.Microseconds);
        if PreviousEnd.Valid then
          Write('; delta from previous sample end=', Audio.Timestamp.Subtract(PreviousEnd).Microseconds, ' us');
        WriteLn('; discontinuity=', Item.Discontinuity);
        PreviousEnd:=Audio.Timestamp.Add(Audio.Duration);
        for I:=0 to Length(Bytes) DIV 2 - 1 do
        begin
          Move(Bytes[I * 2], Value, SizeOf(Value));
          Level:=Abs(Integer(Value));
          if Level > Peak then
            Peak:=Level;
          if Level > 0 then
            Inc(Nonzero);
          Inc(SumSquares, UInt64(Int64(Value) * Value));
          Inc(SampleCount);
        end;
        Flush(Output);
      end;
    Capture.Stop;
    Stats:=Capture.Stats;
    WriteLn('Received buffers=', Stats.AudioBuffersReceived, '; dropped=', Stats.AudioBuffersDropped,
      '; discontinuities=', Stats.Discontinuities, '; stop=', Stats.StopLatencyMilliseconds, ' ms');
  finally
    Capture.Stop;
    Capture:=nil;
  end;
  if SampleCount = 0 then
    raise Exception.Create('The selected device produced no PCM');
  WriteLn('Interleaved scalar samples=', SampleCount, '; nonzero=', Nonzero, '; peak=', Peak,
    '; RMS=', Sqrt(SumSquares / SampleCount):0:3);
  WriteLn('Signal level alone does not establish that a physical microphone is connected.');
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
