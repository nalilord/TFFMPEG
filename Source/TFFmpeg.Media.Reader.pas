unit TFFmpeg.Media.Reader;

interface

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Frames;

type
  TMediaReaderSettings = record
  private
    FInput: TMediaInputSettings;
    FVideoStreamIndex: Integer;
    FAudioStreamIndex: Integer;
    FPixelFormat: TMediaPixelFormat;
    FSampleFormat: TMediaSampleFormat;
    FSampleRate: Integer;
    FChannels: Integer;
    FMaxPacketBytes: Integer;
  public
    class function Default: TMediaReaderSettings; static;
    procedure Validate;
    property Input: TMediaInputSettings read FInput write FInput;
    property VideoStreamIndex: Integer read FVideoStreamIndex write FVideoStreamIndex;
    property AudioStreamIndex: Integer read FAudioStreamIndex write FAudioStreamIndex;
    property PixelFormat: TMediaPixelFormat read FPixelFormat write FPixelFormat;
    property SampleFormat: TMediaSampleFormat read FSampleFormat write FSampleFormat;
    property SampleRate: Integer read FSampleRate write FSampleRate;
    property Channels: Integer read FChannels write FChannels;
    property MaxPacketBytes: Integer read FMaxPacketBytes write FMaxPacketBytes;
  end;

  IMediaReader = interface
    ['{92119DB2-6FB9-47D7-94A1-4C49E45B968A}']
    function GetInfo: TMediaInfo;
    function GetPresentationOrigin: TMediaTime;
    function ReadSample(out ASample: IMediaSample): TMediaReadStatus;
    procedure Seek(const APosition: TMediaTime);
    procedure Close;
    property Info: TMediaInfo read GetInfo;
    property PresentationOrigin: TMediaTime read GetPresentationOrigin;
  end;

  TMediaReader = class sealed
  public
    class function OpenFile(const AFilename: String; const ASettings: TMediaReaderSettings;
      const AToken: IMediaCancellationToken = nil): IMediaReader; static;
    class function OpenBytes(const ABytes: TBytes; const ASettings: TMediaReaderSettings;
      const AToken: IMediaCancellationToken = nil): IMediaReader; static;
    class function OpenURL(const AURL: String; const ASettings: TMediaReaderSettings;
      const AToken: IMediaCancellationToken = nil): IMediaReader; static;
  end;

  TMediaProbe = class sealed
  public
    class function ProbeFile(const AFilename: String; const ASettings: TMediaInputSettings;
      const AToken: IMediaCancellationToken = nil): TMediaInfo; static;
    class function ProbeBytes(const ABytes: TBytes; const ASettings: TMediaInputSettings;
      const AToken: IMediaCancellationToken = nil): TMediaInfo; static;
    class function ProbeURL(const AURL: String; const ASettings: TMediaInputSettings;
      const AToken: IMediaCancellationToken = nil): TMediaInfo; static;
    // -1 requests the default; -2 explicitly disables this kind.
    class function SelectStream(const AInfo: TMediaInfo; AKind: TMediaKind; ARequestedIndex: Integer = -1): Integer; static;
  end;

implementation

uses
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Internal.Reader;

class function TMediaReaderSettings.Default: TMediaReaderSettings;
begin
  Result:=System.Default(TMediaReaderSettings);
  Result.FInput:=TMediaInputSettings.Default;
  Result.FVideoStreamIndex:=-1;
  Result.FAudioStreamIndex:=-1;
  Result.FPixelFormat:=mpfBGRA32;
  Result.FSampleFormat:=msfS16;
  Result.FSampleRate:=48000;
  Result.FChannels:=2;
  Result.FMaxPacketBytes:=64 * 1024 * 1024;
end;

procedure TMediaReaderSettings.Validate;
begin
  FInput.Validate;
  if (FVideoStreamIndex < -2) OR (FAudioStreamIndex < -2) OR ((FVideoStreamIndex = -2) AND (FAudioStreamIndex = -2)) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Open reader', 'Select at least one valid audio/video stream');
  if NOT (FPixelFormat IN [mpfRGB24, mpfBGRA32]) OR NOT (FSampleFormat IN [msfS16, msfFloat32]) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Open reader', 'An explicit supported pixel/sample format is required');
  if (FSampleRate < 8000) OR (FSampleRate > 192000) OR (FChannels < 1) OR (FChannels > 2) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Open reader', 'Output audio requires 8-192 kHz and mono/stereo');
  if (FMaxPacketBytes < 1) OR (FMaxPacketBytes > MEDIA_MAX_BUFFER_BYTES) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Open reader', 'Packet limit must be between 1 byte and 256 MiB');
end;

class function TMediaReader.OpenFile(const AFilename: String; const ASettings: TMediaReaderSettings;
  const AToken: IMediaCancellationToken): IMediaReader;
begin
  Result:=OpenMediaFile(AFilename, ASettings, AToken);
end;

class function TMediaReader.OpenBytes(const ABytes: TBytes; const ASettings: TMediaReaderSettings;
  const AToken: IMediaCancellationToken): IMediaReader;
begin
  Result:=OpenMediaBytes(ABytes, ASettings, AToken);
end;

class function TMediaProbe.ProbeFile(const AFilename: String; const ASettings: TMediaInputSettings;
  const AToken: IMediaCancellationToken): TMediaInfo;
begin
  Result:=ProbeLocalFile(AFilename, ASettings, AToken);
end;

class function TMediaReader.OpenURL(const AURL: String; const ASettings: TMediaReaderSettings;
  const AToken: IMediaCancellationToken): IMediaReader;
begin
  Result:=OpenMediaURL(AURL, ASettings, AToken);
end;

class function TMediaProbe.ProbeURL(const AURL: String; const ASettings: TMediaInputSettings;
  const AToken: IMediaCancellationToken): TMediaInfo;
begin
  Result:=ProbeRemoteURL(AURL, ASettings, AToken);
end;

class function TMediaProbe.ProbeBytes(const ABytes: TBytes; const ASettings: TMediaInputSettings;
  const AToken: IMediaCancellationToken): TMediaInfo;
begin
  Result:=ProbeOwnedBytes(ABytes, ASettings, AToken);
end;

class function TMediaProbe.SelectStream(const AInfo: TMediaInfo; AKind: TMediaKind; ARequestedIndex: Integer): Integer;
var
  Streams: TMediaStreams;
  I: Integer;
  Best: Integer;
  Better: Boolean;
begin
  Result:=-1;
  if NOT (AKind IN [mkAudio, mkVideo]) OR (ARequestedIndex < -2) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Select stream', 'Only audio/video and valid selection indexes are supported');
  if ARequestedIndex = -2 then
    Exit;

  Streams:=AInfo.Streams;
  Best:=-1;
  for I:=0 to Length(Streams) - 1 do
  begin
    if ARequestedIndex >= 0 then
    begin
      if Streams[I].Index = ARequestedIndex then
      begin
        if Streams[I].Kind <> AKind then
          raise EFFmpegMediaError.Create(mecInvalidSettings, 'Select stream', 'The selected stream has a different media kind');
        if NOT Streams[I].DecoderAvailable then
          raise EFFmpegMediaError.Create(mecUnsupported, 'Select stream', 'No decoder for the selected stream');
        Exit(Streams[I].Index);
      end;
    end else
    if (Streams[I].Kind = AKind) AND NOT Streams[I].AttachedArt AND Streams[I].DecoderAvailable then
    begin
      Better:=Best < 0;
      if NOT Better then
      begin
        Better:=Streams[I].DefaultTrack AND NOT Streams[Best].DefaultTrack;
        if Streams[I].DefaultTrack = Streams[Best].DefaultTrack then
          case AKind of
            mkVideo: Better:=Int64(Streams[I].Width) * Streams[I].Height > Int64(Streams[Best].Width) * Streams[Best].Height;
            mkAudio: Better:=Streams[I].ChannelLayout.Channels > Streams[Best].ChannelLayout.Channels;
          end;
      end;
      if Better then
        Best:=I;
    end;
  end;

  if ARequestedIndex >= 0 then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Select stream', 'The requested stream index does not exist');
  if Best >= 0 then
    Result:=Streams[Best].Index;
end;

end.
