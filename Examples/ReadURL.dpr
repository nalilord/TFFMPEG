program ReadURL;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Reader;

procedure Run;
var
  Reader: IMediaReader;
  Settings: TMediaReaderSettings;
  Input: TMediaInputSettings;
  Sample: IMediaSample;
  Status: TMediaReadStatus;
  VideoFrames, AudioSamples: Int64;
begin
  if ParamCount <> 1 then
    raise Exception.Create('Usage: ReadURL http[s]://host/media; 5-second operation timeout');
  Settings:=TMediaReaderSettings.Default;
  Input:=Settings.Input;
  Input.TimeoutMilliseconds:=5000;
  Settings.Input:=Input;
  Reader:=TMediaReader.OpenURL(ParamStr(1), Settings);
  try
    VideoFrames:=0;
    AudioSamples:=0;
    while True do
    begin
      Status:=Reader.ReadSample(Sample);
      case Status of
        mrsEndOfInput: Break;
        mrsCancelled: raise EMediaCancelled.Create('Read URL');
        mrsTimedOut: raise EMediaTimedOut.Create('Read URL');
      end;
      if Sample.Kind = mkVideo then
        Inc(VideoFrames)
      else
        Inc(AudioSamples, (Sample AS IMediaAudioBuffer).SampleCount);
    end;
    WriteLn(VideoFrames, ' video frames; ', AudioSamples, ' audio samples/channel');
  finally
    Reader.Close;
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
