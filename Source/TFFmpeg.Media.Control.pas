unit TFFmpeg.Media.Control;

interface

uses
  TFFmpeg.Media.Types;

type
  IMediaCancellationToken = interface
    ['{E86DDA1C-1A94-4F35-BCF1-2B91E2D610B7}']
    function IsCancellationRequested: Boolean;
    procedure ThrowIfCancellationRequested(const AOperation: String);
  end;

  IMediaCancellationSource = interface
    ['{7EA14A2E-421A-45CB-81F0-DBBCB7151DA8}']
    function GetToken: IMediaCancellationToken;
    procedure Cancel;
    property Token: IMediaCancellationToken read GetToken;
  end;

  TMediaProgressStage = (mpsOpening, mpsProcessing, mpsFinalizing, mpsCompleted);
  TMediaProgress = record
  private
    FStage: TMediaProgressStage;
    FProcessedTime: TMediaTime;
    FBytes: Int64;
    FElapsedMilliseconds: UInt64;
    FPercent: TMediaOptionalInt64;
  public
    property Stage: TMediaProgressStage read FStage write FStage;
    property ProcessedTime: TMediaTime read FProcessedTime write FProcessedTime;
    property Bytes: Int64 read FBytes write FBytes;
    property ElapsedMilliseconds: UInt64 read FElapsedMilliseconds write FElapsedMilliseconds;
    property Percent: TMediaOptionalInt64 read FPercent write FPercent;
  end;
  TMediaProgressCallback = procedure(const AProgress: TMediaProgress) of object;

  TMediaCancellation = class sealed
  public
    class function CreateSource: IMediaCancellationSource; static;
  end;

implementation

uses
{$IFDEF FPC}
  SyncObjs,
{$ELSE}
  System.SyncObjs,
{$ENDIF}
  TFFmpeg.Media.Errors;

type
  TMediaCancellationState = class(TInterfacedObject, IMediaCancellationSource, IMediaCancellationToken)
  private
    FLock: TCriticalSection;
    FCancelled: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function GetToken: IMediaCancellationToken;
    procedure Cancel;
    function IsCancellationRequested: Boolean;
    procedure ThrowIfCancellationRequested(const AOperation: String);
  end;

constructor TMediaCancellationState.Create;
begin
  inherited Create;
  FLock:=TCriticalSection.Create;
end;

destructor TMediaCancellationState.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TMediaCancellationState.GetToken: IMediaCancellationToken;
begin
  Result:=Self;
end;

procedure TMediaCancellationState.Cancel;
begin
  FLock.Acquire;
  try
    FCancelled:=True;
  finally
    FLock.Release;
  end;
end;

function TMediaCancellationState.IsCancellationRequested: Boolean;
begin
  Result:=False;
  FLock.Acquire;
  try
    Result:=FCancelled;
  finally
    FLock.Release;
  end;
end;

procedure TMediaCancellationState.ThrowIfCancellationRequested(const AOperation: String);
begin
  if IsCancellationRequested then
    raise EMediaCancelled.Create(AOperation);
end;

class function TMediaCancellation.CreateSource: IMediaCancellationSource;
begin
  Result:=TMediaCancellationState.Create;
end;

end.
