program ConvertVideo;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Writer,
  TFFmpeg.Media.Convert;

procedure Run;
var
  Settings: TMediaAVConvertSettings;
  Input: TMediaInputSettings;
  Output: TMediaWriterSettings;
  Converted: TMediaConversionResult;
  I: Integer;
  UseURL: Boolean;
begin
  if ParamCount < 2 then
    raise Exception.Create('Usage: ConvertVideo input output.mkv [--cfr] [--url]; H264/Opus, 1280x720 fit, no overwrite');
  Settings:=TMediaAVConvertSettings.H264OpusMatroska(1280, 720, TMediaRate.Create(30000, 1001));
  UseURL:=False;
  for I:=3 to ParamCount do
    if ParamStr(I) = '--cfr' then
      Settings.VideoTiming:=mvpConstantRate
    else
    if ParamStr(I) = '--url' then
      UseURL:=True
    else
      raise Exception.Create('Unknown option: ' + ParamStr(I));
  Input:=Settings.Input;
  Input.TimeoutMilliseconds:=5000;
  Settings.Input:=Input;
  Output:=Settings.Output;
  Output.TimeoutMilliseconds:=5000;
  Settings.Output:=Output;
  if UseURL then
    Converted:=TMediaConvert.MediaURL(ParamStr(1), ParamStr(2), Settings)
  else
    Converted:=TMediaConvert.MediaFile(ParamStr(1), ParamStr(2), Settings);
  WriteLn('Published ', Converted.VideoFrames, ' video frames and ', Converted.AudioSamples, ' audio samples/channel');
  WriteLn('Encoders: ', Converted.VideoEncoderName, ' / ', Converted.AudioEncoderName);
  WriteLn('Duplicated ', Converted.DuplicatedFrames, '; dropped ', Converted.DroppedFrames,
    '; duration ', Converted.Duration.Seconds:0:3, ' seconds');
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
