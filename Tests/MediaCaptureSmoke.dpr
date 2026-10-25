program MediaCaptureSmoke;

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
  SyncObjs,
{$ELSE}
  System.Classes,
  System.SysUtils,
  System.SyncObjs,
  System.Diagnostics,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Devices,
  TFFmpeg.Media.Recording,
  TFFmpeg.Media.Writer,
  TFFmpeg.Media.Reader,
  TFFmpeg.Media.Internal.Recording,
  MediaTestSupport,
  TFFmpeg.Media.Internal.Capture,
  TFFmpeg.Media.Internal.Capture.Source;

type
  TCommandKind = (ckSample, ckDisconnect, ckException, ckTimeout);
  TCommand = record
    FKind: TCommandKind;
    FSample: IMediaSample;
  end;

  TMockState = class
  private
    FLock: TCriticalSection;
    FSignal: TEvent;
    FWaiting: TEvent;
    FCommands: Array of TCommand;
    FThreadID: NativeUInt;
    FActiveReads: Integer;
    FOpenCount: Integer;
    FCloseCount: Integer;
    FWrongThread: Boolean;
    FCloseWhileReading: Boolean;
    FOpenFails: Boolean;
    FTokenFails: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Push(AKind: TCommandKind; const ASample: IMediaSample = nil);
    function Pop(out ACommand: TCommand): Boolean;
    procedure CheckClosed;
  end;

  TMockSource = class(TInterfacedObject, IMediaCaptureSource)
  private
    FState: TMockState;
    FToken: IMediaCancellationToken;
    FOpened: Boolean;
  public
    constructor Create(AState: TMockState);
    procedure Open(const ASettings: TMediaCaptureSettings; const AToken: IMediaCancellationToken);
    function GetInfo: TMediaInfo;
    function ReadSample(out ASample: IMediaSample): TMediaReadStatus;
    procedure Close;
  end;

  TThrowingToken = class(TInterfacedObject, IMediaCancellationToken)
  private
    FState: TMockState;
  public
    constructor Create(AState: TMockState);
    function IsCancellationRequested: Boolean;
    procedure ThrowIfCancellationRequested(const AOperation: String);
  end;

  TRecordingObserver = class
  private
    FStop: IMediaCancellationSource;
    FCancel: IMediaCancellationSource;
    FAction: Integer;
    FCompleted: Boolean;
    FUnknownDuration: Boolean;
    FCallerThread: NativeUInt;
    FLastBytes: Int64;
  public
    constructor Create(AAction: Integer);
    procedure Report(const AProgress: TMediaProgress);
  end;

  TDelayedCancel = class(TThread)
  private
    FSource: IMediaCancellationSource;
  protected
    procedure Execute; override;
  public
    constructor Create(const ASource: IMediaCancellationSource);
  end;

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

function ThreadID: NativeUInt;
begin
{$IFDEF FPC}
  Result:=GetCurrentThreadID;
{$ELSE}
  Result:=TThread.CurrentThread.ThreadID;
{$ENDIF}
end;

constructor TMockState.Create;
begin
  inherited Create;
  FLock:=TCriticalSection.Create;
  FSignal:=TEvent.Create(nil, True, False, '');
  FWaiting:=TEvent.Create(nil, True, False, '');
end;

destructor TMockState.Destroy;
begin
  FCommands:=nil;
  FWaiting.Free;
  FSignal.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TMockState.Push(AKind: TCommandKind; const ASample: IMediaSample);
var
  Command: TCommand;
begin
  Command:=Default(TCommand);
  Command.FKind:=AKind;
  Command.FSample:=ASample;
  FLock.Acquire;
  try
    SetLength(FCommands, Length(FCommands) + 1);
    FCommands[High(FCommands)]:=Command;
    FSignal.SetEvent;
  finally
    FLock.Release;
  end;
end;

function TMockState.Pop(out ACommand: TCommand): Boolean;
var
  I: Integer;
begin
  Result:=False;
  ACommand:=Default(TCommand);
  FLock.Acquire;
  try
    if Length(FCommands) = 0 then
    begin
      FSignal.ResetEvent;
      Exit;
    end;
    ACommand:=FCommands[0];
    for I:=0 to Length(FCommands) - 2 do
      FCommands[I]:=FCommands[I + 1];
    SetLength(FCommands, Length(FCommands) - 1);
    Result:=True;
  finally
    FLock.Release;
  end;
end;

procedure TMockState.CheckClosed;
begin
  FLock.Acquire;
  try
    Check((FOpenCount = 1) AND (FCloseCount = 1), 'Exactly one source open/close');
    Check(FActiveReads = 0, 'No active read after stop/join');
    Check(NOT FCloseWhileReading, 'Native source never closed during read');
    Check(NOT FWrongThread, 'Source open/read/close share the owning worker');
    Check(FThreadID <> ThreadID, 'Native source belongs to the worker, not the consumer');
  finally
    FLock.Release;
  end;
end;

constructor TMockSource.Create(AState: TMockState);
begin
  inherited Create;
  FState:=AState;
end;

procedure TMockSource.Open(const ASettings: TMediaCaptureSettings; const AToken: IMediaCancellationToken);
begin
  FToken:=AToken;
  FState.FLock.Acquire;
  try
    FState.FThreadID:=ThreadID;
    Inc(FState.FOpenCount);
    FOpened:=True;
    if FState.FOpenFails then
      raise EFFmpegMediaError.Create(mecUnsupported, 'Mock open', 'Requested mode is unsupported');
  finally
    FState.FLock.Release;
  end;
end;

function TMockSource.GetInfo: TMediaInfo;
var
  Streams: TMediaStreams;
begin
  Result:=Default(TMediaInfo);
  Result.FormatName:='mock-capture';
  SetLength(Streams, 2);
  Streams[0].Index:=0;
  Streams[0].Kind:=mkVideo;
  Streams[0].Width:=2;
  Streams[0].Height:=2;
  Streams[0].FrameRate:=TMediaRate.Create(30, 1);
  Streams[1].Index:=1;
  Streams[1].Kind:=mkAudio;
  Streams[1].SampleRate:=48000;
  Streams[1].ChannelLayout:=TMediaChannelLayout.Mono;
  Result.Streams:=Streams;
end;

function TMockSource.ReadSample(out ASample: IMediaSample): TMediaReadStatus;
var
  Command: TCommand;
begin
  Result:=mrsEndOfInput;
  ASample:=nil;
  FState.FLock.Acquire;
  try
    FState.FWrongThread:=FState.FWrongThread OR (FState.FThreadID <> ThreadID);
    Inc(FState.FActiveReads);
    FState.FWaiting.SetEvent;
  finally
    FState.FLock.Release;
  end;
  try
    while True do
    begin
      FToken.ThrowIfCancellationRequested('Mock read');
      if FState.Pop(Command) then
      begin
        case Command.FKind of
          ckSample:
          begin
            ASample:=Command.FSample;
            Exit(mrsSample);
          end;

          ckDisconnect: Exit(mrsEndOfInput);
          ckException: raise Exception.Create('Mock driver callback failure');
          ckTimeout: Exit(mrsTimedOut);
        end;
      end;
      FState.FSignal.WaitFor(5);
    end;
  finally
    FState.FLock.Acquire;
    try
      Dec(FState.FActiveReads);
    finally
      FState.FLock.Release;
    end;
  end;
end;

procedure TMockSource.Close;
begin
  if NOT FOpened then
    Exit;
  FOpened:=False;
  FState.FLock.Acquire;
  try
    FState.FWrongThread:=FState.FWrongThread OR (FState.FThreadID <> ThreadID);
    FState.FCloseWhileReading:=FState.FActiveReads <> 0;
    Inc(FState.FCloseCount);
  finally
    FState.FLock.Release;
  end;
  FToken:=nil;
end;

constructor TThrowingToken.Create(AState: TMockState);
begin
  inherited Create;
  FState:=AState;
end;

function TThrowingToken.IsCancellationRequested: Boolean;
begin
  Result:=False;
  FState.FLock.Acquire;
  try
    if FState.FTokenFails then
      raise Exception.Create('Application cancellation callback failed');
  finally
    FState.FLock.Release;
  end;
end;

procedure TThrowingToken.ThrowIfCancellationRequested(const AOperation: String);
begin
  if IsCancellationRequested then
    raise EMediaCancelled.Create(AOperation);
end;

constructor TDelayedCancel.Create(const ASource: IMediaCancellationSource);
begin
  inherited Create(True);
  FreeOnTerminate:=False;
  FSource:=ASource;
end;

procedure TDelayedCancel.Execute;
begin
  Sleep(50);
  FSource.Cancel;
end;

function Settings: TMediaCaptureSettings;
begin
  Result:=TMediaCaptureSettings.Default;
  Result.VideoDeviceID:='dshow:video:mock';
  Result.RequireFixedVideoCadence:=True;
  Result.AudioDeviceID:='dshow:audio:mock';
end;

function Video(AIndex: Integer; AChanged: Boolean = False; AStep: Integer = 0): IMediaSample;
var
  Bytes: TBytes;
  Timestamp: TMediaTime;
begin
  Result:=nil;
  SetLength(Bytes, 16);
  FillChar(Bytes[0], Length(Bytes), Byte(AIndex));
  Bytes[3]:=255;
  Bytes[7]:=255;
  Bytes[11]:=255;
  Bytes[15]:=255;
  Timestamp:=TMediaTime.FromTicks(AIndex, TMediaRate.Create(1, 30));
  if AStep > 0 then
    Timestamp:=TMediaTime.FromMicroseconds(Int64(AIndex) * AStep);
  Result:=TMediaFrames.CopyVideo(Bytes, 2, 2, 8, mpfBGRA32, Timestamp, 0, AChanged);
end;

function Audio(AIndex: Integer): IMediaSample;
var
  Bytes: TBytes;
begin
  Result:=nil;
  SetLength(Bytes, 960);
  FillChar(Bytes[0], Length(Bytes), Byte(AIndex));
  Result:=TMediaFrames.CopyAudio(Bytes, 480, 48000, msfS16, TMediaChannelLayout.Mono,
    TMediaTime.FromMicroseconds(Int64(AIndex) * 10000), 1);
end;

function AudioAt(AIndex: Integer; ATimestamp: Int64): IMediaSample;
begin
  Result:=TMediaFrames.CopyAudio(Audio(AIndex).CopyBytes, 480, 48000, msfS16, TMediaChannelLayout.Mono,
    TMediaTime.FromMicroseconds(ATimestamp), 1);
end;

procedure WaitCount(const ACapture: IMediaCapture; AVideo, AAudio: Int64);
var
  Started: UInt64;
  Stats: TMediaCaptureStats;
begin
  Started:=ClockMilliseconds;
  repeat
    Stats:=ACapture.Stats;
    if (Stats.VideoFramesReceived >= AVideo) AND (Stats.AudioBuffersReceived >= AAudio) then
      Exit;
    Check(ACapture.State <> mcsFailed, 'Worker failed before expected sample count');
    Check(ClockMilliseconds - Started < 5000, 'Worker sample count deadline');
    Sleep(1);
  until False;
end;

procedure WaitFailure(const ACapture: IMediaCapture; ACategory: TMediaErrorCategory);
var
  Started: UInt64;
  Item: TMediaCapturedSample;
  Failed: Boolean;
begin
  Started:=ClockMilliseconds;
  while ACapture.State <> mcsFailed do
  begin
    Check(ClockMilliseconds - Started < 5000, 'Worker error deadline');
    Sleep(1);
  end;
  Failed:=False;
  try
    ACapture.ReadSample(Item, 0);
  except
    on E: EFFmpegMediaError do
      Failed:=E.Category = ACategory;
  end;
  Check(Failed AND NOT Assigned(Item.Sample), 'Contained worker error reaches consumer with no stale sample');
end;

procedure TestPreviewAndStop;
var
  State: TMockState;
  Capture: IMediaCapture;
  Config: TMediaCaptureSettings;
  Item: TMediaCapturedSample;
  Retained: IMediaSample;
  Bytes: TBytes;
  Stats: TMediaCaptureStats;
  I: Integer;
  Started: UInt64;
begin
  State:=TMockState.Create;
  try
    Config:=Settings;
    Config.MaxVideoFrames:=3;
    Capture:=OpenCaptureSource(Config, TMockSource.Create(State), nil);
    try
      Check(Capture.ReadSample(Item, 20) = mcrTimedOut, 'Empty consumer wait expires without ending capture');
      Check(Capture.State = mcsCapturing, 'Consumer timeout is nonterminal');
      for I:=0 to 7 do
        State.Push(ckSample, Video(I));
      WaitCount(Capture, 8, 0);
      Stats:=Capture.Stats;
      Check((Stats.VideoFramesDropped = 5) AND (Stats.VideoQueueFrames = 3) AND (Stats.QueuedBytes = 48), 'Bounded preview drops oldest video');
      Check(Capture.ReadSample(Item, 0) = mcrSample, 'Preview sample');
      Check(Item.Discontinuity AND (Item.Sample.Timestamp.Microseconds = 166666), 'First retained video reports drop and identity');
      Retained:=Item.Sample;
      Check(Capture.ReadSample(Item, 0) = mcrSample, 'Second preview sample');
      Check(NOT Item.Discontinuity, 'Drop is reported once to the next affected sample');
      Started:=ClockMilliseconds;
      Capture.Stop;
      Check(ClockMilliseconds - Started < 500, 'Stop joins a worker blocked in empty read');
      State.CheckClosed;
      Check(Capture.ReadSample(Item, 0) = mcrSample, 'Graceful stop retains already queued samples');
      Check(Capture.ReadSample(Item, 0) = mcrStopped, 'Stopped after draining queued samples');
      Stats:=Capture.Stats;
      Capture.Stop;
      Check(Capture.Stats.StopLatencyMilliseconds = Stats.StopLatencyMilliseconds, 'Repeated stop preserves measured latency');
    finally
      Capture.Stop;
      Capture:=nil;
    end;
    Bytes:=Retained.CopyBytes;
    Check((Length(Bytes) = 16) AND (Bytes[0] = 5), 'Retained frame survives worker/session release');
  finally
    State.Free;
  end;
  WriteLn('PASS: empty wait, bounded preview, retained samples, graceful queue drain and stop/join');
end;

procedure TestOverflow(ARecording, AAudio, AByteLimit: Boolean; ADropAudio: Boolean);
var
  State: TMockState;
  Capture: IMediaCapture;
  Config: TMediaCaptureSettings;
  Item: TMediaCapturedSample;
begin
  State:=TMockState.Create;
  try
    Config:=Settings;
    Config.MaxVideoFrames:=1;
    Config.MaxAudioBuffers:=1;
    if ARecording then
      Config.Policy:=mcpRecording;
    if ADropAudio then
      Config.AudioOverflow:=maoDropOldest;
    if AByteLimit then
    begin
      Config.MaxVideoFrames:=8;
      Config.MaxAudioBuffers:=8;
      Config.MaxQueueBytes:=20;
    end;
    Capture:=OpenCaptureSource(Config, TMockSource.Create(State), nil);
    try
      if AAudio then
      begin
        State.Push(ckSample, Audio(0));
        State.Push(ckSample, Audio(1));
      end else
      begin
        State.Push(ckSample, Video(0));
        State.Push(ckSample, Video(1));
      end;
      if ADropAudio then
      begin
        WaitCount(Capture, 0, 2);
        Check(Capture.Stats.AudioBuffersDropped = 1, 'Explicit preview audio drop count');
        Check(Capture.ReadSample(Item, 0) = mcrSample, 'Retained audio after overflow');
        Check(Item.Discontinuity AND (Item.Sample.Timestamp.Microseconds = 10000), 'Audio loss is reported separately');
      end else
        WaitFailure(Capture, mecInputOutput);
    finally
      Capture.Stop;
      Capture:=nil;
    end;
    State.CheckClosed;
  finally
    State.Free;
  end;
end;

procedure TestFailures;
var
  State: TMockState;
  Capture: IMediaCapture;
  Config: TMediaCaptureSettings;
  Item: TMediaCapturedSample;
  I: Integer;
  Token: IMediaCancellationToken;
begin
  for I:=0 to 7 do
  begin
    State:=TMockState.Create;
    try
      Config:=Settings;
      if I IN [3, 5, 6, 7] then
        Config.Policy:=mcpRecording;
      Token:=nil;
      if I = 4 then
        Token:=TThrowingToken.Create(State);
      Capture:=OpenCaptureSource(Config, TMockSource.Create(State), Token);
      try
        case I of
          0: State.Push(ckDisconnect);
          1: State.Push(ckException);
          2: State.Push(ckTimeout);
          3: State.Push(ckSample, Video(0, True));
          4:
          begin
            State.FLock.Acquire;
            try
              State.FTokenFails:=True;
            finally
              State.FLock.Release;
            end;
          end;
          5:
          begin
            State.Push(ckSample, Video(0));
            State.Push(ckSample, Video(2));
          end;
          6:
          begin
            State.Push(ckSample, Audio(0));
            State.Push(ckSample, Audio(2));
          end;
          7: State.Push(ckSample, TMediaFrames.CopyVideo(Video(0).CopyBytes, 2, 2, 8, mpfBGRA32, TMediaTime.Unknown, 0));
        end;
        if I = 2 then
          WaitFailure(Capture, mecTimedOut)
        else
          WaitFailure(Capture, mecInputOutput);
        Check(Capture.Stats.QueuedBytes = 0, 'Failure releases queued buffers');
      finally
        Capture.Stop;
        Capture:=nil;
        Token:=nil;
      end;
      State.CheckClosed;
    finally
      State.Free;
    end;
  end;
  State:=TMockState.Create;
  try
    Capture:=OpenCaptureSource(Settings, TMockSource.Create(State), nil);
    try
      State.Push(ckSample, Video(0, True));
      Check(Capture.ReadSample(Item, 1000) = mcrSample, 'Preview format change yields sample');
      Check(Item.Discontinuity AND (Capture.Stats.Discontinuities = 1), 'Preview format change is explicit');
    finally
      Capture.Stop;
      Capture:=nil;
    end;
    State.CheckClosed;
  finally
    State.Free;
  end;
  WriteLn('PASS: disconnect, driver/cancellation callback errors, native timeout, format change and timestamp gaps');
end;

procedure TestDriftAndMixedBytePressure;
var
  State: TMockState;
  Capture: IMediaCapture;
  Config: TMediaCaptureSettings;
  Item: TMediaCapturedSample;
  Bytes: TBytes;
  I, Scenario: Integer;
begin
  for Scenario:=0 to 2 do
  begin
    State:=TMockState.Create;
    try
      Config:=Settings;
      Config.MaxVideoFrames:=128;
      Config.MaxAudioBuffers:=128;
      if Scenario = 1 then
        Config.Policy:=mcpRecording;
      if Scenario = 2 then
        Config.MaxQueueBytes:=24;
      Capture:=OpenCaptureSource(Config, TMockSource.Create(State), nil);
      try
        if Scenario = 2 then
        begin
          SetLength(Bytes, 8);
          FillChar(Bytes[0], Length(Bytes), 0);
          State.Push(ckSample, TMediaFrames.CopyAudio(Bytes, 4, 48000, msfS16, TMediaChannelLayout.Mono,
            TMediaTime.FromMicroseconds(0), 1));
          State.Push(ckSample, Video(0));
          State.Push(ckSample, Video(1));
          WaitCount(Capture, 2, 1);
          Check((Capture.Stats.QueuedBytes = 24) AND (Capture.Stats.PeakQueuedBytes = 24), 'Combined queue byte bound');
          Check(Capture.Stats.VideoFramesDropped = 1, 'Byte pressure drops video separately from audio');
          Check(Capture.ReadSample(Item, 0) = mcrSample, 'Audio survives mixed byte pressure');
          Check((Item.Sample.Kind = mkAudio) AND NOT Item.Discontinuity, 'Audio has no implied video loss');
          Check(Capture.ReadSample(Item, 0) = mcrSample, 'Video survives mixed byte pressure');
          Check((Item.Sample.Kind = mkVideo) AND Item.Discontinuity, 'Affected video reports its drop');
        end else
        begin
          // Deliver clocks in separate bursts. Arrival order must not produce
          // drift; only video's gradual timestamp/sample-clock divergence does.
          for I:=0 to 99 do
            State.Push(ckSample, Audio(I));
          for I:=0 to 69 do
            State.Push(ckSample, Video(I, False, 38333));
          if Scenario = 1 then
            WaitFailure(Capture, mecInputOutput)
          else
          begin
            WaitCount(Capture, 70, 100);
            Check(Capture.Stats.AudioVideoDrift.Valid AND Capture.Stats.AudioVideoDrift.Estimated, 'Clock residual is explicitly estimated');
            Check(Capture.Stats.AudioVideoDrift.Microseconds = 344977, 'Clock residual excludes asynchronous delivery and counts exact nominal periods');
            Check(Capture.Stats.Discontinuities = 0, 'Gradual drift is distinct from a sudden gap');
          end;
        end;
      finally
        Capture.Stop;
        Capture:=nil;
      end;
      State.CheckClosed;
    finally
      State.Free;
    end;
  end;
  WriteLn('PASS: estimated clock residual/rejection and mixed byte pressure with separate loss reporting');
end;

procedure TestCaptureTimingPolicies;
var
  State: TMockState;
  Capture: IMediaCapture;
  Config: TMediaCaptureSettings;
  Item: TMediaCapturedSample;
  Bytes: TBytes;
  Scenario, I: Integer;
begin
  for Scenario:=0 to 3 do
  begin
    State:=TMockState.Create;
    try
      Config:=Settings;
      Config.Policy:=mcpRecording;
      Config.RequireFixedVideoCadence:=False;
      if Scenario > 0 then
      begin
        Config.AudioTiming:=mcatSampleClock;
        Config.AudioTimestampToleranceMilliseconds:=4;
      end;
      Config.MaxAudioBuffers:=128;
      if Scenario = 2 then
        Config.AudioTimestampToleranceMilliseconds:=100;
      Config.MaxClockDriftMilliseconds:=50;
      Capture:=OpenCaptureSource(Config, TMockSource.Create(State), nil);
      try
        case Scenario of
          0:
          begin
            State.Push(ckSample, Video(0));
            State.Push(ckSample, Video(2));
            State.Push(ckSample, Video(5));
            WaitCount(Capture, 3, 0);
            Check(Capture.Stats.VideoCadenceChanges = 2, 'VFR cadence variations are reported without fabricating packet loss');
            for I:=0 to 2 do
            begin
              Check(Capture.ReadSample(Item, 0) = mcrSample, 'VFR sample retained');
              Check(NOT Item.Discontinuity AND NOT Item.TimestampAdjusted, 'VFR preserves native video positions');
            end;
          end;
          1:
          begin
            State.Push(ckSample, AudioAt(0, 0));
            State.Push(ckSample, AudioAt(1, 12000));
            State.Push(ckSample, AudioAt(2, 21000));
            WaitCount(Capture, 0, 3);
            for I:=0 to 2 do
            begin
              Check(Capture.ReadSample(Item, 0) = mcrSample, 'Sample-clock audio retained');
              Check(Item.Sample.Timestamp.Microseconds = I * 10000, 'Sample clock advances by exact PCM counts');
              Check(Item.TimestampAdjusted AND Item.Sample.Timestamp.Estimated AND NOT Item.Discontinuity, 'Explicit retiming is estimated and reported');
              if I = 1 then
                Check(Item.SourceTimestamp.Microseconds = 12000, 'Original driver timestamp remains available');
              Bytes:=Item.Sample.CopyBytes;
              Check((Length(Bytes) = 960) AND (Bytes[0] = I), 'Timing policy never fills, drops or alters PCM');
            end;
            Check((Capture.Stats.AudioTimestampChanges = 2) AND (Capture.Stats.AudioBuffersRetimed = 3), 'Native jitter and retiming counters');
            Check(Capture.Stats.AudioClockDrift.Microseconds = 1000, 'Native residual remains measurable after presentation retiming');
          end;
          2:
          begin
            // A generous 100-ms budget still cannot accept an entire missing
            // 10-ms native buffer: the half-buffer cap takes precedence.
            State.Push(ckSample, Audio(0));
            State.Push(ckSample, Audio(2));
            WaitFailure(Capture, mecInputOutput);
          end;
          3:
          begin
            for I:=0 to 59 do
              State.Push(ckSample, AudioAt(I, Int64(I) * 11000));
            WaitFailure(Capture, mecInputOutput);
            Check(Capture.Stats.AudioClockDrift.Microseconds > 50000, 'Cumulative clock drift still aborts recording');
          end;
        end;
      finally
        Capture.Stop;
        Capture:=nil;
      end;
      State.CheckClosed;
    finally
      State.Free;
    end;
  end;
  WriteLn('PASS: explicit VFR/sample-clock policies retain native diagnostics/PCM and reject real gaps or accumulated drift');
end;

procedure TestCancellationAndRepetition;
var
  State: TMockState;
  Capture: IMediaCapture;
  Cancel: IMediaCancellationSource;
  Thread: TDelayedCancel;
  Item: TMediaCapturedSample;
  I: Integer;
  Started: UInt64;
  Failed: Boolean;
begin
  for I:=0 to 20 do
  begin
    State:=TMockState.Create;
    try
      Cancel:=TMediaCancellation.CreateSource;
      Capture:=OpenCaptureSource(Settings, TMockSource.Create(State), Cancel.Token);
      try
        Check(State.FWaiting.WaitFor(1000) = wrSignaled, 'Worker entered source read');
        if I = 0 then
        begin
          Thread:=TDelayedCancel.Create(Cancel);
          try
            Thread.Start;
            Started:=ClockMilliseconds;
            Check(Capture.ReadSample(Item, 5000) = mcrCancelled, 'Concurrent cancellation wakes blocked consumer');
            Check(ClockMilliseconds - Started < 500, 'Cancellation wake latency');
            Check(NOT Assigned(Item.Sample), 'Cancellation clears stale output');
            Thread.WaitFor;
          finally
            Thread.Free;
          end;
        end;
        if I = 1 then
        begin
          Cancel.Cancel;
          Capture.Stop;
          Check(Capture.ReadSample(Item, 0) = mcrCancelled, 'External abort wins a concurrent graceful-stop request');
        end;
        Capture.Stop;
      finally
        Capture:=nil;
        Cancel:=nil;
      end;
      State.CheckClosed;
    finally
      State.Free;
    end;
  end;
  State:=TMockState.Create;
  try
    State.FOpenFails:=True;
    Failed:=False;
    try
      Capture:=OpenCaptureSource(Settings, TMockSource.Create(State), nil);
    except
      on E: EFFmpegMediaError do
        Failed:=E.Category = mecUnsupported;
    end;
    Check(Failed, 'Open error reaches caller after source cleanup/join');
    State.CheckClosed;
  finally
    State.Free;
  end;
  WriteLn('PASS: concurrent cancellation, 21 worker lifecycles and failed-open join');
end;

constructor TRecordingObserver.Create(AAction: Integer);
begin
  inherited Create;
  FAction:=AAction;
  FStop:=TMediaCancellation.CreateSource;
  FCancel:=TMediaCancellation.CreateSource;
  FCallerThread:=ThreadID;
end;

procedure TRecordingObserver.Report(const AProgress: TMediaProgress);
begin
  Check(ThreadID = FCallerThread, 'Recording progress runs on the calling thread');
  Check(AProgress.Bytes >= FLastBytes, 'Recording processed byte count is monotonic');
  FLastBytes:=AProgress.Bytes;
  if AProgress.Stage = mpsCompleted then
  begin
    FCompleted:=True;
    if FUnknownDuration then
      Check(NOT AProgress.Percent.Known, 'User-stopped recording keeps unknown total percentage')
    else
      Check(AProgress.Percent.Known AND (AProgress.Percent.Value = 100), 'Completion percentage follows publication');
  end;
  case FAction of
    1:
      if (AProgress.Stage = mpsProcessing) AND (AProgress.ProcessedTime.Microseconds >= 100000) then
        FStop.Cancel;
    2:
      if AProgress.Stage = mpsFinalizing then
        FCancel.Cancel;
    3:
      if AProgress.Stage = mpsFinalizing then
        raise Exception.Create('Recording finalizing callback failure');
    4:
      if AProgress.Stage = mpsCompleted then
        raise Exception.Create('Recording completed callback failure');
    5:
      if AProgress.Stage = mpsProcessing then
        FCancel.Cancel;
  end;
end;

procedure ValidateRecording(const AFilename: String; AVideoFrames, AAudioSamples: Int64);
var
  Reader: IMediaReader;
  Config: TMediaReaderSettings;
  Sample: IMediaSample;
  AudioBuffer: IMediaAudioBuffer;
  VideoCount, AudioCount: Int64;
begin
  Config:=TMediaReaderSettings.Default;
  Config.Channels:=1;
  Reader:=TMediaReader.OpenFile(AFilename, Config);
  VideoCount:=0;
  AudioCount:=0;
  try
    while Reader.ReadSample(Sample) = mrsSample do
      if Sample.Kind = mkVideo then
        Inc(VideoCount)
      else
      if Supports(Sample, IMediaAudioBuffer, AudioBuffer) then
        Inc(AudioCount, AudioBuffer.SampleCount);
  finally
    Reader.Close;
  end;
  Check(VideoCount = AVideoFrames, 'Recorded video decodes every submitted frame');
  Check(AudioCount = AAudioSamples, 'Recorded audio decodes the exact submitted sample count');
end;

procedure TestJitterRecording;
var
  Directory: TMediaTestDirectory;
  State: TMockState;
  Config: TMediaRecordingSettings;
  CaptureConfig: TMediaCaptureSettings;
  Recorded: TMediaRecordingResult;
  Name: String;
begin
  Directory:=TMediaTestDirectory.Create;
  State:=TMockState.Create;
  try
    Config:=TMediaRecordingSettings.OggOpus(1);
    CaptureConfig:=Config.Capture;
    CaptureConfig.AudioDeviceID:='dshow:audio:mock';
    Config.Capture:=CaptureConfig;
    Config.Duration:=TMediaTime.FromMicroseconds(30000);
    State.Push(ckSample, AudioAt(0, 0));
    State.Push(ckSample, AudioAt(1, 12000));
    State.Push(ckSample, AudioAt(2, 21000));
    Name:=Directory.FileName('reported-jitter.opus');
    Recorded:=WriteCaptureRecording(Name, Config, TMockSource.Create(State), nil, nil, nil);
    Check(Recorded.EstimatedAudioTiming AND (Recorded.CaptureStats.AudioTimestampChanges = 2), 'Recording reports its explicit jitter policy');
    Check((Recorded.AudioSamples = 1440) AND (Recorded.Duration.Microseconds = 30000), 'Jitter policy keeps exact PCM duration/count');
    ValidateRecording(Name, 0, 1440);
    State.CheckClosed;
  finally
    State.Free;
    Directory.Free;
  end;
  WriteLn('PASS: jitter-aware recording independently decodes every submitted PCM sample');
end;

procedure TestRecording;
var
  Directory: TMediaTestDirectory;
  State: TMockState;
  Config: TMediaRecordingSettings;
  CaptureConfig: TMediaCaptureSettings;
  OutputConfig: TMediaWriterSettings;
  AudioConfig: TMediaAudioEncoding;
  Recorded: TMediaRecordingResult;
  Observer: TRecordingObserver;
  Stream: TFileStream;
  Text: AnsiString;
  Name: String;
  I, Scenario: Integer;
  Failed: Boolean;
begin
  Directory:=TMediaTestDirectory.Create;
  try
    for Scenario:=0 to 8 do
    begin
      State:=TMockState.Create;
      Observer:=TRecordingObserver.Create(0);
      try
        Config:=TMediaRecordingSettings.H264MP4(2, 2, TMediaRate.Create(30, 1));
        CaptureConfig:=Config.Capture;
        CaptureConfig.VideoDeviceID:='dshow:video:mock';
        Config.Duration:=TMediaTime.FromMicroseconds(200000);
        Config.ProgressIntervalMilliseconds:=0;
        if Scenario = 1 then
        begin
          Config:=TMediaRecordingSettings.OggOpus(1);
          Config.Duration:=TMediaTime.FromMicroseconds(95000);
          CaptureConfig:=Config.Capture;
          CaptureConfig.AudioDeviceID:='dshow:audio:mock';
          for I:=0 to 9 do
            State.Push(ckSample, Audio(I));
        end else
        begin
          for I:=0 to 6 do
            State.Push(ckSample, Video(I));
        end;
        if Scenario = 2 then
        begin
          Config:=TMediaRecordingSettings.H264OpusMatroska(2, 2, TMediaRate.Create(30, 1));
          Config.Duration:=TMediaTime.FromMicroseconds(200000);
          CaptureConfig:=Config.Capture;
          CaptureConfig.VideoDeviceID:='dshow:video:mock';
          CaptureConfig.AudioDeviceID:='dshow:audio:mock';
          CaptureConfig.Channels:=1;
          OutputConfig:=Config.Output;
          AudioConfig:=OutputConfig.Audio;
          AudioConfig.Channels:=1;
          OutputConfig.Audio:=AudioConfig;
          Config.Output:=OutputConfig;
          for I:=0 to 19 do
            State.Push(ckSample, Audio(I));
        end;
        Config.Capture:=CaptureConfig;
        if Scenario >= 3 then
          Observer.FAction:=Scenario - 2;
        if Scenario = 8 then
        begin
          Config.Duration:=TMediaTime.Unknown;
          Observer.FUnknownDuration:=True;
          Observer.FAction:=1;
        end;
        Name:=Directory.FileName('record-' + IntToStr(Scenario) + '.media');
        if Scenario IN [4, 5, 7] then
        begin
          Stream:=TFileStream.Create(Name, fmCreate);
          try
            Text:='sentinel';
            Stream.WriteBuffer(Text[1], Length(Text));
          finally
            Stream.Free;
          end;
          // Reach finalization while preserving an existing destination on abort.
          OutputConfig:=Config.Output;
          OutputConfig.Overwrite:=True;
          Config.Output:=OutputConfig;
        end;
        Failed:=False;
        try
          Recorded:=WriteCaptureRecording(Name, Config, TMockSource.Create(State), Observer.Report, Observer.FStop.Token, Observer.FCancel.Token);
        except
          on E: Exception do
          begin
            Failed:=True;
            if NOT (Scenario IN [4, 5, 6, 7]) then
              raise;
          end;
        end;
        if Scenario IN [4, 5, 7] then
        begin
          Check(Failed AND NOT Observer.FCompleted, 'Pre-publication callback/cancel failure');
          Stream:=TFileStream.Create(Name, fmOpenRead OR fmShareDenyNone);
          try
            SetLength(Text, Stream.Size);
            Stream.ReadBuffer(Text[1], Length(Text));
          finally
            Stream.Free;
          end;
          Check(Text = 'sentinel', 'Aborted recording preserves existing destination');
        end else
        if Scenario = 6 then
        begin
          Check(Failed AND Observer.FCompleted AND FileExists(Name), 'Completed callback failure leaves published output');
          ValidateRecording(Name, 6, 0);
        end else
        begin
          Check(NOT Failed AND Observer.FCompleted, 'Recording completes');
          if Scenario = 1 then
            Check((Recorded.AudioSamples = 4560) AND (Recorded.VideoFrames = 0), 'Audio duration clips a partial PCM buffer')
          else
          if Scenario = 2 then
            Check((Recorded.VideoFrames = 6) AND (Recorded.AudioSamples = 9600), 'Combined recording counters')
          else
          if Scenario IN [3, 8] then
            Check(Recorded.StopReason = mrrRequested, 'Graceful stop has a distinct result')
          else
            Check((Recorded.VideoFrames = 6) AND (Recorded.Duration.Microseconds = 200000), 'Timed video clips to the requested end');
          ValidateRecording(Name, Recorded.VideoFrames, Recorded.AudioSamples);
        end;
        State.CheckClosed;
      finally
        Observer.Free;
        State.Free;
      end;
    end;
  finally
    Directory.Free;
  end;
  WriteLn('PASS: timed/graceful recording, partial audio, complete decode, callback/cancel publication behavior');
end;

procedure Run;
begin
  TestRecording;
  TestJitterRecording;
  TestPreviewAndStop;
  TestOverflow(True, False, False, False);
  TestOverflow(False, True, False, False);
  TestOverflow(False, True, False, True);
  TestOverflow(True, False, True, False);
  TestFailures;
  TestDriftAndMixedBytePressure;
  TestCaptureTimingPolicies;
  TestCancellationAndRepetition;
  WriteLn('PASS: capture production worker/queue lifecycle');
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
