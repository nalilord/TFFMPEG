program MediaPublicationSmoke;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
  Classes,
{$ELSE}
  System.SysUtils,
  System.Classes,
{$ENDIF}
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Internal.Files,
  MediaTestSupport;

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

procedure WriteValue(const AFilename: String; AValue: Byte);
var
  Stream: TFileStream;
begin
  Stream:=TFileStream.Create(AFilename, fmCreate);
  try
    Stream.WriteBuffer(AValue, 1);
  finally
    Stream.Free;
  end;
end;

function ReadValue(const AFilename: String): Byte;
var
  Stream: TFileStream;
begin
  Result:=0;
  Stream:=TFileStream.Create(AFilename, fmOpenRead OR fmShareDenyWrite);
  try
    Stream.ReadBuffer(Result, 1);
  finally
    Stream.Free;
  end;
end;

procedure Run;
var
  Directory: TMediaTestDirectory;
  Output: TMediaLocalOutput;
  Name, Temporary: String;
  Failed: Boolean;
begin
  Directory:=TMediaTestDirectory.Create;
  try
    Name:=Directory.FileName('published.bin');
    Output:=TMediaLocalOutput.Create(Name, False);
    try
      Temporary:=Output.Temporary;
      Check(FileExists(Temporary) AND NOT FileExists(Name), 'Reserved output remains unpublished');
      WriteValue(Temporary, 17);
      WriteValue(Name, 23);
      Failed:=False;
      try
        Output.Publish;
      except
        on E: EFFmpegMediaError do
          Failed:=E.Category = mecInputOutput;
      end;
      Check(Failed AND (ReadValue(Name) = 23), 'Competing destination creation must win when overwrite is disabled');
    finally
      Output.Free;
    end;
    Check(NOT FileExists(Temporary), 'Failed publication removes the temporary file');
    Output:=TMediaLocalOutput.Create(Name, True);
    try
      Temporary:=Output.Temporary;
      WriteValue(Temporary, 41);
      Output.Publish;
      Output.Publish;
      Check(ReadValue(Name) = 41, 'Overwrite publishes the completed sibling and is idempotent');
    finally
      Output.Free;
    end;
    Check(NOT FileExists(Temporary), 'Publication leaves no sibling temporary');
    Output:=TMediaLocalOutput.Create(Name, True);
    try
      Temporary:=Output.Temporary;
      WriteValue(Temporary, 99);
      Check(ReadValue(Name) = 41, 'Unfinished replacement does not change destination');
    finally
      Output.Free;
    end;
    Check((ReadValue(Name) = 41) AND NOT FileExists(Temporary), 'Destruction discards unpublished replacement');
    Output:=TMediaLocalOutput.Create(Name, True);
    try
      Temporary:=Output.Temporary;
      Check(DeleteFile(Temporary), 'Remove temporary to inject a finalization failure');
      Failed:=False;
      try
        Output.Publish;
      except
        on E: EFFmpegMediaError do
          Failed:=E.Category = mecInputOutput;
      end;
      Check(Failed AND (ReadValue(Name) = 41), 'Failed replacement preserves existing bytes');
    finally
      Output.Free;
    end;
  finally
    Directory.Free;
  end;
  WriteLn('PASS: exclusive sibling reservation, destination races, successful replacement, failed publication and abort cleanup');
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
