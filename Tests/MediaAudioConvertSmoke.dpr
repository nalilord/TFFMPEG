program MediaAudioConvertSmoke;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
{$IFDEF MSWINDOWS}
  Windows,
{$ELSE}
  BaseUnix,
{$ENDIF}
  SysUtils,
  Classes,
{$ELSE}
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Reader,
  TFFmpeg.Media.Writer,
  TFFmpeg.Media.Convert,
  MediaTestSupport;

type
  IDelayedConversionToken = interface(IMediaCancellationToken)
    ['{6ADAD375-CB5F-4F36-9321-10AB174DA3D1}']
    procedure Arm;
  end;

  TDelayedConversionToken = class(TInterfacedObject, IMediaCancellationToken, IDelayedConversionToken)
  private
    FArmed: Boolean;
  public
    procedure Arm;
    function IsCancellationRequested: Boolean;
    procedure ThrowIfCancellationRequested(const AOperation: String);
  end;

  TProgressObserver = class
  private
    FCalls: Array of TMediaProgress;
    FCancelStage: Integer;
    FErrorStage: Integer;
    FSource: IMediaCancellationSource;
    FDestination: String;
    FThreadID: NativeUInt;
    FTimeoutToken: IDelayedConversionToken;
  public
    constructor Create(const ADestination: String);
    procedure Progress(const AProgress: TMediaProgress);
    procedure CheckCalls(AKnownDuration: Boolean; AExpectedBytes: Int64);
    procedure CheckThrottled;
    property CancelStage: Integer read FCancelStage write FCancelStage;
    property ErrorStage: Integer read FErrorStage write FErrorStage;
    property Source: IMediaCancellationSource read FSource write FSource;
    property TimeoutToken: IDelayedConversionToken read FTimeoutToken write FTimeoutToken;
  end;

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

procedure TDelayedConversionToken.Arm;
begin
  FArmed:=True;
end;

function TDelayedConversionToken.IsCancellationRequested: Boolean;
begin
  Result:=False;
  if FArmed then
    Sleep(1100);
end;

procedure TDelayedConversionToken.ThrowIfCancellationRequested(const AOperation: String);
begin
end;

constructor TProgressObserver.Create(const ADestination: String);
begin
  inherited Create;
  FCancelStage:=-1;
  FErrorStage:=-1;
  FDestination:=ADestination;
  FThreadID:=GetCurrentThreadId;
end;

procedure TProgressObserver.Progress(const AProgress: TMediaProgress);
begin
  Check(GetCurrentThreadId = FThreadID, 'Progress runs on the calling thread');
  SetLength(FCalls, Length(FCalls) + 1);
  FCalls[High(FCalls)]:=AProgress;
  if (AProgress.Stage = mpsProcessing) AND Assigned(FTimeoutToken) then
    FTimeoutToken.Arm;
  if AProgress.Stage = mpsCompleted then
    Check(FileExists(FDestination), 'Completion only after publication');
  if (Ord(AProgress.Stage) = FCancelStage) AND ((AProgress.Stage <> mpsProcessing) OR (AProgress.Bytes > 0)) then
    FSource.Cancel;
  if Ord(AProgress.Stage) = FErrorStage then
    raise Exception.Create('Controlled progress callback failure');
end;

procedure TProgressObserver.CheckThrottled;
begin
  Check(Length(FCalls) = 4, 'Throttling suppresses intermediate callbacks while retaining every lifecycle stage');
end;

procedure TProgressObserver.CheckCalls(AKnownDuration: Boolean; AExpectedBytes: Int64);
var
  I: Integer;
  HadFinalizing: Boolean;
begin
  Check((Length(FCalls) >= 4) AND (FCalls[0].Stage = mpsOpening) AND
    (FCalls[High(FCalls)].Stage = mpsCompleted), 'Ordered progress lifecycle');
  HadFinalizing:=False;
  for I:=0 to Length(FCalls) - 1 do
  begin
    HadFinalizing:=HadFinalizing OR (FCalls[I].Stage = mpsFinalizing);
    if FCalls[I].Stage = mpsCompleted then
      Check(HadFinalizing, 'Finalization precedes completion');
    if I > 0 then
    begin
      Check(FCalls[I].Bytes >= FCalls[I - 1].Bytes, 'Monotonic processed PCM bytes');
      Check(FCalls[I].ElapsedMilliseconds >= FCalls[I - 1].ElapsedMilliseconds, 'Monotonic elapsed time');
      Check(FCalls[I].ProcessedTime.Compare(FCalls[I - 1].ProcessedTime) >= 0, 'Monotonic processed time');
    end;
    if FCalls[I].Stage = mpsOpening then
      Check(NOT FCalls[I].Percent.Known, 'Opening duration is not known yet')
    else
      Check(FCalls[I].Percent.Known = AKnownDuration, 'Unknown duration must stay unknown');
    if FCalls[I].Percent.Known AND (FCalls[I].Stage <> mpsCompleted) then
      Check(FCalls[I].Percent.Value < 100, 'No fabricated completion before publication');
  end;
  Check(FCalls[High(FCalls)].Bytes = AExpectedBytes, 'Processed PCM byte semantics');
  if AKnownDuration then
    Check(FCalls[High(FCalls)].Percent.Value = 100, 'Known-duration completed progress');
end;

function Fixture(const AName: String): String;
begin
  Result:=ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + 'fixtures' + PathDelim + AName);
  Check(FileExists(Result), 'Missing fixture ' + Result);
end;

function ReadAudio(const AFilename: String; AChannels: Integer; AStreamIndex: Integer = -1): TBytes;
var
  Reader: IMediaReader;
  Settings: TMediaReaderSettings;
  Sample: IMediaSample;
  Bytes: TBytes;
  Offset: Integer;
begin
  Result:=nil;
  Settings:=TMediaReaderSettings.Default;
  Settings.VideoStreamIndex:=-2;
  Settings.AudioStreamIndex:=AStreamIndex;
  Settings.Channels:=AChannels;
  Reader:=TMediaReader.OpenFile(AFilename, Settings);
  try
    while Reader.ReadSample(Sample) = mrsSample do
    begin
      Bytes:=Sample.CopyBytes;
      Offset:=Length(Result);
      SetLength(Result, Offset + Length(Bytes));
      Move(Bytes[0], Result[Offset], Length(Bytes));
    end;
  finally
    Reader.Close;
  end;
end;

function PCMValue(const ABytes: TBytes; AIndex: Integer): SmallInt;
begin
  Result:=0;
  Move(ABytes[AIndex * 2], Result, 2);
end;

procedure CheckSignal(const ASource, AOutput: TBytes; AChannels: Integer);
var
  I, Count, Lag, BestLag, StartIndex, EndIndex: Integer;
  Sum, EnergySource, EnergyOutput, Correlation, Best: Double;
  SourceValue, OutputValue: Double;
begin
  Check((Length(ASource) = Length(AOutput)) AND (Length(AOutput) > 256 * AChannels), 'Exact decoded sample count, including final partial frame');
  Count:=Length(AOutput) DIV (2 * AChannels);
  EnergySource:=0;
  EnergyOutput:=0;
  Sum:=0;
  for I:=0 to Count - 1 do
  begin
    SourceValue:=PCMValue(ASource, I * AChannels);
    OutputValue:=PCMValue(AOutput, I * AChannels);
    EnergySource:=EnergySource + Sqr(SourceValue);
    EnergyOutput:=EnergyOutput + Sqr(OutputValue);
    Sum:=Sum + SourceValue * OutputValue;
  end;
  Check((EnergySource > Count * 1000000.0) AND (EnergyOutput > Count * 1000000.0), 'Converted signal is non-silent');
  Check(Sum / Sqrt(EnergySource * EnergyOutput) > 0.90, 'Lossy signal correlation');
  if AChannels = 2 then
  begin
    EnergySource:=0;
    EnergyOutput:=0;
    Sum:=0;
    for I:=0 to Count - 1 do
    begin
      SourceValue:=PCMValue(ASource, I * 2 + 1);
      OutputValue:=PCMValue(AOutput, I * 2 + 1);
      EnergySource:=EnergySource + Sqr(SourceValue);
      EnergyOutput:=EnergyOutput + Sqr(OutputValue);
      Sum:=Sum + SourceValue * OutputValue;
    end;
    Check(Sum / Sqrt(EnergySource * EnergyOutput) > 0.90, 'Right channel retains independent signal');
  end;
  for StartIndex:=0 to 1 do
  begin
    EndIndex:=Count - 40;
    I:=40;
    if StartIndex = 0 then
      EndIndex:=200
    else
      I:=Count - 200;
    Best:=-1E300;
    BestLag:=100;
    for Lag:=-30 to 30 do
    begin
      Sum:=0;
      Count:=I;
      while Count < EndIndex do
      begin
        SourceValue:=PCMValue(ASource, Count * AChannels);
        Sum:=Sum + SourceValue * PCMValue(AOutput, (Count + Lag) * AChannels);
        Inc(Count);
      end;
      Correlation:=Sum;
      if Correlation > Best then
      begin
        Best:=Correlation;
        BestLag:=Lag;
      end;
    end;
    Check(Abs(BestLag) <= 3, 'Leading/trailing marker windows retain alignment: ' + IntToStr(BestLag));
    Count:=Length(AOutput) DIV (2 * AChannels);
  end;
end;

function Tag(const AInfo: TMediaInfo; const AKey: String): String;
var
  Metadata: TMediaMetadata;
  Streams: TMediaStreams;
  I, J: Integer;
begin
  Result:='';
  Metadata:=AInfo.Metadata;
  for I:=0 to Length(Metadata) - 1 do
    if SameText(Metadata[I].Key, AKey) then
      Exit(Metadata[I].Value);
  Streams:=AInfo.Streams;
  for J:=0 to Length(Streams) - 1 do
  begin
    Metadata:=Streams[J].Metadata;
    for I:=0 to Length(Metadata) - 1 do
      if SameText(Metadata[I].Key, AKey) then
        Exit(Metadata[I].Value);
  end;
end;

procedure MakeSource(const AFilename: String; AUnknownDuration: Boolean; ASamples: Integer = 1177);
var
  Writer: IMediaWriter;
  Settings: TMediaWriterSettings;
  Encoding: TMediaAudioEncoding;
  Bytes: TBytes;
  I: Integer;
  Value: SmallInt;
begin
  Settings:=TMediaWriterSettings.PCMWave(48000, 2);
  Settings.Metadata:=[TMediaMetadataEntry.Create('title', 'Original synthetic stereo')];
  if AUnknownDuration then
  begin
    Settings.MuxerName:='matroska';
    Settings.Options:=[TMediaOption.Create(mosMuxer, 'live', '1')];
    Encoding:=Settings.Audio;
    Encoding.EncoderName:='flac';
    Settings.Audio:=Encoding;
  end;
  Writer:=TMediaWriter.OpenFile(AFilename, Settings);
  SetLength(Bytes, ASamples * 4);
  for I:=0 to ASamples - 1 do
  begin
    Value:=Round(10000 * Sin(I * 2 * Pi * 1000 / 48000));
    Move(Value, Bytes[I * 4], 2);
    Value:=-Value;
    Move(Value, Bytes[I * 4 + 2], 2);
  end;
  Writer.SubmitAudio(TMediaFrames.CopyAudio(Bytes, ASamples, 48000, msfS16, TMediaChannelLayout.Stereo, TMediaTime.Unknown));
  Writer.Finish;
end;

procedure TestConversion(const ASource, ADestination: String; AChannels: Integer; AExpectedSamples: Integer; AKnownDuration: Boolean);
var
  Settings: TMediaAudioConvertSettings;
  Observer: TProgressObserver;
  Converted: TMediaConversionResult;
  Info: TMediaInfo;
  Streams: TMediaStreams;
  Bytes, Expected: TBytes;
begin
  Settings:=TMediaAudioConvertSettings.OggOpus(AChannels, 128000);
  Settings.ProgressIntervalMilliseconds:=0;
  Observer:=TProgressObserver.Create(ADestination);
  try
    Converted:=TMediaConvert.AudioFile(ASource, ADestination, Settings, Observer.Progress);
    Check((Converted.AudioSamples = AExpectedSamples) AND (Converted.AudioSampleRate = 48000) AND
      (Converted.AudioEncoderName = 'libopus'), 'Conversion result counts and concrete encoder');
    Observer.CheckCalls(AKnownDuration, Int64(AExpectedSamples) * AChannels * 2);
    Info:=TMediaProbe.ProbeFile(ADestination, TMediaInputSettings.Default);
    Streams:=Info.Streams;
    Check((Length(Streams) = 1) AND (Streams[0].Kind = mkAudio) AND (Streams[0].CodecName = 'opus') AND
      NOT Streams[0].AttachedArt, 'One Opus audio track; cover art excluded deliberately');
    Bytes:=ReadAudio(ADestination, AChannels);
    Expected:=ReadAudio(ASource, AChannels);
    CheckSignal(Expected, Bytes, AChannels);
    Check(Length(Bytes) = AExpectedSamples * AChannels * 2, 'Exact Opus delay/padding trim');
    Check(Tag(Info, 'title') = '', 'Default strips source metadata');
  finally
    Observer.Free;
  end;
end;

procedure CheckNoSibling(const AFilename: String);
var
  Search: TSearchRec;
begin
  if FindFirst(AFilename + '.tffmpeg-*', faAnyFile, Search) = 0 then
  begin
    FindClose(Search);
    raise Exception.Create('Leaked conversion sibling');
  end;
end;

procedure Sentinel(const AFilename: String; AWrite: Boolean);
var
  Stream: TFileStream;
  Value: Byte;
begin
  Value:=71;
  if AWrite then
    Stream:=TFileStream.Create(AFilename, fmCreate)
  else
    Stream:=TFileStream.Create(AFilename, fmOpenRead OR fmShareDenyNone);
  try
    if AWrite then
      Stream.WriteBuffer(Value, 1)
    else
    begin
      Check(Stream.Size = 1, 'Failed conversion preserves existing destination');
      Stream.ReadBuffer(Value, 1);
      Check(Value = 71, 'Existing destination content preserved');
    end;
  finally
    Stream.Free;
  end;
end;

procedure TestFailures(const ASource, ADestination, AAlias: String);
var
  Settings: TMediaAudioConvertSettings;
  OutputSettings: TMediaWriterSettings;
  Encoding: TMediaAudioEncoding;
  Observer: TProgressObserver;
  Cancel: IMediaCancellationSource;
  I: Integer;
  Linked: Boolean;
begin
  Settings:=TMediaAudioConvertSettings.OggOpus;
  OutputSettings:=Settings.Output;
  OutputSettings.Overwrite:=True;
  Settings.Output:=OutputSettings;
  Settings.ProgressIntervalMilliseconds:=0;
  try
    TMediaConvert.AudioFile(ASource, ASource, Settings);
    Check(False, 'Same source/destination must be rejected');
  except
    on E: EFFmpegMediaError do
      Check(E.Category = mecInvalidSettings, 'Alias error category');
  end;
{$IFDEF MSWINDOWS}
  Linked:=CreateHardLinkW(PWideChar(UnicodeString(AAlias)), PWideChar(UnicodeString(ASource)), nil);
{$ELSE}
  Linked:=fpLink(PAnsiChar(UTF8String(ASource)), PAnsiChar(UTF8String(AAlias))) = 0;
{$ENDIF}
  Check(Linked, 'Create required hard-link alias fixture');
  try
    TMediaConvert.AudioFile(ASource, AAlias, Settings);
    Check(False, 'Hard-linked source/destination must be rejected');
  except
    on E: EFFmpegMediaError do
      Check(E.Category = mecInvalidSettings, 'Hard-link alias category');
  end;
  Sentinel(ADestination, True);
  Observer:=TProgressObserver.Create(ADestination);
  try
    for I:=Ord(mpsOpening) to Ord(mpsFinalizing) do
    begin
      Cancel:=TMediaCancellation.CreateSource;
      Observer.Source:=Cancel;
      Observer.CancelStage:=I;
      try
        TMediaConvert.AudioFile(ASource, ADestination, Settings, Observer.Progress, Cancel.Token);
        Check(False, 'Cancelled conversion must fail');
      except
        on E: EMediaCancelled do
          Sentinel(ADestination, False);
      end;
      CheckNoSibling(ADestination);
    end;
    Observer.CancelStage:=-1;
    Observer.ErrorStage:=Ord(mpsFinalizing);
    try
      TMediaConvert.AudioFile(ASource, ADestination, Settings, Observer.Progress);
      Check(False, 'Callback failure must propagate');
    except
      on E: Exception do
        Check(E.Message = 'Controlled progress callback failure', 'Callback error identity preserved');
    end;
    Sentinel(ADestination, False);
    CheckNoSibling(ADestination);
    Encoding:=OutputSettings.Audio;
    Encoding.EncoderName:='libopus';
    Encoding.Options:=[TMediaOption.Create(mosEncoder, 'tffmpeg_unrecognized_encoder_key', '1')];
    OutputSettings.Audio:=Encoding;
    Settings.Output:=OutputSettings;
    try
      TMediaConvert.AudioFile(ASource, ADestination, Settings);
      Check(False, 'Unconsumed encoder options must fail');
    except
      on E: EFFmpegMediaError do
        Check((E.Category = mecInvalidSettings) AND (Pos('tffmpeg_unrecognized_encoder_key', E.Message) > 0), 'Unconsumed encoder option diagnostic');
    end;
    Sentinel(ADestination, False);
    CheckNoSibling(ADestination);
    Encoding.Options:=nil;
    OutputSettings.Audio:=Encoding;
    OutputSettings.Options:=[TMediaOption.Create(mosMuxer, 'tffmpeg_unrecognized_muxer_key', '1')];
    Settings.Output:=OutputSettings;
    try
      TMediaConvert.AudioFile(ASource, ADestination, Settings);
      Check(False, 'Unconsumed muxer options must fail');
    except
      on E: EFFmpegMediaError do
        Check((E.Category = mecInvalidSettings) AND (Pos('tffmpeg_unrecognized_muxer_key', E.Message) > 0), 'Unconsumed muxer option diagnostic');
    end;
    Sentinel(ADestination, False);
    CheckNoSibling(ADestination);
    OutputSettings.Options:=nil;
    Settings.Output:=OutputSettings;
    Observer.ErrorStage:=Ord(mpsCompleted);
    try
      TMediaConvert.AudioFile(ASource, ADestination, Settings, Observer.Progress);
      Check(False, 'Completed callback exception must propagate');
    except
      on E: Exception do
        Check(E.Message = 'Controlled progress callback failure', 'Completed callback error identity');
    end;
    Check(Length(ReadAudio(ADestination, 2)) = 1177 * 4, 'Completed callback failure retains successfully published output');
    CheckNoSibling(ADestination);
    Sentinel(ADestination, True);
    Encoding:=OutputSettings.Audio;
    Encoding.EncoderName:='tffmpeg_missing_encoder';
    OutputSettings.Audio:=Encoding;
    Settings.Output:=OutputSettings;
    try
      TMediaConvert.AudioFile(ASource, ADestination, Settings);
      Check(False, 'Missing conversion encoder must fail');
    except
      on E: EFFmpegMediaError do
        Check(E.Category = mecUnsupported, 'Unavailable conversion encoder category');
    end;
    Sentinel(ADestination, False);
    CheckNoSibling(ADestination);
  finally
    Observer.Free;
  end;
end;

procedure TestTimeout(const ASource, ADestination: String);
var
  Observer: TProgressObserver;
  Token: IDelayedConversionToken;
  Settings: TMediaAudioConvertSettings;
  Input: TMediaInputSettings;
  Output: TMediaWriterSettings;
begin
  Sentinel(ADestination, True);
  Settings:=TMediaAudioConvertSettings.OggOpus;
  Input:=Settings.Input;
  Input.TimeoutMilliseconds:=1000;
  Settings.Input:=Input;
  Output:=Settings.Output;
  Output.Overwrite:=True;
  Settings.Output:=Output;
  Token:=TDelayedConversionToken.Create;
  Observer:=TProgressObserver.Create(ADestination);
  try
    Observer.TimeoutToken:=Token;
    try
      TMediaConvert.AudioFile(ASource, ADestination, Settings, Observer.Progress, Token);
      Check(False, 'Native read timeout must propagate through conversion');
    except
      on E: EMediaTimedOut do
        Sentinel(ADestination, False);
    end;
    CheckNoSibling(ADestination);
  finally
    Observer.Free;
  end;
end;

procedure TestTrackSelection(const ADestination: String);
var
  Settings: TMediaAudioConvertSettings;
  Expected, Bytes: TBytes;
  I: Integer;
begin
  Settings:=TMediaAudioConvertSettings.OggOpus(1);
  Settings.AudioStreamIndex:=1;
  TMediaConvert.AudioFile(Fixture('tracks.mkv'), ADestination, Settings);
  Expected:=ReadAudio(Fixture('tracks.mkv'), 1, 1);
  Bytes:=ReadAudio(ADestination, 1);
  CheckSignal(Expected, Bytes, 1);
  Check(Length(Bytes) = 4800 * 2, 'Explicit non-default track count');
  for I:=0 to 1 do
  begin
    Settings.AudioStreamIndex:=0;
    if I = 1 then
      Settings.AudioStreamIndex:=999;
    try
      TMediaConvert.AudioFile(Fixture('tracks.mkv'), ADestination + '.invalid', Settings);
      Check(False, 'Wrong-kind/missing track must fail preflight');
    except
      on E: EFFmpegMediaError do
        Check(E.Category = mecInvalidSettings, 'Track preflight error category');
    end;
    CheckNoSibling(ADestination + '.invalid');
    Check(NOT FileExists(ADestination + '.invalid'), 'Track preflight does not publish');
  end;
end;

procedure Run;
var
  Directory: TMediaTestDirectory;
  Settings: TMediaAudioConvertSettings;
  Info: TMediaInfo;
  SourceName, UnknownName, Destination: String;
  Reader: IMediaReader;
  ReaderSettings: TMediaReaderSettings;
  Sample: IMediaSample;
  Count: Integer;
  Bytes: TBytes;
  Observer: TProgressObserver;
  OutputSettings: TMediaWriterSettings;
begin
  Directory:=TMediaTestDirectory.Create;
  try
    TestConversion(Fixture('cover.mp3'), Directory.FileName('mp3-stereo.ogg'), 2, 4800, True);
    TestConversion(Fixture('cover.mp3'), Directory.FileName('mp3-mono.ogg'), 1, 4800, True);
    SourceName:=Directory.FileName('stereo.wav');
    MakeSource(SourceName, False);
    TestConversion(SourceName, Directory.FileName('stereo.ogg'), 2, 1177, True);
    Settings:=TMediaAudioConvertSettings.OggOpus;
    Settings.MetadataPolicy:=mmpCopyContainerText;
    Destination:=Directory.FileName('metadata.ogg');
    TMediaConvert.AudioFile(SourceName, Destination, Settings);
    Info:=TMediaProbe.ProbeFile(Destination, TMediaInputSettings.Default);
    Check(Tag(Info, 'title') = 'Original synthetic stereo', 'Explicit container text metadata copy');
    OutputSettings:=Settings.Output;
    OutputSettings.Metadata:=[TMediaMetadataEntry.Create('title', 'Explicit title override')];
    Settings.Output:=OutputSettings;
    TMediaConvert.AudioFile(SourceName, Directory.FileName('overridden.ogg'), Settings);
    Info:=TMediaProbe.ProbeFile(Directory.FileName('overridden.ogg'), TMediaInputSettings.Default);
    Check(Tag(Info, 'title') = 'Explicit title override', 'Explicit metadata overrides matching source key');
    Destination:=Directory.FileName('throttled.ogg');
    Observer:=TProgressObserver.Create(Destination);
    try
      Settings.ProgressIntervalMilliseconds:=High(Cardinal);
      TMediaConvert.AudioFile(SourceName, Destination, Settings, Observer.Progress);
      Observer.CheckThrottled;
    finally
      Observer.Free;
    end;
    MakeSource(Directory.FileName('tiny.wav'), False, 73);
    TMediaConvert.AudioFile(Directory.FileName('tiny.wav'), Directory.FileName('tiny.ogg'));
    Bytes:=ReadAudio(Directory.FileName('tiny.ogg'), 2);
    Check(Length(Bytes) = 73 * 4, 'Input shorter than one Opus frame retains exact count');
    UnknownName:=Directory.FileName('unknown-duration.mka');
    MakeSource(UnknownName, True);
    ReaderSettings:=TMediaReaderSettings.Default;
    ReaderSettings.VideoStreamIndex:=-2;
    Reader:=TMediaReader.OpenFile(UnknownName, ReaderSettings);
    Check(NOT Reader.Info.Streams[0].Duration.Valid, 'Fixture has no known stream duration');
    Count:=0;
    while Reader.ReadSample(Sample) = mrsSample do
      Inc(Count, (Sample AS IMediaAudioBuffer).SampleCount);
    Reader.Close;
    TestConversion(UnknownName, Directory.FileName('unknown.ogg'), 2, Count, False);
    TestFailures(SourceName, Directory.FileName('failed.ogg'), Directory.FileName('source-hardlink.wav'));
    TestTimeout(SourceName, Directory.FileName('timeout.ogg'));
    TestTrackSelection(Directory.FileName('selected-track.ogg'));
    WriteLn('PASS: MP3 to Opus, mono/stereo, exact trimming, marker alignment, metadata, unknown progress, aliases, cancel/failure cleanup');
  finally
    Directory.Free;
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
