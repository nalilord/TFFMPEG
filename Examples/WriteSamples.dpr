program WriteSamples;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Writer;

var
  Writer: IMediaWriter;
  Bytes: TBytes;
  Buffer: IMediaAudioBuffer;
  I: Integer;
  Value: SmallInt;
begin
  try
    if ParamCount <> 1 then
      raise Exception.Create('Usage: WriteSamples output.wav');
    Writer:=TMediaWriter.OpenFile(ParamStr(1), TMediaWriterSettings.PCMWave(48000, 1));
    try
      SetLength(Bytes, 48000 * 2);
      for I:=0 to 47999 do
      begin
        Value:=Round(8000 * Sin(I * 2 * Pi * 440 / 48000));
        Move(Value, Bytes[I * 2], 2);
      end;
      Buffer:=TMediaFrames.CopyAudio(Bytes, 48000, 48000, msfS16, TMediaChannelLayout.Mono, TMediaTime.Unknown);
      Writer.SubmitAudio(Buffer);
      Buffer:=nil;
      Writer.Finish;
      WriteLn('Published one second of PCM with ', Writer.AudioEncoderName);
    finally
      Writer.Abort;
    end;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
