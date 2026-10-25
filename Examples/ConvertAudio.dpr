program ConvertAudio;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Writer,
  TFFmpeg.Media.Convert;

type
  TConsoleProgress = class
  private
    FSource: IMediaCancellationSource;
    FCancelAfterMilliseconds: UInt64;
  public
    constructor Create(const ASource: IMediaCancellationSource; ACancelAfterMilliseconds: UInt64);
    procedure Progress(const AProgress: TMediaProgress);
  end;

constructor TConsoleProgress.Create(const ASource: IMediaCancellationSource; ACancelAfterMilliseconds: UInt64);
begin
  inherited Create;
  FSource:=ASource;
  FCancelAfterMilliseconds:=ACancelAfterMilliseconds;
end;

procedure TConsoleProgress.Progress(const AProgress: TMediaProgress);
const
  Stages: Array[TMediaProgressStage] of String = ('Opening', 'Processing', 'Finalizing', 'Completed');
begin
  Write(Stages[AProgress.Stage], ': ', AProgress.ProcessedTime.Seconds:0:3, ' seconds, ', AProgress.Bytes, ' PCM bytes');
  if AProgress.Percent.Known then
    Write(', ', AProgress.Percent.Value, '%');
  WriteLn;
  // Applications can also cancel this source from another thread. This optional
  // command-line demonstration requests cancellation at the next progress report.
  if (FCancelAfterMilliseconds <> 0) AND (AProgress.ElapsedMilliseconds >= FCancelAfterMilliseconds) AND
    (AProgress.Stage <> mpsCompleted) then
    FSource.Cancel;
end;

procedure Run;
var
  Settings: TMediaAudioConvertSettings;
  Input: TMediaInputSettings;
  Output: TMediaWriterSettings;
  Source: IMediaCancellationSource;
  Observer: TConsoleProgress;
  Converted: TMediaConversionResult;
  CancelAfter: UInt64;
begin
  if (ParamCount < 2) OR (ParamCount > 3) then
    raise Exception.Create('Usage: ConvertAudio input.mp3 output.ogg [cancel-after-ms]; stereo, 48 kHz, 128000 bits/s, no overwrite');
  CancelAfter:=0;
  if ParamCount = 3 then
    CancelAfter:=StrToUInt64(ParamStr(3));
  Settings:=TMediaAudioConvertSettings.OggOpus(2, 128000);
  Input:=Settings.Input;
  Input.TimeoutMilliseconds:=5000;
  Settings.Input:=Input;
  Output:=Settings.Output;
  Output.TimeoutMilliseconds:=5000;
  Settings.Output:=Output;
  Source:=TMediaCancellation.CreateSource;
  Observer:=TConsoleProgress.Create(Source, CancelAfter);
  try
    Converted:=TMediaConvert.AudioFile(ParamStr(1), ParamStr(2), Settings, Observer.Progress, Source.Token);
    WriteLn('Published ', Converted.AudioSamples, ' samples/channel with ', Converted.AudioEncoderName);
  finally
    Observer.Free;
  end;
end;

begin
  try
    Run;
  except
    on E: EMediaCancelled do
    begin
      WriteLn(E.Message);
      Halt(2);
    end;
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
