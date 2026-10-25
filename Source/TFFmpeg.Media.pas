unit TFFmpeg.Media;

interface

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Reader,
  TFFmpeg.Media.Images,
  TFFmpeg.Media.Writer,
  TFFmpeg.Media.Convert;

type
  TFFmpegMedia = class sealed
  public
    class function ConvertFile(const ASource, ADestination: String; const ASettings: TMediaAVConvertSettings;
      AProgress: TMediaProgressCallback = nil; const AToken: IMediaCancellationToken = nil): TMediaConversionResult; static;
    class function ConvertURL(const AURL, ADestination: String; const ASettings: TMediaAVConvertSettings;
      AProgress: TMediaProgressCallback = nil; const AToken: IMediaCancellationToken = nil): TMediaConversionResult; static;
    class function ConvertAudio(const ASource, ADestination: String): TMediaConversionResult; overload; static;
    class function ConvertAudio(const ASource, ADestination: String; const ASettings: TMediaAudioConvertSettings;
      AProgress: TMediaProgressCallback = nil; const AToken: IMediaCancellationToken = nil): TMediaConversionResult; overload; static;
    class function OpenWriter(const AFilename: String; const ASettings: TMediaWriterSettings;
      const AToken: IMediaCancellationToken = nil): IMediaWriter; static;
    class function SaveScreenshot(const AFilename: String; const APosition: TMediaTime; const ADestination: String): TMediaScreenshot; overload; static;
    class function SaveScreenshot(const AFilename: String; const APosition: TMediaTime; const ADestination: String;
      const ASettings: TMediaScreenshotSettings; const AWriteSettings: TMediaImageWriteSettings;
      const AToken: IMediaCancellationToken = nil): TMediaScreenshot; overload; static;
    class function OpenFile(const AFilename: String): IMediaReader; overload; static;
    class function OpenFile(const AFilename: String; const ASettings: TMediaReaderSettings;
      const AToken: IMediaCancellationToken = nil): IMediaReader; overload; static;
    class function OpenBytes(const ABytes: TBytes): IMediaReader; overload; static;
    class function OpenBytes(const ABytes: TBytes; const ASettings: TMediaReaderSettings;
      const AToken: IMediaCancellationToken = nil): IMediaReader; overload; static;
    class function OpenURL(const AURL: String): IMediaReader; overload; static;
    class function OpenURL(const AURL: String; const ASettings: TMediaReaderSettings;
      const AToken: IMediaCancellationToken = nil): IMediaReader; overload; static;
    class function ProbeFile(const AFilename: String): TMediaInfo; overload; static;
    class function ProbeFile(const AFilename: String; const ASettings: TMediaInputSettings;
      const AToken: IMediaCancellationToken = nil): TMediaInfo; overload; static;
    class function ProbeBytes(const ABytes: TBytes): TMediaInfo; overload; static;
    class function ProbeBytes(const ABytes: TBytes; const ASettings: TMediaInputSettings;
      const AToken: IMediaCancellationToken = nil): TMediaInfo; overload; static;
    class function ProbeURL(const AURL: String): TMediaInfo; overload; static;
    class function ProbeURL(const AURL: String; const ASettings: TMediaInputSettings;
      const AToken: IMediaCancellationToken = nil): TMediaInfo; overload; static;
  end;

implementation

class function TFFmpegMedia.ConvertFile(const ASource, ADestination: String; const ASettings: TMediaAVConvertSettings;
  AProgress: TMediaProgressCallback; const AToken: IMediaCancellationToken): TMediaConversionResult;
begin
  Result:=TMediaConvert.MediaFile(ASource, ADestination, ASettings, AProgress, AToken);
end;

class function TFFmpegMedia.ConvertURL(const AURL, ADestination: String; const ASettings: TMediaAVConvertSettings;
  AProgress: TMediaProgressCallback; const AToken: IMediaCancellationToken): TMediaConversionResult;
begin
  Result:=TMediaConvert.MediaURL(AURL, ADestination, ASettings, AProgress, AToken);
end;

class function TFFmpegMedia.ConvertAudio(const ASource, ADestination: String): TMediaConversionResult;
begin
  Result:=TMediaConvert.AudioFile(ASource, ADestination);
end;

class function TFFmpegMedia.ConvertAudio(const ASource, ADestination: String; const ASettings: TMediaAudioConvertSettings;
  AProgress: TMediaProgressCallback; const AToken: IMediaCancellationToken): TMediaConversionResult;
begin
  Result:=TMediaConvert.AudioFile(ASource, ADestination, ASettings, AProgress, AToken);
end;

class function TFFmpegMedia.OpenWriter(const AFilename: String; const ASettings: TMediaWriterSettings;
  const AToken: IMediaCancellationToken): IMediaWriter;
begin
  Result:=TMediaWriter.OpenFile(AFilename, ASettings, AToken);
end;

class function TFFmpegMedia.SaveScreenshot(const AFilename: String; const APosition: TMediaTime;
  const ADestination: String): TMediaScreenshot;
begin
  Result:=SaveScreenshot(AFilename, APosition, ADestination, TMediaScreenshotSettings.Default, TMediaImageWriteSettings.Default);
end;

class function TFFmpegMedia.SaveScreenshot(const AFilename: String; const APosition: TMediaTime; const ADestination: String;
  const ASettings: TMediaScreenshotSettings; const AWriteSettings: TMediaImageWriteSettings;
  const AToken: IMediaCancellationToken): TMediaScreenshot;
begin
  Result:=TMediaImages.ScreenshotFile(AFilename, APosition, ASettings, AToken);
  TMediaImages.SaveFile(Result.Frame, ADestination, AWriteSettings, AToken);
end;

class function TFFmpegMedia.OpenFile(const AFilename: String): IMediaReader;
begin
  Result:=OpenFile(AFilename, TMediaReaderSettings.Default);
end;

class function TFFmpegMedia.OpenFile(const AFilename: String; const ASettings: TMediaReaderSettings;
  const AToken: IMediaCancellationToken): IMediaReader;
begin
  Result:=TMediaReader.OpenFile(AFilename, ASettings, AToken);
end;

class function TFFmpegMedia.OpenBytes(const ABytes: TBytes): IMediaReader;
begin
  Result:=OpenBytes(ABytes, TMediaReaderSettings.Default);
end;

class function TFFmpegMedia.OpenBytes(const ABytes: TBytes; const ASettings: TMediaReaderSettings;
  const AToken: IMediaCancellationToken): IMediaReader;
begin
  Result:=TMediaReader.OpenBytes(ABytes, ASettings, AToken);
end;

class function TFFmpegMedia.OpenURL(const AURL: String): IMediaReader;
begin
  Result:=OpenURL(AURL, TMediaReaderSettings.Default);
end;

class function TFFmpegMedia.OpenURL(const AURL: String; const ASettings: TMediaReaderSettings;
  const AToken: IMediaCancellationToken): IMediaReader;
begin
  Result:=TMediaReader.OpenURL(AURL, ASettings, AToken);
end;

class function TFFmpegMedia.ProbeURL(const AURL: String): TMediaInfo;
begin
  Result:=ProbeURL(AURL, TMediaInputSettings.Default);
end;

class function TFFmpegMedia.ProbeURL(const AURL: String; const ASettings: TMediaInputSettings;
  const AToken: IMediaCancellationToken): TMediaInfo;
begin
  Result:=TMediaProbe.ProbeURL(AURL, ASettings, AToken);
end;

class function TFFmpegMedia.ProbeFile(const AFilename: String): TMediaInfo;
begin
  Result:=ProbeFile(AFilename, TMediaInputSettings.Default);
end;

class function TFFmpegMedia.ProbeFile(const AFilename: String; const ASettings: TMediaInputSettings;
  const AToken: IMediaCancellationToken): TMediaInfo;
begin
  Result:=TMediaProbe.ProbeFile(AFilename, ASettings, AToken);
end;

class function TFFmpegMedia.ProbeBytes(const ABytes: TBytes): TMediaInfo;
begin
  Result:=ProbeBytes(ABytes, TMediaInputSettings.Default);
end;

class function TFFmpegMedia.ProbeBytes(const ABytes: TBytes; const ASettings: TMediaInputSettings;
  const AToken: IMediaCancellationToken): TMediaInfo;
begin
  Result:=TMediaProbe.ProbeBytes(ABytes, ASettings, AToken);
end;

end.
