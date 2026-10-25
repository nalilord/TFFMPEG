program MediaControlSmoke;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
  Classes,
{$ELSE}
  System.SysUtils,
  System.Classes,
{$ENDIF}
  libavformat_avio,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Internal.Native,
  MediaTestSupport;

type
  TFaultyToken = class(TInterfacedObject, IMediaCancellationToken)
  public
    function IsCancellationRequested: Boolean;
    procedure ThrowIfCancellationRequested(const AOperation: String);
  end;

function TFaultyToken.IsCancellationRequested: Boolean;
begin
  Result:=False;
  raise Exception.Create('Deliberate token failure');
end;

procedure TFaultyToken.ThrowIfCancellationRequested(const AOperation: String);
begin
  raise Exception.Create(AOperation);
end;

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

procedure Run;
var
  Operation: TMediaOperation;
  Interrupt: TAVIOInterruptCB;
  Token: IMediaCancellationToken;
  Source: IMediaCancellationSource;
  Failed: Boolean;
  Directory: TMediaTestDirectory;
  Stream: TFileStream;
  DirectoryPath: String;
begin
  Source:=TMediaCancellation.CreateSource;
  Operation:=TMediaOperation.Create(Source.Token, 0);
  try
    Interrupt:=Operation.Interrupt;
    Check(Interrupt.callback(Interrupt.opaque) = 0, 'Fresh operation');
    Operation.Check('Active');
    Source.Cancel;
    Check(Interrupt.callback(Interrupt.opaque) = 1, 'Cancelled native callback');
    Failed:=False;
    try
      Operation.Check('Cancelled');
    except
      on E: EMediaCancelled do
        Failed:=True;
    end;
    Check(Failed, 'Cancellation reported after native return');
  finally
    Operation.Free;
  end;

  Operation:=TMediaOperation.Create(nil, 1);
  try
    Sleep(5);
    Interrupt:=Operation.Interrupt;
    Check(Interrupt.callback(Interrupt.opaque) = 1, 'Expired callback');
    Failed:=False;
    try
      Operation.Check('Expired');
    except
      on E: EMediaTimedOut do
        Failed:=True;
    end;
    Check(Failed, 'Timeout reported after native return');
  finally
    Operation.Free;
  end;

  Token:=TFaultyToken.Create;
  Operation:=TMediaOperation.Create(Token, 0);
  try
    Interrupt:=Operation.Interrupt;
    Check(Interrupt.callback(Interrupt.opaque) = 1, 'Token exception must be contained');
    Failed:=False;
    try
      Operation.Check('Faulty token');
    except
      on E: EFFmpegMediaError do
        Failed:=(E.Category = mecInvalidState) AND (Pos('Deliberate token failure', E.Message) > 0);
    end;
    Check(Failed, 'Retained token failure must be reported');
  finally
    Operation.Free;
  end;

  Directory:=TMediaTestDirectory.Create;
  try
    try
      DirectoryPath:=Directory.Path;
      Stream:=TFileStream.Create(Directory.FileName('cleanup.bin'), fmCreate);
      Stream.Free;
      raise EAbort.Create('Deliberate failure to test cleanup');
    finally
      Directory.Free;
    end;
  except
    on E: EAbort do
      Check(E.Message = 'Deliberate failure to test cleanup', 'Expected cleanup test failure');
  end;
  Check(NOT DirectoryExists(DirectoryPath), 'Temporary directory must be removed on failure');
  WriteLn('PASS: native callback cancellation, timeout, exception containment and temporary-file cleanup');
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
