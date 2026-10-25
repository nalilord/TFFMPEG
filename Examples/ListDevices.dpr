program ListDevices;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Devices;

function StatusText(AStatus: TMediaDeviceQueryStatus): String;
begin
  Result:='unsupported';
  case AStatus of
    mdqsAvailable: Result:='available';
    mdqsEmpty: Result:='empty';
  end;
end;

procedure Run;
var
  Listing: TMediaDeviceList;
  Devices: TMediaDeviceInfos;
  Query: TMediaDeviceModes;
  Modes: TMediaDeviceModeArray;
  I, J: Integer;
begin
  if (ParamCount > 1) OR ((ParamCount = 1) AND (ParamStr(1) <> '--modes')) then
    raise Exception.Create('Usage: ListDevices [--modes]; indexes are zero-based');
  Listing:=TMediaDevices.ListDevices;
  if Listing.Status = mdqsUnsupported then
  begin
    WriteLn('DirectShow device discovery is unsupported on this platform/runtime.');
    Exit;
  end;
  Devices:=Listing.Devices;
  WriteLn('Devices: ', Length(Devices));
  for I:=0 to Length(Devices) - 1 do
  begin
    WriteLn(I, ': ', Devices[I].DisplayName);
    WriteLn('  ID: ', Devices[I].ID);
    if (ParamCount = 1) AND (ParamStr(1) = '--modes') then
    begin
      try
        Query:=TMediaDevices.QueryModes(Devices[I].ID);
        Modes:=Query.Modes;
        WriteLn('  Mode query status: ', StatusText(Query.Status), '; modes: ', Length(Modes));
        for J:=0 to Length(Modes) - 1 do
        begin
          Write('    ', Modes[J].PinName, ': ', Modes[J].FormatName);
          if Modes[J].Kind = mkVideo then
          begin
            Write(' ', Modes[J].Width, 'x', Modes[J].Height);
            if Modes[J].FrameRate.Known then
              Write(' @ ', Modes[J].FrameRate.Numerator, '/', Modes[J].FrameRate.Denominator, ' fps');
          end else
          if Modes[J].Kind = mkAudio then
            Write(' ', Modes[J].SampleRate, ' Hz, ', Modes[J].Channels, ' channels, ', Modes[J].BitsPerSample, ' bits');
          WriteLn;
        end;
      except
        on E: Exception do
          WriteLn('  Mode query failed: ', E.Message);
      end;
    end;
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
