program GrabFrame;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  TFFmpeg.Media,
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Images,
  TFFmpeg.Media.Errors;

procedure Run;
var
  Position: Double;
  Screenshot: TMediaScreenshot;
  Settings: TFormatSettings;
begin
  if ParamCount <> 3 then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'GrabFrame', 'Usage: GrabFrame <local media> <seconds with decimal dot> <output.bmp|png|jpg>');
{$IFDEF FPC}
  Settings:=DefaultFormatSettings;
{$ELSE}
  Settings:=TFormatSettings.Create;
{$ENDIF}
  Settings.DecimalSeparator:='.';
  if NOT TryStrToFloat(ParamStr(2), Position, Settings) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'GrabFrame', 'Position must be a number of seconds');
  Screenshot:=TFFmpegMedia.SaveScreenshot(ParamStr(1), TMediaTime.FromSeconds(Position), ParamStr(3));
  WriteLn('Requested ', Screenshot.RequestedTime.Seconds:0:6, ' s, selected ', Screenshot.ActualTime.Seconds:0:6, ' s; ',
    Screenshot.Frame.Width, 'x', Screenshot.Frame.Height);
end;

begin
  try
    Run;
  except
    on E: EFFmpegMediaError do
    begin
      WriteLn(E.Message);
      Halt(1);
    end;
  end;
end.
