program MediaDeviceSmoke;

{$APPTYPE CONSOLE}
{$R+}
{$Q+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
{$IFDEF MSWINDOWS}
  libavdevice,
  libavformat,
  libavutil,
  TFFmpeg.Utils,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Devices,
  TFFmpeg.Media.Errors;

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

procedure Run;
var
  Listing, Repeated: TMediaDeviceList;
  Devices, CopyDevices, Again: TMediaDeviceInfos;
  Query: TMediaDeviceModes;
  Modes, CopyModes: TMediaDeviceModeArray;
  I, J, Matches: Integer;
  Failed: Boolean;
{$IFDEF MSWINDOWS}
  NativeList: libavdevice.PAVDeviceInfoList;
  NativeDevice: PAVDeviceInfo;
  Code: Integer;
  NativeID: String;
{$ENDIF}
begin
  Listing:=TMediaDevices.ListDevices('nonexistent-backend');
  Check(Listing.Status = mdqsUnsupported, 'Unknown backend must be explicitly unsupported');
  Check(Length(Listing.Devices) = 0, 'Unsupported enumeration must have no devices');
  Failed:=False;
  try
    Query:=TMediaDevices.QueryModes('friendly-name');
  except
    on E: EFFmpegMediaError do
      Failed:=E.Category = mecInvalidSettings;
  end;
  Check(Failed, 'Friendly names must not masquerade as stable backend IDs');

  Listing:=TMediaDevices.ListDevices;
  if NOT TMediaDevices.BackendAvailable then
  begin
    Check(Listing.Status = mdqsUnsupported, 'Unavailable backend result');
    Query:=TMediaDevices.QueryModes('dshow:video:missing');
    Check(Query.Status = mdqsUnsupported, 'Unavailable mode query result');
    WriteLn('PASS: unavailable platform/backend is explicitly unsupported');
    Exit;
  end;
  Check(Listing.Status IN [mdqsAvailable, mdqsEmpty], 'Available backend enumeration status');
  Devices:=Listing.Devices;
  Check((Listing.Status = mdqsEmpty) = (Length(Devices) = 0), 'Empty/available status agrees with count');
  CopyDevices:=Listing.Devices;
  if Length(CopyDevices) > 0 then
  begin
    CopyDevices[0].ID:='changed';
    Again:=Listing.Devices;
    Check(Again[0].ID = Devices[0].ID, 'Device snapshot getter is detached');
    Repeated.Devices:=Devices;
    CopyDevices:=Devices;
    CopyDevices[0].ID:='changed';
    Again:=Repeated.Devices;
    Check(Again[0].ID <> 'changed', 'Device snapshot setter is detached');
    // Restore the caller array after intentionally mutating its shared copy.
    Devices:=Listing.Devices;
  end;
  Repeated:=TMediaDevices.ListDevices;
  Again:=Repeated.Devices;
  Check(Length(Again) = Length(Devices), 'Repeated enumeration count');
  for I:=0 to Length(Devices) - 1 do
  begin
    Check((Devices[I].Backend = 'dshow') AND (Devices[I].DisplayName <> ''), 'Backend and display name');
    Check(Devices[I].Kind IN [mkVideo, mkAudio], 'Capture device kind');
    Matches:=0;
    for J:=0 to Length(Again) - 1 do
      if Devices[I].ID = Again[J].ID then
        Inc(Matches);
    Check(Matches = 1, 'Stable unique device IDs across enumeration');
    Query:=TMediaDevices.QueryModes(Devices[I].ID);
    Modes:=Query.Modes;
    Check(Query.DeviceID = Devices[I].ID, 'Mode snapshot retains device identity');
    Check((Query.Status <> mdqsAvailable) OR (Length(Modes) > 0), 'Available mode query contains modes');
    for J:=0 to Length(Modes) - 1 do
    begin
      Check(Modes[J].FormatName <> '', 'Mode has a format description');
      Check(Modes[J].Kind = Devices[I].Kind, 'Mode matches device kind');
      if Modes[J].Kind = mkVideo then
        Check((Modes[J].Width > 0) AND (Modes[J].Height > 0), 'Video mode dimensions')
      else
        Check((Modes[J].SampleRate > 0) AND (Modes[J].Channels > 0), 'Audio mode layout');
    end;
    if Length(Modes) > 0 then
    begin
      CopyModes:=Query.Modes;
      CopyModes[0].FormatName:='changed';
      CopyModes:=Query.Modes;
      Check(CopyModes[0].FormatName = Modes[0].FormatName, 'Mode snapshot getter is detached');
      Query.Modes:=Modes;
      Modes[0].FormatName:='changed';
      CopyModes:=Query.Modes;
      Check(CopyModes[0].FormatName <> 'changed', 'Mode snapshot setter is detached');
    end;
    WriteLn('Device: ', Devices[I].DisplayName, '; mode status=', Ord(Query.Status), '; count=', Length(Modes));
  end;
  Failed:=False;
  try
    Query:=TMediaDevices.QueryModes('dshow:video:missing');
  except
    on E: EFFmpegMediaError do
      Failed:=E.Category = mecInputOutput;
  end;
  Check(Failed, 'Disappeared or unknown device is an explicit IO error');

{$IFDEF MSWINDOWS}
  NativeList:=nil;
  try
    Code:=avdevice_list_input_sources(av_find_input_format('dshow'), nil, nil, @NativeList);
    WriteLn('Native DirectShow list result=', Code);
    // Characterize this deployed native backend rather than assume ENOSYS or
    // universal support. Partial/error lists cannot qualify a successful result.
    if Code < 0 then
    begin
      WriteLn('Native enumeration is unavailable/failed on this deployment; OS discovery remains authoritative.');
      Exit;
    end;
    Check(Assigned(NativeList), 'Successful native listing supplies a list');
    Check(NativeList.nb_devices = Length(Devices), 'Native and OS discovery counts agree');
    for I:=0 to NativeList.nb_devices - 1 do
    begin
      NativeDevice:=PPAVDeviceInfo(NativeUInt(NativeList.devices) + NativeUInt(I) * SizeOf(Pointer))^;
      NativeID:=UTF8PtrToString(NativeDevice.device_name);
      Matches:=0;
      for J:=0 to Length(Devices) - 1 do
        if StringReplace(Copy(Devices[J].ID, 13, MaxInt), ':', '_', [rfReplaceAll]) = NativeID then
          Inc(Matches);
      Check(Matches = 1, 'Native alternative name maps to one OS moniker');
    end;
  finally
    avdevice_free_list_devices(@NativeList);
  end;
{$ENDIF}
  WriteLn('PASS: discovery, native/OS identity, modes, detached snapshots and stale identifiers');
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
