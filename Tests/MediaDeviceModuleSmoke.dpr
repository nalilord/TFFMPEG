program MediaDeviceModuleSmoke;

{$APPTYPE CONSOLE}

{$IFDEF MSWINDOWS}
{$IFNDEF FPC}
{$DEFINE MEDIA_DEVICE_WINDOWS}
{$ENDIF}
{$ENDIF}

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
{$IFDEF MEDIA_DEVICE_WINDOWS}
  Winapi.Windows,
{$ENDIF}
  TFFmpeg.Media.Internal.Devices.DShow;

procedure Run;
{$IFDEF MEDIA_DEVICE_WINDOWS}
var
  Module: HMODULE;
  Directory: Array[0..MAX_PATH] of Char;
  Filename: String;
  Baseline, Current, Count: Cardinal;
  I: Integer;
{$ENDIF}
begin
{$IFDEF MEDIA_DEVICE_WINDOWS}
  RetainDShowCaptureModule;
  Count:=GetSystemDirectory(Directory, Length(Directory));
  if (Count = 0) OR (Count >= Cardinal(Length(Directory))) then
    raise Exception.Create('Cannot resolve system capture module');
  Filename:=IncludeTrailingPathDelimiter(String(Directory)) + 'kswdmcap.ax';
  if NOT GetProcessHandleCount(GetCurrentProcess, Baseline) then
    RaiseLastOSError;
  for I:=0 to 19 do
  begin
    RetainDShowCaptureModule;
    Module:=LoadLibraryEx(PChar(Filename), 0, $00000800);
    if Module = 0 then
      RaiseLastOSError;
    try
      if NOT GetProcessHandleCount(GetCurrentProcess, Current) then
        RaiseLastOSError;
    finally
      FreeLibrary(Module);
    end;
    if Current > Baseline + 2 then
      raise Exception.Create('Repeated Windows capture module use leaks process handles');
  end;
  WriteLn('PASS: twenty native capture module load/release cycles keep handles bounded: ', Baseline, ' -> ', Current);
{$ELSE}
  WriteLn('Windows module lifecycle requires native Delphi Windows; FPC checks compilation only');
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
