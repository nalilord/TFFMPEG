program MediaDeviceRateSmoke;

{$APPTYPE CONSOLE}
{$R+}
{$Q+}

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
{$IFDEF MSWINDOWS}
  libavutil_rational,
  libavutil_parseutils,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Internal.Capture.DShow;

procedure Run;
{$IFDEF MSWINDOWS}
var
  Rates: Array[0..7] of TMediaRate;
  Native: TAVRational;
  Value: UTF8String;
  Expected, Actual: Int64;
  I: Integer;
{$ENDIF}
begin
{$IFDEF MSWINDOWS}
  Rates[0]:=TMediaRate.Create(30, 1);
  Rates[1]:=TMediaRate.Create(30000, 1001);
  Rates[2]:=TMediaRate.Create(10000000, 333333);
  Rates[3]:=TMediaRate.Create(5000000, 208333);
  Rates[4]:=TMediaRate.Create(10000000, 1333333);
  Rates[5]:=TMediaRate.Create(5, 1);
  Rates[6]:=TMediaRate.Create(240000, 1001);
  Rates[7]:=TMediaRate.Create(10000000, 666666);
  for I:=0 to High(Rates) do
  begin
    Expected:=Int64(10000000) * Rates[I].Denominator DIV Rates[I].Numerator;
    Value:=UTF8String(DShowFrameRateText(Rates[I]));
    if av_parse_video_rate(@Native, PAnsiChar(Value)) < 0 then
      raise Exception.Create('Native parser rejected the device rate');
    Actual:=Int64(10000000) * Native.den DIV Native.num;
    if Expected <> Actual then
      raise Exception.Create('Device frame interval changed across native parser quantization');
    WriteLn('Rate ', Rates[I].Numerator, '/', Rates[I].Denominator, ' -> ', String(Value), '; native interval=', Actual, ' ticks');
  end;
  WriteLn('PASS: native DirectShow interval survives FFmpeg rate-parser reduction');
{$ELSE}
  WriteLn('DirectShow rate runtime test requires Delphi Windows; no native qualification on this platform.');
{$ENDIF}
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
