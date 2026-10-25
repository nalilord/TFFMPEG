program MediaURLSmoke;

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
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Reader,
  TFFmpeg.Media.Convert,
  MediaTestSupport;

type
  TCancelThread = class(TThread)
  private
    FSource: IMediaCancellationSource;
  protected
    procedure Execute; override;
  public
    constructor Create(const ASource: IMediaCancellationSource);
  end;

constructor TCancelThread.Create(const ASource: IMediaCancellationSource);
begin
  inherited Create(True);
  FreeOnTerminate:=False;
  FSource:=ASource;
end;

procedure TCancelThread.Execute;
begin
  Sleep(150);
  FSource.Cancel;
end;

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

function ReaderSettings: TMediaReaderSettings;
var
  Input: TMediaInputSettings;
begin
  Result:=TMediaReaderSettings.Default;
  Result.VideoStreamIndex:=-2;
  Input:=Result.Input;
  Input.TimeoutMilliseconds:=2000;
  Input.MaxProbeBytes:=65536;
  Input.Options:=[TMediaOption.Create(mosDemuxer, 'http_proxy', '')];
  Result.Input:=Input;
end;

procedure TestRead(const AURL: String; AVerifyTLS: Boolean);
var
  Reader: IMediaReader;
  Settings: TMediaReaderSettings;
  Input: TMediaInputSettings;
  Info: TMediaInfo;
  Sample, Retained: IMediaSample;
  Count: Integer;
begin
  Settings:=ReaderSettings;
  Input:=Settings.Input;
  if NOT AVerifyTLS then
    Input.Options:=[TMediaOption.Create(mosDemuxer, 'http_proxy', ''), TMediaOption.Create(mosDemuxer, 'tls_verify', '0')];
  Settings.Input:=Input;
  Info:=TMediaProbe.ProbeURL(AURL, Input);
  Check((Length(Info.Streams) = 1) AND (Info.Streams[0].Kind = mkAudio) AND (Info.Streams[0].SampleRate = 24000), 'URL probe snapshot');
  Reader:=TMediaReader.OpenURL(AURL, Settings);
  Count:=0;
  Retained:=nil;
  while Reader.ReadSample(Sample) = mrsSample do
  begin
    if NOT Assigned(Retained) then
      Retained:=Sample;
    Inc(Count, (Sample AS IMediaAudioBuffer).SampleCount);
  end;
  Check((Count = 4800) AND NOT Assigned(Sample), 'URL decoded/resampled count and clean EOF');
  Reader.Close;
  Check(Length(Retained.CopyBytes) > 0, 'URL sample ownership survives close');
end;

procedure TestNonseekable(const AURL: String);
var
  Reader: IMediaReader;
begin
  Reader:=TMediaReader.OpenURL(AURL, ReaderSettings);
  Check(NOT Reader.Info.Seekable, 'Server without byte ranges is nonseekable');
  try
    Reader.Seek(TMediaTime.FromMicroseconds(0));
    Check(False, 'Nonseekable URL seek must fail');
  except
    on E: EFFmpegMediaError do
      Check(E.Category = mecUnsupported, 'Nonseekable seek error category');
  end;
  Reader.Close;
end;

procedure TestOpenTimeout(const AURL: String);
var
  Settings: TMediaReaderSettings;
  Input: TMediaInputSettings;
  Reader: IMediaReader;
begin
  Settings:=ReaderSettings;
  Input:=Settings.Input;
  Input.TimeoutMilliseconds:=250;
  Settings.Input:=Input;
  try
    Reader:=TMediaReader.OpenURL(AURL, Settings);
    Check(False, 'Stalled HTTP opening must time out');
  except
    on E: EMediaTimedOut do
      Check(NOT Assigned(Reader), 'Failed URL open returns no session');
  end;
end;

procedure TestReadInterruption(const AURL: String; ACancel: Boolean);
var
  Settings: TMediaReaderSettings;
  Reader: IMediaReader;
  Sample: IMediaSample;
  Status: TMediaReadStatus;
  Source: IMediaCancellationSource;
  Thread: TCancelThread;
  Count: Integer;
begin
  Settings:=ReaderSettings;
  Source:=TMediaCancellation.CreateSource;
  Reader:=TMediaReader.OpenURL(AURL, Settings, Source.Token);
  Thread:=nil;
  if ACancel then
    Thread:=TCancelThread.Create(Source);
  try
    if Assigned(Thread) then
      Thread.Start;
    Count:=0;
    repeat
      Status:=Reader.ReadSample(Sample);
      if Status = mrsSample then
        Inc(Count, (Sample AS IMediaAudioBuffer).SampleCount);
      Check(Count < 1000000, 'Bounded stalled source test');
    until Status <> mrsSample;
    Check(Count > 0, 'Read interruption happens after real decoded samples');
    if ACancel then
      Check(Status = mrsCancelled, 'Concurrent cancellation interrupts native HTTP read')
    else
      Check(Status = mrsTimedOut, 'Stalled native HTTP read reports timeout');
    Check(NOT Assigned(Sample), 'Interrupted URL read clears sample');
    Check(Reader.ReadSample(Sample) = Status, 'Interrupted URL session is terminal');
    Reader.Close;
  finally
    Thread.Free;
  end;
end;

procedure TestRejected(const AURL: String; AKind: Integer);
var
  Settings: TMediaReaderSettings;
  Input: TMediaInputSettings;
  Reader: IMediaReader;
begin
  Settings:=ReaderSettings;
  if AKind = 3 then
  begin
    Input:=Settings.Input;
    Input.Options:=[TMediaOption.Create(mosDemuxer, 'http_proxy', ''), TMediaOption.Create(mosDemuxer, 'tffmpeg_unknown_network_key', '1')];
    Settings.Input:=Input;
  end;
  try
    Reader:=TMediaReader.OpenURL(AURL, Settings);
    Check(False, 'Rejected URL must fail');
  except
    on E: EFFmpegMediaError do
    begin
      case AKind of
        0: Check(E.Category = mecUnsupported, 'Unsupported URL scheme');
        1: Check((E.Category = mecInputOutput) AND E.HasNativeCode, 'Self-signed TLS must fail default certificate validation');
        2: Check((E.Category = mecInputOutput) AND E.HasNativeCode, 'Network redirect cannot open file protocol');
        3: Check((E.Category = mecInvalidSettings) AND (Pos('tffmpeg_unknown_network_key', E.Message) > 0), 'Unconsumed network option diagnostic');
      end;
    end;
  end;
  Check(NOT Assigned(Reader), 'Rejected URL releases context/session');
end;

procedure TestConversion(const AHTTP: String);
var
  Directory: TMediaTestDirectory;
  Settings: TMediaAVConvertSettings;
  Converted: TMediaConversionResult;
  Reader: IMediaReader;
  Sample: IMediaSample;
  Filename: String;
  Count: Integer;
  Search: TSearchRec;
begin
  Directory:=TMediaTestDirectory.Create;
  try
    Settings:=TMediaAVConvertSettings.H264OpusMatroska(32, 24, TMediaRate.Create(10, 1));
    Settings.Input:=ReaderSettings.Input;
    Filename:=Directory.FileName('converted.mka');
    Converted:=TMediaConvert.MediaURL(AHTTP + '/media', Filename, Settings);
    Check((Converted.AudioSamples = 4800) AND (Converted.VideoFrames = 0), 'URL conversion uses selected streams through complete drain');
    Reader:=TMediaReader.OpenFile(Filename, TMediaReaderSettings.Default);
    Count:=0;
    while Reader.ReadSample(Sample) = mrsSample do
      Inc(Count, (Sample AS IMediaAudioBuffer).SampleCount);
    Reader.Close;
    Check(Count = 4800, 'URL converted output decoded sample count');
    Filename:=Directory.FileName('stalled.mka');
    try
      TMediaConvert.MediaURL(AHTTP + '/stall', Filename, Settings);
      Check(False, 'URL conversion read timeout must fail');
    except
      on E: EMediaTimedOut do
        Check(NOT FileExists(Filename), 'Interrupted URL conversion never publishes');
    end;
    if FindFirst(Filename + '.tffmpeg-*', faAnyFile, Search) = 0 then
    begin
      FindClose(Search);
      Check(False, 'Interrupted URL conversion must remove the sibling');
    end;
  finally
    Directory.Free;
  end;
end;

procedure Run;
var
  HTTP, HTTPS: String;
  Reader: IMediaReader;
begin
  Check(ParamCount = 2, 'Run through Tools/run-media-url-tests.py with controlled HTTP/HTTPS servers');
  HTTP:=ParamStr(1);
  HTTPS:=ParamStr(2);
  TestRead(HTTP + '/media', True);
  TestRead(HTTP + '/no-range', True);
  TestNonseekable(HTTP + '/no-range');
  TestOpenTimeout(HTTP + '/delayed-headers');
  TestReadInterruption(HTTP + '/stall', False);
  TestReadInterruption(HTTP + '/stall', True);
  TestRejected('file:///C:/Windows/win.ini', 0);
  TestRejected(HTTP + '/redirect-file', 2);
  TestRejected(HTTPS + '/media', 1);
  TestRejected(HTTP + '/redirect-tls', 1);
  TestRead(HTTPS + '/media', False);
  TestRead(HTTP + '/redirect-tls', False);
  TestRejected(HTTP + '/media', 3);
  TestConversion(HTTP);
  try
    Reader:=TMediaReader.OpenFile(HTTP + '/file-must-not-contact-server', ReaderSettings);
    Check(False, 'OpenFile remains a literal file operation');
  except
    on E: EFFmpegMediaError do
      Check(E.Category = mecInputOutput, 'URL-looking missing literal file is an IO error');
  end;
  TestRead(HTTP + '/media', True);
  WriteLn('PASS: HTTP/HTTPS probe/read, retained samples, range/nonseekable IO, open/read timeouts, concurrent cancellation, TLS verification, redirects and file separation');
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
