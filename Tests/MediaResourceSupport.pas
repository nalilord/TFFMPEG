unit MediaResourceSupport;

interface

type
  TMediaResourceSnapshot = record
  private
    FPrivateBytes: UInt64;
    FWorkingSetBytes: UInt64;
    FHandles: Cardinal;
    FGDIObjects: Cardinal;
    FUserObjects: Cardinal;
  public
    class function Capture: TMediaResourceSnapshot; static;
    procedure CheckGrowth(const ABaseline: TMediaResourceSnapshot; APrivateAllowance: UInt64; AHandleAllowance: Cardinal;
      const AContext: String);
    procedure Print(const ALabel: String);
    property PrivateBytes: UInt64 read FPrivateBytes;
    property WorkingSetBytes: UInt64 read FWorkingSetBytes;
    property Handles: Cardinal read FHandles;
    property GDIObjects: Cardinal read FGDIObjects;
    property UserObjects: Cardinal read FUserObjects;
  end;

implementation

{$IFDEF MSWINDOWS}
{$IFNDEF FPC}
{$DEFINE MEDIA_RESOURCE_WINDOWS}
{$ENDIF}
{$ENDIF}

uses
{$IFDEF FPC}
  SysUtils;
{$ELSE}
{$IFDEF MEDIA_RESOURCE_WINDOWS}
  System.SysUtils,
  Winapi.Windows,
  Winapi.PsAPI;
{$ELSE}
  System.SysUtils;
{$ENDIF}
{$ENDIF}

class function TMediaResourceSnapshot.Capture: TMediaResourceSnapshot;
{$IFDEF MEDIA_RESOURCE_WINDOWS}
var
  Counters: TProcessMemoryCountersEx;
{$ENDIF}
begin
  Result:=Default(TMediaResourceSnapshot);
{$IFDEF MEDIA_RESOURCE_WINDOWS}
  FillChar(Counters, SizeOf(Counters), 0);
  Counters.cb:=SizeOf(Counters);
  if NOT GetProcessMemoryInfo(GetCurrentProcess, PPROCESS_MEMORY_COUNTERS(@Counters), SizeOf(Counters)) then
    RaiseLastOSError;
  if NOT GetProcessHandleCount(GetCurrentProcess, Result.FHandles) then
    RaiseLastOSError;
  Result.FPrivateBytes:=Counters.PrivateUsage;
  Result.FWorkingSetBytes:=Counters.WorkingSetSize;
  Result.FGDIObjects:=GetGuiResources(GetCurrentProcess, GR_GDIOBJECTS);
  Result.FUserObjects:=GetGuiResources(GetCurrentProcess, GR_USEROBJECTS);
{$ELSE}
  raise Exception.Create('Resource instrumentation is qualified for Delphi Windows only');
{$ENDIF}
end;

procedure TMediaResourceSnapshot.CheckGrowth(const ABaseline: TMediaResourceSnapshot; APrivateAllowance: UInt64; AHandleAllowance: Cardinal;
  const AContext: String);
begin
  if FPrivateBytes > ABaseline.FPrivateBytes + APrivateAllowance then
    raise Exception.Create(AContext + ': private memory exceeded the post-warmup growth allowance');
  if (FHandles > ABaseline.FHandles + AHandleAllowance) OR (FGDIObjects > ABaseline.FGDIObjects + AHandleAllowance) OR
    (FUserObjects > ABaseline.FUserObjects + AHandleAllowance) then
    raise Exception.Create(AContext + ': process/GDI/USER handle growth exceeded the allowance');
end;

procedure TMediaResourceSnapshot.Print(const ALabel: String);
begin
  WriteLn(ALabel, ': private=', FPrivateBytes, '; working set=', FWorkingSetBytes, '; handles=', FHandles,
    '; GDI=', FGDIObjects, '; USER=', FUserObjects);
  Flush(Output);
end;

end.
