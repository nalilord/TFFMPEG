program MediaInfo;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  TFFmpeg.Media,
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Errors;

function TimeText(const ATime: TMediaTime): String;
begin
  Result:='unknown';
  if ATime.Valid then
    Result:=FormatFloat('0.000000', ATime.Seconds) + ' s';
  if ATime.Estimated then
    Result:=Result + ' (estimated)';
end;

procedure Run;
var
  Info: TMediaInfo;
  Streams: TMediaStreams;
  I: Integer;
begin
  if ParamCount <> 1 then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'MediaInfo', 'Usage: MediaInfo <local media filename>');
  Info:=TFFmpegMedia.ProbeFile(ParamStr(1));
  WriteLn('Container: ', Info.FormatName, ' / ', Info.FormatDescription);
  WriteLn('Duration: ', TimeText(Info.Duration), '; start: ', TimeText(Info.StartTime), '; seekable: ', Info.Seekable);
  Streams:=Info.Streams;
  for I:=0 to Length(Streams) - 1 do
  begin
    WriteLn('Stream ', Streams[I].Index, ': ', Streams[I].CodecName, '; decoder: ', Streams[I].DecoderAvailable,
      '; duration: ', TimeText(Streams[I].Duration), '; language: ', Streams[I].Language);
    case Streams[I].Kind of
      mkVideo:
      begin
        WriteLn('  Video ', Streams[I].Width, 'x', Streams[I].Height, '; attached art: ', Streams[I].AttachedArt);
        if Streams[I].FrameRate.Known then
          WriteLn('  Rate ', Streams[I].FrameRate.Numerator, '/', Streams[I].FrameRate.Denominator);
        if Streams[I].RotationKnown then
          WriteLn('  Rotation: ', Streams[I].RotationDegrees:0:2, ' degrees counterclockwise');
      end;

      mkAudio:
        WriteLn('  Audio ', Streams[I].SampleRate, ' Hz; ', Streams[I].ChannelLayout.Channels, ' channels; ', Streams[I].ChannelLayout.Name);
    end;
  end;
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
