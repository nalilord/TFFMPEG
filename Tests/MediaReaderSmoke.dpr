program MediaReaderSmoke;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
  Classes,
{$ELSE}
  System.SysUtils,
  System.Classes,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Reader,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Errors;

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

type
  IMediaDelayedTestToken = interface(IMediaCancellationToken)
    ['{55B56280-015F-496D-B59B-43E9E3422C45}']
    procedure SetDelay(AMilliseconds: Cardinal);
  end;

  TMediaDelayedTestToken = class(TInterfacedObject, IMediaCancellationToken, IMediaDelayedTestToken)
  private
    FDelay: Cardinal;
  public
    procedure SetDelay(AMilliseconds: Cardinal);
    function IsCancellationRequested: Boolean;
    procedure ThrowIfCancellationRequested(const AOperation: String);
  end;

procedure TMediaDelayedTestToken.SetDelay(AMilliseconds: Cardinal);
begin
  FDelay:=AMilliseconds;
end;

function TMediaDelayedTestToken.IsCancellationRequested: Boolean;
begin
  Result:=False;
  if FDelay > 0 then
    Sleep(FDelay);
end;

procedure TMediaDelayedTestToken.ThrowIfCancellationRequested(const AOperation: String);
begin
  // This test token never cancels. Its controlled delay exercises elapsed timeout.
end;

function Fixture(const AName: String): String;
begin
  Result:=ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + 'fixtures' + PathDelim + AName);
end;

procedure TestVideoAndMixed;
var
  Reader: IMediaReader;
  Sample: IMediaSample;
  Video, Retained: IMediaVideoFrame;
  Audio: IMediaAudioBuffer;
  Status: TMediaReadStatus;
  Bytes, Saved: TBytes;
  Frames: Integer;
  Samples: Int64;
  I: Integer;
begin
  Reader:=TMediaReader.OpenFile(Fixture('multi.mkv'), TMediaReaderSettings.Default);
  Frames:=0;
  Samples:=0;
  repeat
    Status:=Reader.ReadSample(Sample);
    if Status = mrsSample then
    begin
      Check(Assigned(Sample), 'Sample status requires non-nil output');
      if Supports(Sample, IMediaVideoFrame, Video) then
      begin
        Check(Frames < 3, 'Unexpected extra video frame');
        Check((Video.Width = 16) AND (Video.Height = 12) AND (Video.Stride = 64), 'Decoded video geometry');
        Check(Video.Timestamp.Microseconds = Int64(Frames) * 100000, 'Video presentation timestamps');
        Bytes:=Video.CopyBytes;
        Check((Bytes[(2 - Frames) MOD 3] = 255) AND (Bytes[3] = 255), 'Red/green/blue identity and opaque alpha');
        if Frames = 0 then
        begin
          Retained:=Video;
          Saved:=Video.CopyBytes;
        end;
        Inc(Frames);
      end else
      begin
        Check(Supports(Sample, IMediaAudioBuffer, Audio), 'Audio/video tagged dispatch');
        Check((Audio.StreamIndex = 2) AND (Audio.SampleRate = 48000) AND (Audio.ChannelLayout.Channels = 2), 'Selected default audio conversion');
        Check(Audio.Timestamp.Microseconds = TMediaTime.FromTicks(Samples, TMediaRate.Create(1, 48000)).Microseconds, 'Sample-count audio timestamps');
        Inc(Samples, Audio.SampleCount);
      end;
    end;
  until Status <> mrsSample;
  Check((Status = mrsEndOfInput) AND NOT Assigned(Sample), 'EOF clears output');
  Check((Frames = 3) AND (Samples = 4800), 'All selected decoders and resampler must drain completely');
  Check(Reader.ReadSample(Sample) = mrsEndOfInput, 'Repeated EOF');

  Reader.Seek(TMediaTime.FromSeconds(0));
  Frames:=0;
  Samples:=0;
  while Reader.ReadSample(Sample) = mrsSample do
    if Sample.Kind = mkVideo then
      Inc(Frames)
    else
    begin
      Audio:=Sample AS IMediaAudioBuffer;
      Inc(Samples, Audio.SampleCount);
    end;
  Check((Frames = 3) AND (Samples = 4800), 'Seek after EOF resets decoders and resampler');
  Reader.Close;
  Reader.Close;
  Reader:=nil;
  Bytes:=Retained.CopyBytes;
  Check((Length(Bytes) = Length(Saved)) AND CompareMem(@Bytes[0], @Saved[0], Length(Bytes)), 'Retained frame survives reads, seek and close');
  Bytes[0]:=89;
  Bytes:=Retained.CopyBytes;
  Check(Bytes[0] = Saved[0], 'Retained native frame exposes only independent copies');
  for I:=0 to 9 do
  begin
    Reader:=TMediaReader.OpenFile(Fixture('video.mkv'), TMediaReaderSettings.Default);
    Check(Reader.ReadSample(Sample) = mrsSample, 'Repeated open/read');
    Reader:=nil;
  end;
  WriteLn('PASS: single AV demux pump, exact lossless video identity/timing, default audio routing, full drain and retained frames after seek/close');
end;

procedure TestPCMAndCancellation;
var
  Settings: TMediaReaderSettings;
  Reader: IMediaReader;
  Sample: IMediaSample;
  Audio, Retained: IMediaAudioBuffer;
  Bytes, SourceBytes: TBytes;
  Stream: TFileStream;
  Source: IMediaCancellationSource;
  Count: Integer;
  FirstValue, LastValue: SmallInt;
  Failed: Boolean;
begin
  Settings:=TMediaReaderSettings.Default;
  Settings.SampleRate:=24000;
  Settings.Channels:=1;
  Settings.VideoStreamIndex:=-2;
  Stream:=TFileStream.Create(Fixture('markers.wav'), fmOpenRead OR fmShareDenyWrite);
  try
    SetLength(SourceBytes, Stream.Size);
    Stream.ReadBuffer(SourceBytes[0], Length(SourceBytes));
  finally
    Stream.Free;
  end;
  Reader:=TMediaReader.OpenBytes(SourceBytes, Settings);
  FillChar(SourceBytes[0], Length(SourceBytes), 0);
  SourceBytes:=nil;
  Count:=0;
  FirstValue:=0;
  LastValue:=0;
  while Reader.ReadSample(Sample) = mrsSample do
  begin
    Audio:=Sample AS IMediaAudioBuffer;
    Bytes:=Audio.CopyBytes;
    if Count = 0 then
    begin
      FirstValue:=PSmallInt(@Bytes[0])^;
      Retained:=Audio;
    end;
    LastValue:=PSmallInt(@Bytes[Length(Bytes) - 2])^;
    Inc(Count, Audio.SampleCount);
  end;
  Check((Count = 2400) AND (FirstValue = 1234) AND (LastValue = -2345), 'PCM exact sample count and edge markers');
  Reader:=nil;
  Bytes:=Retained.CopyBytes;
  Check(PSmallInt(@Bytes[0])^ = 1234, 'Retained PCM survives reader destruction');

  Settings.SampleFormat:=msfFloat32;
  Source:=TMediaCancellation.CreateSource;
  Reader:=TMediaReader.OpenFile(Fixture('markers.wav'), Settings, Source.Token);
  Check(Reader.ReadSample(Sample) = mrsSample, 'Float PCM read');
  Audio:=Sample AS IMediaAudioBuffer;
  Bytes:=Audio.CopyBytes;
  Check((Audio.SampleFormat = msfFloat32) AND (Abs(PSingle(@Bytes[0])^ - 1234 / 32768) < 0.00001), 'Float signal conversion');
  Source.Cancel;
  Check((Reader.ReadSample(Sample) = mrsCancelled) AND NOT Assigned(Sample), 'Cancellation clears stale sample');
  Check(Reader.ReadSample(Sample) = mrsCancelled, 'Cancellation is terminal');
  Reader.Close;
  Failed:=False;
  try
    Reader.ReadSample(Sample);
  except
    on E: EFFmpegMediaError do
      Failed:=E.Category = mecInvalidState;
  end;
  Check(Failed AND NOT Assigned(Sample), 'Closed read rejects lifecycle and clears output');
  WriteLn('PASS: copied byte input, exact PCM/edge samples, float conversion, retained audio and terminal cancellation');
end;

procedure TestLifecycleAndLimits;
var
  Settings: TMediaReaderSettings;
  Reader: IMediaReader;
  Sample: IMediaSample;
  Failed: Boolean;
  I: Integer;
begin
  Settings:=TMediaReaderSettings.Default;
  Settings.AudioStreamIndex:=-2;
  Reader:=TMediaReader.OpenFile(Fixture('video.mkv'), Settings);
  for I:=0 to 2 do
  begin
    Failed:=False;
    try
      case I of
        0: Reader.Seek(TMediaTime.FromSeconds(-0.1));
        1: Reader.Seek(TMediaTime.Unknown);
        2: Reader.Seek(TMediaTime.FromSeconds(1));
      end;
    except
      on E: EFFmpegMediaError do
        Failed:=E.Category = mecInvalidSettings;
    end;
    Check(Failed, 'Invalid seek must fail explicitly');
  end;
  Check(Reader.ReadSample(Sample) = mrsSample, 'Invalid seek guards leave reader usable');
  Reader.Close;
  Check(Length(Reader.Info.Streams) = 1, 'Snapshot remains available after close');
  Settings.MaxPacketBytes:=1;
  Reader:=TMediaReader.OpenFile(Fixture('video.mkv'), Settings);
  Failed:=False;
  try
    Reader.ReadSample(Sample);
  except
    on E: EFFmpegMediaError do
      Failed:=E.Category = mecDecode;
  end;
  Check(Failed AND NOT Assigned(Sample), 'Packet size bound must fail without stale output');
  Failed:=False;
  try
    Reader.ReadSample(Sample);
  except
    on E: EFFmpegMediaError do
      Failed:=E.Category = mecInvalidState;
  end;
  Check(Failed, 'Failed decoder session requires reopen');
  Reader:=nil;
  Failed:=False;
  try
    Reader:=TMediaReader.OpenFile(Fixture('channels33.wav'), TMediaReaderSettings.Default);
  except
    on E: EFFmpegMediaError do
      Failed:=E.Category = mecUnsupported;
  end;
  Check(Failed, 'Selected audio layout must respect decode limits without blocking inspection');
  WriteLn('PASS: seek guards, detached closed-session info, bounded packet failure and failed-reader lifecycle');
end;

procedure TestReadTimeout;
var
  Token: IMediaDelayedTestToken;
  Reader: IMediaReader;
  Settings: TMediaReaderSettings;
  InputSettings: TMediaInputSettings;
  Sample: IMediaSample;
  Failed: Boolean;
begin
  Token:=TMediaDelayedTestToken.Create;
  Settings:=TMediaReaderSettings.Default;
  InputSettings:=Settings.Input;
  InputSettings.TimeoutMilliseconds:=1000;
  Settings.Input:=InputSettings;
  Reader:=TMediaReader.OpenFile(Fixture('markers.wav'), Settings, Token);
  Check(Reader.ReadSample(Sample) = mrsSample, 'Read before timeout');
  Token.SetDelay(1010);
  Check((Reader.ReadSample(Sample) = mrsTimedOut) AND NOT Assigned(Sample), 'Elapsed read timeout clears output');
  Check(Reader.ReadSample(Sample) = mrsTimedOut, 'Read timeout is terminal');
  Reader.Close;
  Token.SetDelay(0);
  Reader:=TMediaReader.OpenFile(Fixture('markers.wav'), Settings, Token);
  Token.SetDelay(1010);
  Failed:=False;
  try
    Reader.Seek(TMediaTime.FromSeconds(0));
  except
    on E: EMediaTimedOut do
      Failed:=True;
  end;
  Check(Failed, 'Seek must use a dedicated timeout exception');
  Check((Reader.ReadSample(Sample) = mrsTimedOut) AND NOT Assigned(Sample), 'Timed-out seek leaves a terminal session');
  Reader.Close;
  WriteLn('PASS: elapsed read/seek timeout, stale-output clearing and terminal interrupted state');
end;

begin
  try
    TestVideoAndMixed;
    TestPCMAndCancellation;
    TestLifecycleAndLimits;
    TestReadTimeout;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
