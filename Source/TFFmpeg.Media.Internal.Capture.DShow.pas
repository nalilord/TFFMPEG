unit TFFmpeg.Media.Internal.Capture.DShow;

interface

uses
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Internal.Capture.Source;

function CreateDShowCaptureSource: IMediaCaptureSource;
function DShowFrameRateText(const ARate: TMediaRate): String;

implementation

{$IFDEF MSWINDOWS}
{$IFNDEF FPC}
{$DEFINE MEDIA_DSHOW_WINDOWS}
{$ENDIF}
{$ENDIF}

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
{$IFDEF MEDIA_DSHOW_WINDOWS}
  Winapi.Windows,
  Winapi.ActiveX,
  libavutil_rational,
  libavutil_parseutils,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Devices,
  TFFmpeg.Media.Reader,
  TFFmpeg.Media.Internal.Reader,
  TFFmpeg.Media.Internal.Devices.DShow,
{$ENDIF}
  TFFmpeg.Media.Errors;

function DShowFrameRateText(const ARate: TMediaRate): String;
{$IFDEF MEDIA_DSHOW_WINDOWS}
var
  NativeRate: TAVRational;
  Text: UTF8String;
  Interval: Int64;
{$ENDIF}
begin
  Result:='';
  if NOT ARate.Known then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Device frame rate', 'An explicit positive rational rate is required');
{$IFDEF MEDIA_DSHOW_WINDOWS}
  Interval:=Int64(10000000) * ARate.Denominator DIV ARate.Numerator;
  if Interval < 1 then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Device frame rate', 'Frame period is below the DirectShow clock resolution');
  Result:=IntToStr(ARate.Numerator) + '/' + IntToStr(ARate.Denominator);
  Text:=UTF8String(Result);
  if (av_parse_video_rate(@NativeRate, PAnsiChar(Text)) >= 0) AND (NativeRate.num > 0) AND
    (Int64(NativeRate.den) * 10000000 DIV NativeRate.num = Interval) then
    Exit;
  // FFmpeg limits parsed video rates to 1001000 before DirectShow truncates to
  // 100-ns intervals. An exact advertised ratio may round across that boundary.
  // Choose the midpoint of the SAME native tick, then verify the actual parser;
  // never silently select a neighboring supported interval or another mode.
  NativeRate:=av_d2q(10000000.0 / (Interval + 0.5), 1001000);
  Result:=IntToStr(NativeRate.num) + '/' + IntToStr(NativeRate.den);
  Text:=UTF8String(Result);
  if (av_parse_video_rate(@NativeRate, PAnsiChar(Text)) < 0) OR (NativeRate.num <= 0) OR
    (Int64(NativeRate.den) * 10000000 DIV NativeRate.num <> Interval) then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Device frame rate', 'FFmpeg cannot represent the requested DirectShow frame interval');
{$ELSE}
  raise EFFmpegMediaError.Create(mecUnsupported, 'Device frame rate', 'DirectShow capture requires Delphi Windows');
{$ENDIF}
end;

{$IFDEF MEDIA_DSHOW_WINDOWS}
type
  TDShowCaptureSource = class(TInterfacedObject, IMediaCaptureSource)
  private
    FCOMInitialized: Boolean;
    FReader: IMediaReader;
  public
    destructor Destroy; override;
    procedure Open(const ASettings: TMediaCaptureSettings; const AToken: IMediaCancellationToken);
    function GetInfo: TMediaInfo;
    function ReadSample(out ASample: IMediaSample): TMediaReadStatus;
    procedure Close;
  end;

procedure RaiseDeviceIO(const AOperation, AMessage: String; AError: EFFmpegMediaError);
begin
  if AError.HasNativeCode then
    raise EFFmpegMediaError.Create(mecInputOutput, AOperation, AMessage + AError.Message, AError.NativeCode)
  else
    raise EFFmpegMediaError.Create(mecInputOutput, AOperation, AMessage + AError.Message);
end;

function NativeName(const AID: String; const ADevices: TMediaDeviceInfos): String;
var
  I: Integer;
begin
  Result:='';
  if AID = '' then
    Exit;
  for I:=0 to Length(ADevices) - 1 do
    if SameText(AID, ADevices[I].ID) then
      Exit(StringReplace(Copy(ADevices[I].ID, 13, MaxInt), ':', '_', [rfReplaceAll]));
  raise EFFmpegMediaError.Create(mecInputOutput, 'Open capture', 'The requested device is no longer present');
end;

procedure TDShowCaptureSource.Open(const ASettings: TMediaCaptureSettings; const AToken: IMediaCancellationToken);
var
  Code: HResult;
  Listing: TMediaDeviceList;
  Devices: TMediaDeviceInfos;
  Name, AudioName: String;
  Settings: TMediaReaderSettings;
  Input: TMediaInputSettings;
  Options: TMediaOptions;
  Streams: TMediaStreams;
  I: Integer;

  procedure AddOption(const AKey, AValue: String);
  begin
    SetLength(Options, Length(Options) + 1);
    Options[High(Options)]:=TMediaOption.Create(mosDemuxer, AKey, AValue);
  end;

begin
  Close;
  ASettings.Validate;
  if NOT TMediaDevices.BackendAvailable then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Open capture', 'The deployed runtime has no DirectShow input backend');
  if ASettings.VideoDeviceID <> '' then
    RetainDShowCaptureModule;
  Code:=CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  if Code < 0 then
    raise EFFmpegMediaError.Create(mecInputOutput, 'Open capture COM', SysErrorMessage(Code), Code);
  FCOMInitialized:=True;
  try
    Listing:=TMediaDevices.ListDevices;
    Devices:=Listing.Devices;
    Name:=NativeName(ASettings.VideoDeviceID, Devices);
    AudioName:=NativeName(ASettings.AudioDeviceID, Devices);
    if Name <> '' then
      Name:='video=' + Name;
    if AudioName <> '' then
    begin
      if Name <> '' then
        Name:=Name + ':';
      Name:=Name + 'audio=' + AudioName;
    end;
    Settings:=TMediaReaderSettings.Default;
    Settings.PixelFormat:=ASettings.PixelFormat;
    Settings.SampleFormat:=ASettings.SampleFormat;
    Settings.SampleRate:=ASettings.SampleRate;
    Settings.Channels:=ASettings.Channels;
    if ASettings.VideoDeviceID = '' then
      Settings.VideoStreamIndex:=-2;
    if ASettings.AudioDeviceID = '' then
      Settings.AudioStreamIndex:=-2;
    if ASettings.UseVideoDeviceTimestamps then
      AddOption('use_video_device_timestamps', '1')
    else
      AddOption('use_video_device_timestamps', '0');
    AddOption('rtbufsize', IntToStr(ASettings.NativeBufferBytes));
    // This bounds probing without changing the native device clock or queue.
    AddOption('analyzeduration', '1000000');
    if ASettings.VideoMode.Width > 0 then
      AddOption('video_size', IntToStr(ASettings.VideoMode.Width) + 'x' + IntToStr(ASettings.VideoMode.Height));
    if ASettings.VideoMode.FrameRate.Known then
      AddOption('framerate', DShowFrameRateText(ASettings.VideoMode.FrameRate));
    if ASettings.VideoMode.FormatName <> '' then
      AddOption('pixel_format', ASettings.VideoMode.FormatName);
    if ASettings.VideoMode.PinName <> '' then
      AddOption('video_pin_name', ASettings.VideoMode.PinName);
    if ASettings.AudioMode.SampleRate > 0 then
      AddOption('sample_rate', IntToStr(ASettings.AudioMode.SampleRate));
    if ASettings.AudioMode.Channels > 0 then
      AddOption('channels', IntToStr(ASettings.AudioMode.Channels));
    if ASettings.AudioMode.BitsPerSample > 0 then
      AddOption('sample_size', IntToStr(ASettings.AudioMode.BitsPerSample));
    if ASettings.AudioMode.PinName <> '' then
      AddOption('audio_pin_name', ASettings.AudioMode.PinName);
    if ASettings.AudioBufferMilliseconds > 0 then
      AddOption('audio_buffer_size', IntToStr(ASettings.AudioBufferMilliseconds));
    Input:=Settings.Input;
    Input.MaxStreams:=2;
    Input.MaxProbeBytes:=ASettings.ProbeBufferBytes;
    Input.TimeoutMilliseconds:=ASettings.OperationTimeoutMilliseconds;
    Input.Options:=Options;
    Settings.Input:=Input;
    try
      FReader:=OpenMediaDevice(Name, 'dshow', Settings, AToken);
    except
      on E: EFFmpegMediaError do
      begin
        if E.Category = mecInputOutput then
          RaiseDeviceIO('Open capture', 'DirectShow could not open the selected devices/mode (unsupported, busy, unavailable or denied): ', E);
        raise;
      end;
    end;
    Streams:=FReader.Info.Streams;
    for I:=0 to Length(Streams) - 1 do
    begin
      if NOT Streams[I].StartTime.Valid then
        raise EFFmpegMediaError.Create(mecUnsupported, 'Open capture', 'Probing did not establish every stream start within the probe byte bound');
      if (Streams[I].Kind = mkVideo) AND (ASettings.VideoMode.Width > 0) AND
        ((Streams[I].Width <> ASettings.VideoMode.Width) OR (Streams[I].Height <> ASettings.VideoMode.Height)) then
        raise EFFmpegMediaError.Create(mecUnsupported, 'Open capture', 'Driver negotiated different video dimensions');
      if (Streams[I].Kind = mkVideo) AND (ASettings.VideoMode.FormatName <> '') AND
        (Streams[I].PixelFormatName <> ASettings.VideoMode.FormatName) then
        raise EFFmpegMediaError.Create(mecUnsupported, 'Open capture', 'Driver negotiated a different pixel format');
      if (Streams[I].Kind = mkVideo) AND ASettings.VideoMode.FrameRate.Known then
        if NOT Streams[I].FrameRate.Known OR
          (Abs(Streams[I].FrameRate.Value / ASettings.VideoMode.FrameRate.Value - 1) > 0.0001) then
          raise EFFmpegMediaError.Create(mecUnsupported, 'Open capture', 'Driver negotiated a different frame rate');
      if (Streams[I].Kind = mkAudio) AND (ASettings.AudioMode.BitsPerSample > 0) AND
        (Streams[I].BitsPerSample <> ASettings.AudioMode.BitsPerSample) then
        raise EFFmpegMediaError.Create(mecUnsupported, 'Open capture', 'Driver negotiated a different PCM bit depth');
      if (Streams[I].Kind = mkAudio) AND (ASettings.AudioMode.FormatName <> '') AND
        (Streams[I].CodecName <> ASettings.AudioMode.FormatName) then
        raise EFFmpegMediaError.Create(mecUnsupported, 'Open capture', 'Driver negotiated a different audio device format');
      if (Streams[I].Kind = mkAudio) AND
        (((ASettings.AudioMode.SampleRate > 0) AND (Streams[I].SampleRate <> ASettings.AudioMode.SampleRate)) OR
        ((ASettings.AudioMode.Channels > 0) AND (Streams[I].ChannelLayout.Channels <> ASettings.AudioMode.Channels))) then
        raise EFFmpegMediaError.Create(mecUnsupported, 'Open capture', 'Driver negotiated a different audio rate/layout');
    end;
  except
    Close;
    raise;
  end;
end;

destructor TDShowCaptureSource.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TDShowCaptureSource.Close;
begin
  try
    if Assigned(FReader) then
      FReader.Close;
  finally
    FReader:=nil;
    if FCOMInitialized then
    begin
      FCOMInitialized:=False;
      CoUninitialize;
    end;
  end;
end;

function TDShowCaptureSource.GetInfo: TMediaInfo;
begin
  Result:=FReader.Info;
end;

function TDShowCaptureSource.ReadSample(out ASample: IMediaSample): TMediaReadStatus;
begin
  Result:=mrsEndOfInput;
  try
    Result:=FReader.ReadSample(ASample);
  except
    on E: EFFmpegMediaError do
    begin
      if E.Category = mecInputOutput then
        RaiseDeviceIO('Read capture', 'The source disconnected or its driver failed: ', E);
      raise;
    end;
  end;
end;
{$ENDIF}

function CreateDShowCaptureSource: IMediaCaptureSource;
begin
  Result:=nil;
{$IFDEF MEDIA_DSHOW_WINDOWS}
  Result:=TDShowCaptureSource.Create;
{$ELSE}
  raise EFFmpegMediaError.Create(mecUnsupported, 'Open capture', 'DirectShow capture is implemented for Delphi Windows targets only');
{$ENDIF}
end;

end.
