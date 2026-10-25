unit TFFmpeg.Media.Internal.Capture;

interface

uses
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Devices,
  TFFmpeg.Media.Internal.Capture.Source;

function OpenDeviceCapture(const ASettings: TMediaCaptureSettings; const AToken: IMediaCancellationToken): IMediaCapture;
// Test injection exercises the production worker/queues without hardware. Source
// lifecycle and native ownership remain confined to that worker.
function OpenCaptureSource(const ASettings: TMediaCaptureSettings; const ASource: IMediaCaptureSource;
  const AToken: IMediaCancellationToken): IMediaCapture;

implementation

uses
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
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Internal.Capture.DShow;

type
  TCaptureCancellation = class(TInterfacedObject, IMediaCancellationToken)
  private
    FStop: IMediaCancellationToken;
    FExternal: IMediaCancellationToken;
  public
    constructor Create(const AStop, AExternal: IMediaCancellationToken);
    function IsCancellationRequested: Boolean;
    procedure ThrowIfCancellationRequested(const AOperation: String);
  end;

  TMediaCaptureSession = class;

  TCaptureWorker = class(TThread)
  private
    FOwner: TMediaCaptureSession;
    FSource: IMediaCaptureSource;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TMediaCaptureSession; const ASource: IMediaCaptureSource);
  end;

  TCaptureQueueItem = record
    FValue: TMediaCapturedSample;
    FBytes: Integer;
    FKind: TMediaKind;
  end;

  TMediaCaptureSession = class(TInterfacedObject, IMediaCapture)
  private
    FLock: TCriticalSection;
    FReady: TEvent;
    FData: TEvent;
    FWorker: TCaptureWorker;
    FWorkerStarted: Boolean;
    FStop: IMediaCancellationSource;
    FToken: IMediaCancellationToken;
    FExternalToken: IMediaCancellationToken;
    FSettings: TMediaCaptureSettings;
    FState: TMediaCaptureState;
    FInfo: TMediaInfo;
    FStats: TMediaCaptureStats;
    FQueue: Array of TCaptureQueueItem;
    FCount: Integer;
    FVideoDropPending: Boolean;
    FAudioDropPending: Boolean;
    FLastVideo: TMediaTime;
    FLastAudioEnd: TMediaTime;
    FLastAudioDuration: TMediaTime;
    FFirstVideo: TMediaTime;
    FFirstAudio: TMediaTime;
    FVideoPeriod: TMediaTime;
    FVideoRate: TMediaRate;
    FVideoClockError: TMediaTime;
    FAudioClockError: TMediaTime;
    FAudioSamples: Int64;
    FAudioRate: Integer;
    FError: String;
    FErrorCategory: TMediaErrorCategory;
    FHasNativeCode: Boolean;
    FNativeCode: Integer;
    FStopStarted: UInt64;
    procedure CheckFailure;
    procedure RemoveItem(AIndex: Integer);
    procedure ClearQueue;
    function DropOldest(AKind: TMediaKind): Boolean;
    function ObserveSample(const ASample: IMediaSample): Boolean;
    procedure Enqueue(const ASample: IMediaSample; const AInfo: TMediaInfo);
    procedure WorkerLoop(const ASource: IMediaCaptureSource);
    procedure WorkerCancelled;
    procedure WorkerFailed(const AMessage: String; AError: Exception);
    procedure WorkerFinished;
  public
    constructor Create(const ASettings: TMediaCaptureSettings; const ASource: IMediaCaptureSource;
      const AToken: IMediaCancellationToken);
    destructor Destroy; override;
    function GetInfo: TMediaInfo;
    function GetState: TMediaCaptureState;
    function GetStats: TMediaCaptureStats;
    function ReadSample(out ASample: TMediaCapturedSample; AWaitMilliseconds: Cardinal): TMediaCaptureReadStatus;
    procedure Stop;
  end;

function CaptureClock: UInt64;
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

constructor TCaptureCancellation.Create(const AStop, AExternal: IMediaCancellationToken);
begin
  inherited Create;
  FStop:=AStop;
  FExternal:=AExternal;
end;

function TCaptureCancellation.IsCancellationRequested: Boolean;
begin
  Result:=FStop.IsCancellationRequested;
  if NOT Result AND Assigned(FExternal) then
    Result:=FExternal.IsCancellationRequested;
end;

procedure TCaptureCancellation.ThrowIfCancellationRequested(const AOperation: String);
begin
  if IsCancellationRequested then
    raise EMediaCancelled.Create(AOperation);
end;

constructor TCaptureWorker.Create(AOwner: TMediaCaptureSession; const ASource: IMediaCaptureSource);
begin
  inherited Create(True);
  FreeOnTerminate:=False;
  FOwner:=AOwner;
  FSource:=ASource;
end;

procedure TCaptureWorker.Execute;
begin
  try
    try
      FOwner.WorkerLoop(FSource);
    finally
      try
        FSource.Close;
      finally
        FSource:=nil;
      end;
    end;
  except
    on E: EMediaCancelled do
      FOwner.WorkerCancelled;
    on E: Exception do
      FOwner.WorkerFailed(E.ClassName + ': ' + E.Message, E);
    else
      FOwner.WorkerFailed('Unexpected capture worker failure', nil);
  end;
  FOwner.WorkerFinished;
end;

constructor TMediaCaptureSession.Create(const ASettings: TMediaCaptureSettings; const ASource: IMediaCaptureSource;
  const AToken: IMediaCancellationToken);
begin
  inherited Create;
  ASettings.Validate;
  if NOT Assigned(ASource) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Open capture', 'A capture source is required');
  FSettings:=ASettings;
  FState:=mcsOpening;
  FLock:=TCriticalSection.Create;
  FReady:=TEvent.Create(nil, True, False, '');
  FData:=TEvent.Create(nil, True, False, '');
  FStop:=TMediaCancellation.CreateSource;
  FExternalToken:=AToken;
  FToken:=TCaptureCancellation.Create(FStop.Token, AToken);
  SetLength(FQueue, ASettings.MaxVideoFrames + ASettings.MaxAudioBuffers);
  FWorker:=TCaptureWorker.Create(Self, ASource);
  FWorker.Start;
  FWorkerStarted:=True;
  // Open returns only after a negotiated snapshot or a contained worker error.
  // Driver graph construction is synchronous; it cannot safely be detached if
  // that driver's COM call ignores the operation deadline.
  FReady.WaitFor(INFINITE);
  FLock.Acquire;
  try
    CheckFailure;
    if FState = mcsCancelled then
      raise EMediaCancelled.Create('Open capture');
  finally
    FLock.Release;
  end;
end;

destructor TMediaCaptureSession.Destroy;
begin
  // RTL thread destruction may resume a suspended thread after a failed Start.
  // Its first token check must prevent opening a source during partial cleanup.
  if Assigned(FStop) AND NOT FWorkerStarted then
    FStop.Cancel;
  Stop;
  FWorker.Free;
  FWorker:=nil;
  FQueue:=nil;
  FToken:=nil;
  FExternalToken:=nil;
  FStop:=nil;
  FData.Free;
  FReady.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TMediaCaptureSession.CheckFailure;
begin
  if FState = mcsFailed then
    if FHasNativeCode then
      raise EFFmpegMediaError.Create(FErrorCategory, 'Capture', FError, FNativeCode)
    else
      raise EFFmpegMediaError.Create(FErrorCategory, 'Capture', FError);
end;

procedure TMediaCaptureSession.RemoveItem(AIndex: Integer);
var
  I: Integer;
begin
  if FQueue[AIndex].FKind = mkVideo then
    FStats.VideoQueueFrames:=FStats.VideoQueueFrames - 1
  else
    FStats.AudioQueueBuffers:=FStats.AudioQueueBuffers - 1;
  FStats.QueuedBytes:=FStats.QueuedBytes - FQueue[AIndex].FBytes;
  for I:=AIndex to FCount - 2 do
    FQueue[I]:=FQueue[I + 1];
  Dec(FCount);
  FQueue[FCount]:=Default(TCaptureQueueItem);
end;

procedure TMediaCaptureSession.ClearQueue;
begin
  while FCount > 0 do
    RemoveItem(FCount - 1);
end;

function TMediaCaptureSession.DropOldest(AKind: TMediaKind): Boolean;
var
  I: Integer;
begin
  Result:=False;
  for I:=0 to FCount - 1 do
    if FQueue[I].FKind = AKind then
    begin
      RemoveItem(I);
      if AKind = mkVideo then
      begin
        FStats.VideoFramesDropped:=FStats.VideoFramesDropped + 1;
        FVideoDropPending:=True;
      end else
      begin
        FStats.AudioBuffersDropped:=FStats.AudioBuffersDropped + 1;
        FAudioDropPending:=True;
      end;
      Exit(True);
    end;
end;

function TMediaCaptureSession.ObserveSample(const ASample: IMediaSample): Boolean;
var
  Delta, Expected: TMediaTime;
  Audio: IMediaAudioBuffer;
  Tolerance, AllowedJitter: Int64;
  Reason: String;
begin
  Result:=ASample.FormatChanged OR NOT ASample.Timestamp.Valid;
  Reason:='Source format changed';
  if NOT ASample.Timestamp.Valid then
    Reason:='Source timestamp is unknown';
  if ASample.Timestamp.Valid then
  begin
    if ASample.Kind = mkVideo then
    begin
      if FLastVideo.Valid then
      begin
        Delta:=ASample.Timestamp.Subtract(FLastVideo);
        if Delta.Microseconds <= 0 then
        begin
          Result:=True;
          Reason:='Video timestamp did not advance: ' + IntToStr(Delta.Microseconds) + ' us';
        end;
        if FVideoPeriod.Valid AND (Delta.Microseconds > FVideoPeriod.Microseconds + FVideoPeriod.Microseconds DIV 2) then
        begin
          FStats.VideoCadenceChanges:=FStats.VideoCadenceChanges + 1;
          if FSettings.RequireFixedVideoCadence then
          begin
            Result:=True;
            Reason:='Fixed video cadence changed: ' + IntToStr(Delta.Microseconds) + ' us';
          end;
        end;
      end;
      if NOT FFirstVideo.Valid then
        FFirstVideo:=ASample.Timestamp;
      FLastVideo:=ASample.Timestamp;
      if FVideoRate.Known AND FSettings.RequireFixedVideoCadence then
      begin
        Expected:=TMediaTime.FromTicks(FStats.VideoFramesReceived, TMediaRate.Create(FVideoRate.Denominator, FVideoRate.Numerator));
        FVideoClockError:=ASample.Timestamp.Subtract(FFirstVideo).Subtract(Expected);
      end;
    end else
    begin
      if NOT Supports(ASample, IMediaAudioBuffer, Audio) then
        raise EFFmpegMediaError.Create(mecDecode, 'Capture', 'Audio sample has no audio buffer interface');
      if FLastAudioEnd.Valid then
      begin
        Delta:=ASample.Timestamp.Subtract(FLastAudioEnd);
        Tolerance:=1000000 DIV Audio.SampleRate + 2;
        if (Delta.Microseconds > Tolerance) OR (Delta.Microseconds < -Tolerance) then
        begin
          FStats.AudioTimestampChanges:=FStats.AudioTimestampChanges + 1;
          AllowedJitter:=Tolerance;
          if FSettings.AudioTiming = mcatSampleClock then
          begin
            AllowedJitter:=Int64(FSettings.AudioTimestampToleranceMilliseconds) * 1000;
            // Never accept an entire missing native buffer as clock jitter.
            // Short/low-latency buffers tighten, rather than relax, the budget.
            if FLastAudioDuration.Valid AND (AllowedJitter > FLastAudioDuration.Microseconds DIV 2) then
              AllowedJitter:=FLastAudioDuration.Microseconds DIV 2;
            if AllowedJitter < Tolerance then
              AllowedJitter:=Tolerance;
          end;
          if (Delta.Microseconds > AllowedJitter) OR (Delta.Microseconds < -AllowedJitter) then
          begin
            Result:=True;
            Reason:='Audio timestamp gap ' + IntToStr(Delta.Microseconds) + ' us exceeds ' + IntToStr(AllowedJitter) + ' us';
          end;
        end;
      end;
      if NOT FFirstAudio.Valid then
        FFirstAudio:=ASample.Timestamp;
      if FAudioRate = 0 then
        FAudioRate:=Audio.SampleRate;
      if FAudioRate <> Audio.SampleRate then
      begin
        Result:=True;
        Reason:='Audio sample rate changed';
      end;
      Expected:=TMediaTime.FromTicks(FAudioSamples, TMediaRate.Create(1, FAudioRate));
      FAudioClockError:=ASample.Timestamp.Subtract(FFirstAudio).Subtract(Expected);
      FStats.AudioClockDrift:=TMediaTime.FromMicroseconds(FAudioClockError.Microseconds, True);
      Inc(FAudioSamples, Audio.SampleCount);
      FLastAudioDuration:=TMediaTime.FromTicks(Audio.SampleCount, TMediaRate.Create(1, Audio.SampleRate));
      FLastAudioEnd:=ASample.Timestamp.Add(FLastAudioDuration);
      if (FSettings.Policy = mcpRecording) AND (FSettings.AudioTiming = mcatSampleClock) AND
        ((FAudioClockError.Microseconds > Int64(FSettings.MaxClockDriftMilliseconds) * 1000) OR
        (FAudioClockError.Microseconds < -Int64(FSettings.MaxClockDriftMilliseconds) * 1000)) then
        raise EFFmpegMediaError.Create(mecInputOutput, 'Capture', 'Native audio clock divergence exceeds the recording limit');
    end;
    if ASample.Timestamp.Microseconds < 0 then
    begin
      Result:=True;
      Reason:='Source timestamp is negative';
    end;
  end;
  if FVideoClockError.Valid AND FAudioClockError.Valid then
  begin
    // Compare each stream's timestamp residual against its own sample-count
    // clock. Different read/arrival order must not masquerade as clock drift.
    Delta:=FVideoClockError.Subtract(FAudioClockError);
    FStats.AudioVideoDrift:=TMediaTime.FromMicroseconds(Delta.Microseconds, True);
    if (FSettings.Policy = mcpRecording) AND
      ((FStats.AudioVideoDrift.Microseconds > Int64(FSettings.MaxClockDriftMilliseconds) * 1000) OR
      (FStats.AudioVideoDrift.Microseconds < -Int64(FSettings.MaxClockDriftMilliseconds) * 1000)) then
      raise EFFmpegMediaError.Create(mecInputOutput, 'Capture', 'Audio/video clock divergence exceeds the recording limit');
  end;
  if NOT FSettings.RequireFixedVideoCadence AND NOT FSettings.UseVideoDeviceTimestamps AND
    FFirstVideo.Valid AND FAudioClockError.Valid then
    // Graph-clock video has variable cadence. Audio's timestamp/sample-count
    // residual estimates its divergence from that shared reference without
    // falsely treating exposure-dependent frame intervals as clock drift.
    FStats.AudioVideoDrift:=TMediaTime.FromMicroseconds(-FAudioClockError.Microseconds, True);
  if Result then
  begin
    FStats.Discontinuities:=FStats.Discontinuities + 1;
    if FSettings.Policy = mcpRecording then
      raise EFFmpegMediaError.Create(mecInputOutput, 'Capture', Reason);
  end;
end;

function SampleBytes(const ASample: IMediaSample): Integer;
var
  Video: IMediaVideoFrame;
  Audio: IMediaAudioBuffer;
  Count: Int64;
  BytesPerSample: Integer;
begin
  Result:=0;
  Count:=0;
  if (ASample.Kind = mkVideo) AND Supports(ASample, IMediaVideoFrame, Video) then
    Count:=Int64(Video.Stride) * Video.Height
  else
  if (ASample.Kind = mkAudio) AND Supports(ASample, IMediaAudioBuffer, Audio) then
  begin
    BytesPerSample:=2;
    if Audio.SampleFormat = msfFloat32 then
      BytesPerSample:=4;
    Count:=Int64(Audio.SampleCount) * Audio.ChannelLayout.Channels * BytesPerSample;
  end;
  if (Count < 1) OR (Count > MEDIA_MAX_BUFFER_BYTES) then
    raise EFFmpegMediaError.Create(mecDecode, 'Capture', 'Invalid sample kind, interface or buffer size');
  Result:=Integer(Count);
end;

procedure TMediaCaptureSession.Enqueue(const ASample: IMediaSample; const AInfo: TMediaInfo);
var
  ByteCount: Integer;
  Item: TMediaCapturedSample;
  HasSpace: Boolean;
  Audio: IMediaAudioBuffer;
  Timestamp: TMediaTime;
begin
  ByteCount:=SampleBytes(ASample);
  FLock.Acquire;
  try
    FInfo:=AInfo;
    Item:=Default(TMediaCapturedSample);
    Item.Sample:=ASample;
    Item.SourceTimestamp:=ASample.Timestamp;
    Item.Discontinuity:=ObserveSample(ASample);
    if (ASample.Kind = mkAudio) AND (FSettings.AudioTiming = mcatSampleClock) AND FFirstAudio.Valid AND ASample.Timestamp.Valid then
    begin
      Supports(ASample, IMediaAudioBuffer, Audio);
      Timestamp:=FFirstAudio.Add(TMediaTime.FromTicks(FAudioSamples - Audio.SampleCount, TMediaRate.Create(1, Audio.SampleRate), True));
      Item.Sample:=TMediaFrames.CopyAudio(ASample.CopyBytes, Audio.SampleCount, Audio.SampleRate, Audio.SampleFormat,
        Audio.ChannelLayout, Timestamp, Audio.StreamIndex, Audio.FormatChanged);
      Item.TimestampAdjusted:=True;
      FStats.AudioBuffersRetimed:=FStats.AudioBuffersRetimed + 1;
    end;
    if ASample.Kind = mkVideo then
      FStats.VideoFramesReceived:=FStats.VideoFramesReceived + 1
    else
      FStats.AudioBuffersReceived:=FStats.AudioBuffersReceived + 1;
    if ByteCount > FSettings.MaxQueueBytes then
      raise EFFmpegMediaError.Create(mecInputOutput, 'Capture queue', 'One decoded sample exceeds the queue byte limit');
    if (ASample.Kind = mkVideo) AND (FStats.VideoQueueFrames >= FSettings.MaxVideoFrames) then
    begin
      if FSettings.Policy = mcpRecording then
        raise EFFmpegMediaError.Create(mecInputOutput, 'Capture queue', 'Recording video queue overrun');
      DropOldest(mkVideo);
    end;
    if (ASample.Kind = mkAudio) AND (FStats.AudioQueueBuffers >= FSettings.MaxAudioBuffers) then
    begin
      if (FSettings.Policy = mcpRecording) OR (FSettings.AudioOverflow = maoFail) then
        raise EFFmpegMediaError.Create(mecInputOutput, 'Capture queue', 'Audio queue overrun');
      DropOldest(mkAudio);
    end;
    while FStats.QueuedBytes + ByteCount > FSettings.MaxQueueBytes do
    begin
      if FSettings.Policy = mcpRecording then
        raise EFFmpegMediaError.Create(mecInputOutput, 'Capture queue', 'Recording queue byte overrun');
      HasSpace:=DropOldest(mkVideo);
      if NOT HasSpace AND (FSettings.AudioOverflow = maoDropOldest) then
        HasSpace:=DropOldest(mkAudio);
      if NOT HasSpace then
        raise EFFmpegMediaError.Create(mecInputOutput, 'Capture queue', 'Queue byte overrun with no permitted drop');
    end;
    FQueue[FCount].FValue:=Item;
    FQueue[FCount].FBytes:=ByteCount;
    FQueue[FCount].FKind:=ASample.Kind;
    Inc(FCount);
    if ASample.Kind = mkVideo then
      FStats.VideoQueueFrames:=FStats.VideoQueueFrames + 1
    else
      FStats.AudioQueueBuffers:=FStats.AudioQueueBuffers + 1;
    FStats.QueuedBytes:=FStats.QueuedBytes + ByteCount;
    if FStats.QueuedBytes > FStats.PeakQueuedBytes then
      FStats.PeakQueuedBytes:=FStats.QueuedBytes;
    FData.SetEvent;
  finally
    FLock.Release;
  end;
end;

procedure TMediaCaptureSession.WorkerLoop(const ASource: IMediaCaptureSource);
var
  Sample: IMediaSample;
  Status: TMediaReadStatus;
  Info: TMediaInfo;
  Streams: TMediaStreams;
  I: Integer;
begin
  FToken.ThrowIfCancellationRequested('Open capture');
  ASource.Open(FSettings, FToken);
  FToken.ThrowIfCancellationRequested('Open capture');
  Info:=ASource.Info;
  Streams:=Info.Streams;
  for I:=0 to Length(Streams) - 1 do
    if (Streams[I].Kind = mkVideo) AND Streams[I].FrameRate.Known then
    begin
      FVideoRate:=Streams[I].FrameRate;
      FVideoPeriod:=TMediaTime.FromTicks(1, TMediaRate.Create(FVideoRate.Denominator, FVideoRate.Numerator));
    end;
  FLock.Acquire;
  try
    FInfo:=Info;
    FState:=mcsCapturing;
    FReady.SetEvent;
  finally
    FLock.Release;
  end;
  while True do
  begin
    FToken.ThrowIfCancellationRequested('Capture');
    Status:=ASource.ReadSample(Sample);
    FToken.ThrowIfCancellationRequested('Capture');
    case Status of
      mrsSample:
      begin
        if NOT Assigned(Sample) then
          raise EFFmpegMediaError.Create(mecDecode, 'Capture', 'Source returned an empty sample');
        Enqueue(Sample, ASource.Info);
        Sample:=nil;
      end;

      mrsCancelled: raise EMediaCancelled.Create('Capture');
      mrsTimedOut: raise EMediaTimedOut.Create('Capture');
      mrsEndOfInput: raise EFFmpegMediaError.Create(mecInputOutput, 'Capture', 'Device ended or disconnected');
    end;
  end;
end;

procedure TMediaCaptureSession.WorkerCancelled;
var
  Aborted: Boolean;
begin
  // Cancellation takes priority when Stop races an already requested abort.
  // Query outside the queue lock and contain application-token exceptions even
  // on this cleanup path; the source has already closed on the worker.
  try
    Aborted:=Assigned(FExternalToken) AND FExternalToken.IsCancellationRequested;
  except
    on E: Exception do
    begin
      WorkerFailed(E.ClassName + ': ' + E.Message, E);
      Exit;
    end;
    else
    begin
      WorkerFailed('Unexpected cancellation callback failure', nil);
      Exit;
    end;
  end;
  FLock.Acquire;
  try
    if FStop.Token.IsCancellationRequested AND NOT Aborted then
      FState:=mcsStopping
    else
    begin
      FState:=mcsCancelled;
      ClearQueue;
    end;
  finally
    FLock.Release;
  end;
end;

procedure TMediaCaptureSession.WorkerFailed(const AMessage: String; AError: Exception);
begin
  FLock.Acquire;
  try
    FState:=mcsFailed;
    FError:=AMessage;
    FErrorCategory:=mecInputOutput;
    if AError IS EFFmpegMediaError then
    begin
      FErrorCategory:=EFFmpegMediaError(AError).Category;
      FHasNativeCode:=EFFmpegMediaError(AError).HasNativeCode;
      FNativeCode:=EFFmpegMediaError(AError).NativeCode;
    end;
    ClearQueue;
  finally
    FLock.Release;
  end;
end;

procedure TMediaCaptureSession.WorkerFinished;
begin
  FLock.Acquire;
  try
    if NOT (FState IN [mcsCancelled, mcsFailed]) then
      FState:=mcsStopped;
    FReady.SetEvent;
    FData.SetEvent;
  finally
    FLock.Release;
  end;
end;

function TMediaCaptureSession.GetInfo: TMediaInfo;
begin
  Result:=Default(TMediaInfo);
  FLock.Acquire;
  try
    Result:=FInfo;
  finally
    FLock.Release;
  end;
end;

function TMediaCaptureSession.GetState: TMediaCaptureState;
begin
  Result:=mcsFailed;
  FLock.Acquire;
  try
    Result:=FState;
  finally
    FLock.Release;
  end;
end;

function TMediaCaptureSession.GetStats: TMediaCaptureStats;
begin
  Result:=Default(TMediaCaptureStats);
  FLock.Acquire;
  try
    Result:=FStats;
  finally
    FLock.Release;
  end;
end;

function TMediaCaptureSession.ReadSample(out ASample: TMediaCapturedSample; AWaitMilliseconds: Cardinal): TMediaCaptureReadStatus;
var
  Started, Elapsed: UInt64;
  WaitTime: Cardinal;
begin
  Result:=mcrTimedOut;
  ASample:=Default(TMediaCapturedSample);
  Started:=CaptureClock;
  while True do
  begin
    FLock.Acquire;
    try
      CheckFailure;
      if FState = mcsCancelled then
        Exit(mcrCancelled);
      if FCount > 0 then
      begin
        ASample:=FQueue[0].FValue;
        if (FQueue[0].FKind = mkVideo) AND FVideoDropPending then
        begin
          ASample.Discontinuity:=True;
          FVideoDropPending:=False;
        end;
        if (FQueue[0].FKind = mkAudio) AND FAudioDropPending then
        begin
          ASample.Discontinuity:=True;
          FAudioDropPending:=False;
        end;
        RemoveItem(0);
        Exit(mcrSample);
      end;
      if FState = mcsStopped then
        Exit(mcrStopped);
      FData.ResetEvent;
    finally
      FLock.Release;
    end;
    Elapsed:=CaptureClock - Started;
    if Elapsed >= AWaitMilliseconds then
      Exit;
    WaitTime:=AWaitMilliseconds - Cardinal(Elapsed);
    // Small waits also support runtimes whose event waits have no alertable
    // cancellation. Only the worker calls the application's token.
    if WaitTime > 10 then
      WaitTime:=10;
    FData.WaitFor(WaitTime);
  end;
end;

procedure TMediaCaptureSession.Stop;
begin
  if NOT Assigned(FWorker) OR NOT FWorkerStarted then
    Exit;
  FLock.Acquire;
  try
    if FStopStarted = 0 then
      FStopStarted:=CaptureClock;
    if FState IN [mcsOpening, mcsCapturing] then
      FState:=mcsStopping;
    FStop.Cancel;
    FData.SetEvent;
  finally
    FLock.Release;
  end;
  // The worker closes/releases its source before this join returns. No other
  // thread frees a live input, decoder, COM apartment or callback state.
  FWorker.WaitFor;
  FWorkerStarted:=False;
  FLock.Acquire;
  try
    FStats.StopLatencyMilliseconds:=CaptureClock - FStopStarted;
  finally
    FLock.Release;
  end;
end;

function OpenCaptureSource(const ASettings: TMediaCaptureSettings; const ASource: IMediaCaptureSource;
  const AToken: IMediaCancellationToken): IMediaCapture;
begin
  Result:=TMediaCaptureSession.Create(ASettings, ASource, AToken);
end;

function OpenDeviceCapture(const ASettings: TMediaCaptureSettings; const AToken: IMediaCancellationToken): IMediaCapture;
begin
  Result:=nil;
  ASettings.Validate;
  Result:=OpenCaptureSource(ASettings, CreateDShowCaptureSource, AToken);
end;

end.
