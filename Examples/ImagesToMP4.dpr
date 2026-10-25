program ImagesToMP4;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Writer;

var
  Images: Array of TMediaSequenceImage;
  Settings: TMediaImageSequenceSettings;
  Output: TMediaImageSequenceResult;
  I: Integer;
begin
  try
    if ParamCount < 2 then
      raise Exception.Create('Usage: ImagesToMP4 output.mp4 image1.png [image2.jpg ...]; each image lasts 2 seconds');
    SetLength(Images, ParamCount - 1);
    for I:=0 to Length(Images) - 1 do
      Images[I]:=TMediaSequenceImage.FromFile(ParamStr(I + 2), TMediaTime.FromSeconds(2));
    Settings:=TMediaImageSequenceSettings.H264MP4(1280, 720, TMediaRate.Create(30000, 1001));
    Settings.Fit:=mfFit;
    Output:=TMediaImageSequence.WriteFile(ParamStr(1), Images, Settings);
    WriteLn('Published ', Output.FrameCount, ' frames with ', Output.EncoderName, '; duration ', Output.EncodedDuration.Seconds:0:3, ' seconds');
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
