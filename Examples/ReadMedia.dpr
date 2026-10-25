program ReadMedia;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Reader,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Errors;

procedure Run;
var
  Reader: IMediaReader;
  Sample: IMediaSample;
  Audio: IMediaAudioBuffer;
  Status: TMediaReadStatus;
  Frames: Integer;
  Samples: Int64;
begin
  if ParamCount <> 1 then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'ReadMedia', 'Usage: ReadMedia <local media filename>');
  Reader:=TMediaReader.OpenFile(ParamStr(1), TMediaReaderSettings.Default);
  Frames:=0;
  Samples:=0;
  repeat
    Status:=Reader.ReadSample(Sample);
    case Status of
      mrsSample:
      begin
        if Sample.Kind = mkVideo then
          Inc(Frames)
        else
        if Supports(Sample, IMediaAudioBuffer, Audio) then
          Inc(Samples, Audio.SampleCount);
      end;

      mrsTimedOut: WriteLn('Read timed out; reopen the reader to continue.');
      mrsCancelled: WriteLn('Read cancelled.');
    end;
  until Status <> mrsSample;
  Reader.Close;
  WriteLn('Decoded ', Frames, ' video frames and ', Samples, ' audio samples per channel at 48000 Hz.');
end;

begin
  try
    Run;
  except
    on E: EFFmpegMediaError do
    begin
      WriteLn(E.Message);
      Halt(1);
    end;
  end;
end.
