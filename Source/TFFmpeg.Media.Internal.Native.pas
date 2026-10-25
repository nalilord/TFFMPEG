unit TFFmpeg.Media.Internal.Native;

interface

uses
  libavformat_avio,
  libavutil_frame,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Types;

type
  // Owned by an operation/session; must outlive all contexts using Interrupt.
  TMediaOperation = class
  private
    FToken: IMediaCancellationToken;
    FStarted: UInt64;
    FTimeoutMilliseconds: Cardinal;
    FCallbackError: String;
    FCancelled: Boolean;
    FTimedOut: Boolean;
  public
    constructor Create(const AToken: IMediaCancellationToken; ATimeoutMilliseconds: Cardinal);
    function Interrupt: TAVIOInterruptCB;
    function Interrupted: Boolean;
    procedure RestartTimeout;
    procedure Check(const AOperation: String);
  end;

function PublicDisplayMatrix(AData: PByte; ASize: NativeUInt): TMediaDisplayTransform;
function FrameDisplayMatrix(AFrame: PAVFrame): TMediaDisplayTransform;

implementation

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
  System.Diagnostics,
{$ENDIF}
  TFFmpeg.Media.Errors;

function PublicDisplayMatrix(AData: PByte; ASize: NativeUInt): TMediaDisplayTransform;
var
  Matrix: Array[0..8] of Integer;
  Values: Array[0..8] of Double;
  I: Integer;
begin
  Result:=Default(TMediaDisplayTransform);
  if NOT Assigned(AData) OR (ASize < SizeOf(Matrix)) then
    Exit;
  Move(AData^, Matrix, SizeOf(Matrix));
  for I:=0 to 8 do
    if (I MOD 3) = 2 then
      Values[I]:=Matrix[I] / 1073741824.0
    else
      Values[I]:=Matrix[I] / 65536.0;
  Result:=TMediaDisplayTransform.Create(Values);
end;

function FrameDisplayMatrix(AFrame: PAVFrame): TMediaDisplayTransform;
var
  SideData: PAVFrameSideData;
begin
  Result:=Default(TMediaDisplayTransform);
  SideData:=av_frame_get_side_data(AFrame, AV_FRAME_DATA_DISPLAYMATRIX);
  if Assigned(SideData) then
    Result:=PublicDisplayMatrix(SideData.data, SideData.size);
end;

function MonotonicMilliseconds: UInt64;
{$IFNDEF FPC}
var
  Ticks, Frequency: Int64;
{$ENDIF}
begin
{$IFDEF FPC}
  Result:=GetTickCount64;
{$ELSE}
  Ticks:=TStopwatch.GetTimeStamp;
  Frequency:=TStopwatch.Frequency;
  Result:=UInt64(Ticks DIV Frequency) * 1000 + UInt64((Ticks MOD Frequency) * 1000 DIV Frequency);
{$ENDIF}
end;

constructor TMediaOperation.Create(const AToken: IMediaCancellationToken; ATimeoutMilliseconds: Cardinal);
begin
  inherited Create;
  FToken:=AToken;
  FTimeoutMilliseconds:=ATimeoutMilliseconds;
  FStarted:=MonotonicMilliseconds;
end;

procedure TMediaOperation.RestartTimeout;
begin
  FStarted:=MonotonicMilliseconds;
  FTimedOut:=False;
end;

function TMediaOperation.Interrupted: Boolean;
begin
  Result:=True;
  try
    if FCallbackError <> '' then
      Exit;
    if Assigned(FToken) AND FToken.IsCancellationRequested then
    begin
      FCancelled:=True;
      Exit;
    end;
    if (FTimeoutMilliseconds <> 0) AND (MonotonicMilliseconds - FStarted >= FTimeoutMilliseconds) then
    begin
      FTimedOut:=True;
      Exit;
    end;
    Result:=False;
  except
    on E: Exception do
    begin
      // A custom token is application code. Retain its error for Pascal-side
      // reporting; no exception may unwind through a native callback.
      FCallbackError:=E.Message;
      if FCallbackError = '' then
        FCallbackError:=E.ClassName;
    end;
    else FCallbackError:='Non-Exception error in cancellation token';
  end;
end;

function MediaInterrupt(AOpaque: Pointer): Integer; cdecl;
begin
  Result:=1;
  try
    if Assigned(AOpaque) then
      Result:=Ord(TMediaOperation(AOpaque).Interrupted);
  except
    // Also contain unexpected errors in the interrupt bridge itself.
    Result:=1;
  end;
end;

function TMediaOperation.Interrupt: TAVIOInterruptCB;
begin
  Result:=Default(TAVIOInterruptCB);
  Result.callback:=MediaInterrupt;
  Result.opaque:=Self;
end;

procedure TMediaOperation.Check(const AOperation: String);
begin
  Interrupted;
  if FCallbackError <> '' then
    raise EFFmpegMediaError.Create(mecInvalidState, AOperation, 'Cancellation token failed: ' + FCallbackError);
  if FCancelled then
    raise EMediaCancelled.Create(AOperation);
  if FTimedOut then
    raise EMediaTimedOut.Create(AOperation);
end;

end.
