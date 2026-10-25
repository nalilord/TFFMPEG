unit TFFmpeg.Media.Errors;

interface

uses
{$IFDEF FPC}
  SysUtils;
{$ELSE}
  System.SysUtils;
{$ENDIF}

type
  TMediaErrorCategory = (mecInvalidSettings, mecUnsupported, mecInputOutput, mecDecode, mecEncode, mecInvalidState, mecCancelled, mecTimedOut,
    mecPositionUnavailable);

  EFFmpegMediaError = class(Exception)
  private
    FCategory: TMediaErrorCategory;
    FOperation: String;
    FNativeCode: Integer;
    FHasNativeCode: Boolean;
  public
    constructor Create(ACategory: TMediaErrorCategory; const AOperation, AMessage: String); reintroduce; overload;
    constructor Create(ACategory: TMediaErrorCategory; const AOperation, AMessage: String; ANativeCode: Integer); reintroduce; overload;
    property Category: TMediaErrorCategory read FCategory;
    property Operation: String read FOperation;
    property NativeCode: Integer read FNativeCode;
    property HasNativeCode: Boolean read FHasNativeCode;
  end;

  EMediaCancelled = class(EFFmpegMediaError)
  public
    constructor Create(const AOperation: String); reintroduce;
  end;

  EMediaTimedOut = class(EFFmpegMediaError)
  public
    constructor Create(const AOperation: String); reintroduce;
  end;

implementation

constructor EFFmpegMediaError.Create(ACategory: TMediaErrorCategory; const AOperation, AMessage: String);
begin
  inherited Create(AOperation + ': ' + AMessage);
  FCategory:=ACategory;
  FOperation:=AOperation;
end;

constructor EFFmpegMediaError.Create(ACategory: TMediaErrorCategory; const AOperation, AMessage: String; ANativeCode: Integer);
begin
  Create(ACategory, AOperation, AMessage);
  FNativeCode:=ANativeCode;
  FHasNativeCode:=True;
end;

constructor EMediaCancelled.Create(const AOperation: String);
begin
  inherited Create(mecCancelled, AOperation, 'Operation cancelled');
end;

constructor EMediaTimedOut.Create(const AOperation: String);
begin
  inherited Create(mecTimedOut, AOperation, 'Operation timed out');
end;

end.
