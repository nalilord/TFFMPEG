unit TFFmpeg.Media.Internal.Recording;

interface

uses
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Recording,
  TFFmpeg.Media.Internal.Capture.Source;

function WriteCaptureRecording(const AFilename: String; const ASettings: TMediaRecordingSettings;
  const ASource: IMediaCaptureSource; AProgress: TMediaProgressCallback;
  const AStopToken, ACancelToken: IMediaCancellationToken): TMediaRecordingResult;

implementation

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
  System.Diagnostics,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Images,
  TFFmpeg.Media.Writer,
  TFFmpeg.Media.Devices,
  TFFmpeg.Media.Internal.Capture;

function RecordingClock: UInt64;
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

function WriteCaptureRecording(const AFilename: String; const ASettings: TMediaRecordingSettings;
  const ASource: IMediaCaptureSource; AProgress: TMediaProgressCallback;
  const AStopToken, ACancelToken: IMediaCancellationToken): TMediaRecordingResult;
var
  Capture: IMediaCapture;
  Writer: IMediaWriter;
  Item, Empty: TMediaCapturedSample;
  Status: TMediaCaptureReadStatus;
  Video, Pending: IMediaVideoFrame;
  Audio: IMediaAudioBuffer;
  PendingTime, PendingDuration, EndTime, SampleEnd, AudioStart: TMediaTime;
  ImageSettings: TMediaImageSettings;
  Streams: TMediaStreams;
  Stream: TMediaStreamInfo;
  Started, LastProgress: UInt64;
  ByteCount, SubmittedBytes: Int64;
  Count, BytesPerSample, I: Integer;
  Bytes: TBytes;
  VideoDone, AudioDone, StopRequested: Boolean;

  procedure CheckCancel;
  begin
    if Assigned(ACancelToken) then
      ACancelToken.ThrowIfCancellationRequested('Record device');
  end;

  procedure Report(AStage: TMediaProgressStage; AForce: Boolean);
  var
    Progress: TMediaProgress;
    NowTime: UInt64;
    Percent: Int64;
  begin
    if NOT Assigned(AProgress) then
      Exit;
    NowTime:=RecordingClock;
    if NOT AForce AND (NowTime - LastProgress < ASettings.ProgressIntervalMilliseconds) then
      Exit;
    LastProgress:=NowTime;
    Progress:=Default(TMediaProgress);
    Progress.Stage:=AStage;
    Progress.ProcessedTime:=Result.Duration;
    Progress.Bytes:=SubmittedBytes;
    Progress.ElapsedMilliseconds:=NowTime - Started;
    if ASettings.Duration.Valid then
    begin
      Percent:=Trunc(Result.Duration.Microseconds / ASettings.Duration.Microseconds * 100);
      if Percent > 99 then
        Percent:=99;
      if AStage = mpsCompleted then
        Percent:=100;
      Progress.Percent:=TMediaOptionalInt64.Create(Percent, AStage <> mpsCompleted);
    end;
    AProgress(Progress);
    CheckCancel;
  end;

  procedure AddBytes(ABytes: Int64);
  begin
    if (ABytes < 0) OR (SubmittedBytes > High(Int64) - ABytes) then
      raise EFFmpegMediaError.Create(mecEncode, 'Record device', 'Processed byte counter overflow');
    Inc(SubmittedBytes, ABytes);
  end;

  procedure AdvanceEnd(const AEnd: TMediaTime);
  begin
    if AEnd.Compare(Result.Duration) > 0 then
      Result.Duration:=AEnd;
  end;

  procedure EmitPending(const AEnd: TMediaTime);
  begin
    if NOT Assigned(Pending) then
      Exit;
    if AEnd.Compare(PendingTime) <= 0 then
      raise EFFmpegMediaError.Create(mecInputOutput, 'Record device', 'Video interval did not advance');
    Writer.SubmitVideoAt(Pending, PendingTime, AEnd.Subtract(PendingTime));
    if Result.VideoFrames = High(Int64) then
      raise EFFmpegMediaError.Create(mecEncode, 'Record device', 'Video counter overflow');
    Result.VideoFrames:=Result.VideoFrames + 1;
    AddBytes(Int64(Pending.Stride) * Pending.Height);
    AdvanceEnd(AEnd);
    Pending:=nil;
  end;

  procedure StopCapture;
  begin
    Capture.Stop;
    // Stop is cleanup and never masks a worker error. Observe the terminal state
    // before publishing, even when enough media had already reached the writer.
    if Capture.State = mcsFailed then
      Capture.ReadSample(Empty, 0);
    if Capture.State = mcsCancelled then
      raise EMediaCancelled.Create('Record device');
  end;

begin
  Result:=Default(TMediaRecordingResult);
  ASettings.Validate;
  if NOT ASettings.Duration.Valid AND NOT Assigned(AStopToken) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Record device', 'Choose a positive duration or provide a graceful-stop token');
  Capture:=nil;
  Writer:=nil;
  Pending:=nil;
  AudioStart:=TMediaTime.Unknown;
  SubmittedBytes:=0;
  Result.Duration:=TMediaTime.FromMicroseconds(0);
  Result.EstimatedAudioTiming:=ASettings.Output.Audio.Enabled AND (ASettings.Capture.AudioTiming = mcatSampleClock);
  if ASettings.Output.Audio.Enabled then
    Result.AudioSampleRate:=ASettings.Capture.SampleRate;
  Result.StopReason:=mrrDuration;
  Started:=RecordingClock;
  LastProgress:=Started;
  VideoDone:=NOT ASettings.Output.Video.Enabled;
  AudioDone:=NOT ASettings.Output.Audio.Enabled;
  StopRequested:=False;
  ImageSettings:=ASettings.Image;
  ImageSettings.Width:=ASettings.Output.Video.Width;
  ImageSettings.Height:=ASettings.Output.Video.Height;
  try
    CheckCancel;
    Report(mpsOpening, True);
    // Preflight before a live source starts filling bounded queues.
    Writer:=TMediaWriter.OpenFile(AFilename, ASettings.Output, ACancelToken);
    Result.VideoEncoderName:=Writer.VideoEncoderName;
    Result.AudioEncoderName:=Writer.AudioEncoderName;
    if Assigned(ASource) then
      Capture:=OpenCaptureSource(ASettings.Capture, ASource, ACancelToken)
    else
      Capture:=TMediaDevices.OpenCapture(ASettings.Capture, ACancelToken);
    Result.Negotiated:=Capture.Info;
    Report(mpsProcessing, True);
    while True do
    begin
      CheckCancel;
      if NOT StopRequested AND Assigned(AStopToken) AND AStopToken.IsCancellationRequested then
      begin
        StopRequested:=True;
        Result.StopReason:=mrrRequested;
        StopCapture;
      end;
      if VideoDone AND AudioDone then
      begin
        StopCapture;
        Break;
      end;
      Status:=Capture.ReadSample(Item, 50);
      case Status of
        mcrTimedOut: Continue;
        mcrCancelled: raise EMediaCancelled.Create('Record device');
        mcrStopped: Break;
      end;
      if Item.Discontinuity then
        raise EFFmpegMediaError.Create(mecInputOutput, 'Record device', 'A capture discontinuity prevents complete recording');
      if Item.Sample.Kind = mkVideo then
      begin
        if VideoDone then
          Continue;
        if NOT Supports(Item.Sample, IMediaVideoFrame, Video) then
          raise EFFmpegMediaError.Create(mecDecode, 'Record device', 'Missing public video interface');
        EndTime:=Video.Timestamp;
        if ASettings.Duration.Valid AND (EndTime.Compare(ASettings.Duration) >= 0) then
        begin
          EmitPending(ASettings.Duration);
          VideoDone:=True;
          Continue;
        end;
        EmitPending(EndTime);
        Streams:=Capture.Info.Streams;
        Stream:=Default(TMediaStreamInfo);
        for I:=0 to Length(Streams) - 1 do
          if Streams[I].Index = Video.StreamIndex then
            Stream:=Streams[I];
        Pending:=TMediaImages.Render(Video, Stream, ImageSettings, ACancelToken);
        PendingTime:=Video.Timestamp;
        PendingDuration:=Video.Duration;
        if NOT PendingDuration.Valid OR (PendingDuration.Microseconds <= 0) then
        begin
          if Stream.FrameRate.Known then
            PendingDuration:=TMediaTime.FromTicks(1, TMediaRate.Create(Stream.FrameRate.Denominator, Stream.FrameRate.Numerator))
          else
            PendingDuration:=TMediaTime.FromTicks(1,
              TMediaRate.Create(ASettings.Output.Video.FrameRate.Denominator, ASettings.Output.Video.FrameRate.Numerator));
        end;
      end else
      if Item.Sample.Kind = mkAudio then
      begin
        if AudioDone then
          Continue;
        if NOT Supports(Item.Sample, IMediaAudioBuffer, Audio) then
          raise EFFmpegMediaError.Create(mecDecode, 'Record device', 'Missing public audio interface');
        Count:=Audio.SampleCount;
        SampleEnd:=Audio.Timestamp.Add(TMediaTime.FromTicks(Count, TMediaRate.Create(1, Audio.SampleRate)));
        if ASettings.Duration.Valid AND (SampleEnd.Compare(ASettings.Duration) >= 0) then
        begin
          AudioDone:=True;
          Count:=0;
          if Audio.Timestamp.Compare(ASettings.Duration) < 0 then
            Count:=Integer(ASettings.Duration.Subtract(Audio.Timestamp).ToTicks(TMediaRate.Create(1, Audio.SampleRate)));
          if Count > Audio.SampleCount then
            Count:=Audio.SampleCount;
        end;
        if Count > 0 then
        begin
          BytesPerSample:=2;
          if Audio.SampleFormat = msfFloat32 then
            BytesPerSample:=4;
          ByteCount:=Int64(Count) * Audio.ChannelLayout.Channels * BytesPerSample;
          if Count <> Audio.SampleCount then
          begin
            Bytes:=Audio.CopyBytes;
            Bytes:=Copy(Bytes, 0, Integer(ByteCount));
            Audio:=TMediaFrames.CopyAudio(Bytes, Count, Audio.SampleRate, Audio.SampleFormat, Audio.ChannelLayout, Audio.Timestamp, Audio.StreamIndex);
          end;
          Writer.SubmitAudio(Audio);
          if NOT AudioStart.Valid then
            AudioStart:=Audio.Timestamp;
          if Result.AudioSamples > High(Int64) - Count then
            raise EFFmpegMediaError.Create(mecEncode, 'Record device', 'Audio counter overflow');
          Result.AudioSamples:=Result.AudioSamples + Count;
          AddBytes(ByteCount);
          // Account from one anchor/count rather than summing individually
          // truncated microsecond buffer durations at a clipped final prefix.
          AdvanceEnd(AudioStart.Add(TMediaTime.FromTicks(Result.AudioSamples, TMediaRate.Create(1, Audio.SampleRate))));
        end;
      end else
        raise EFFmpegMediaError.Create(mecDecode, 'Record device', 'Unexpected captured media kind');
      Report(mpsProcessing, False);
    end;
    StopCapture;
    if Assigned(Pending) then
    begin
      EndTime:=PendingTime.Add(PendingDuration);
      if ASettings.Duration.Valid AND (EndTime.Compare(ASettings.Duration) > 0) then
        EndTime:=ASettings.Duration;
      EmitPending(EndTime);
    end;
    if (ASettings.Output.Video.Enabled AND (Result.VideoFrames = 0)) OR
      (ASettings.Output.Audio.Enabled AND (Result.AudioSamples = 0)) then
      raise EFFmpegMediaError.Create(mecInvalidState, 'Record device', 'Recording stopped before every selected stream produced media');
    Result.CaptureStats:=Capture.Stats;
    Report(mpsFinalizing, True);
    CheckCancel;
    Writer.Finish;
    Result.ElapsedMilliseconds:=RecordingClock - Started;
    Report(mpsCompleted, True);
  finally
    try
      if Assigned(Capture) then
        Capture.Stop;
    finally
      if Assigned(Writer) AND (Writer.State <> mwsFinished) then
        Writer.Abort;
    end;
  end;
end;

end.
