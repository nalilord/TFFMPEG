unit TFFmpeg.Media.Internal.Devices.DShow;

interface

uses
  TFFmpeg.Media.Devices;

function DShowBackendAvailable(const ABackend: String): Boolean;
function DShowListDevices(const ABackend: String): TMediaDeviceList;
function DShowQueryModes(const ADeviceID: String): TMediaDeviceModes;
procedure RetainDShowCaptureModule;

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
  System.Classes,
  System.SyncObjs,
  System.Variants,
  Winapi.Windows,
  Winapi.ActiveX,
  Winapi.DirectShow9,
  Winapi.MMSystem,
  libavdevice,
  libavformat,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Errors;

{$IFDEF MEDIA_DSHOW_WINDOWS}
const
  DEVICE_LIBRARY_SEARCH_SYSTEM32 = $00000800;

var
  CaptureModule: HMODULE;
  CaptureModuleLock: TCriticalSection;
{$ENDIF}

procedure RetainDShowCaptureModule;
{$IFDEF MEDIA_DSHOW_WINDOWS}
var
  Directory: Array[0..MAX_PATH] of Char;
  Count: Cardinal;
  Filename: String;
  Code: Cardinal;
{$ENDIF}
begin
{$IFDEF MEDIA_DSHOW_WINDOWS}
  CaptureModuleLock.Acquire;
  try
    if CaptureModule <> 0 then
      Exit;
    Count:=GetSystemDirectory(Directory, Length(Directory));
    if (Count = 0) OR (Count >= Cardinal(Length(Directory))) then
      raise EFFmpegMediaError.Create(mecInputOutput, 'Initialize DirectShow', 'Cannot resolve the Windows system directory');
    Filename:=IncludeTrailingPathDelimiter(String(Directory)) + 'kswdmcap.ax';
    // This Windows capture module leaks WPP registrations on repeated unload
    // (17 handles/cycle with the tested 10.0.26100.* modules). Keep one owned module
    // reference until unit finalization, independently of per-session graphs.
    // An absolute system path prevents application-directory DLL substitution.
    CaptureModule:=LoadLibraryEx(PChar(Filename), 0, DEVICE_LIBRARY_SEARCH_SYSTEM32);
    if CaptureModule = 0 then
    begin
      Code:=GetLastError;
      raise EFFmpegMediaError.Create(mecInputOutput, 'Initialize DirectShow', 'Cannot load the Windows capture module: ' + SysErrorMessage(Code), Code);
    end;
  finally
    CaptureModuleLock.Release;
  end;
{$ELSE}
  raise EFFmpegMediaError.Create(mecUnsupported, 'Initialize DirectShow', 'DirectShow capture requires Delphi Windows');
{$ENDIF}
end;

procedure ValidateName(const AValue, AOperation: String);
begin
  if (AValue = '') OR (Pos(#0, AValue) > 0) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, AOperation, 'A nonempty identifier without NUL is required');
end;

function DShowBackendAvailable(const ABackend: String): Boolean;
begin
  Result:=False;
  ValidateName(ABackend, 'Query device backend');
{$IFDEF MEDIA_DSHOW_WINDOWS}
  if SameText(ABackend, 'dshow') then
    Result:=Assigned(av_find_input_format('dshow'));
{$ENDIF}
end;

{$IFDEF MEDIA_DSHOW_WINDOWS}
const
  WAVE_FORMAT_IEEE_FLOAT = $0003;

type
  TDeviceQueryThread = class(TThread)
  private
    FDeviceID: String;
    FQueryModes: Boolean;
    FDevices: TMediaDeviceList;
    FModes: TMediaDeviceModes;
    FError: String;
    FCategory: TMediaErrorCategory;
    FHasNativeCode: Boolean;
    FNativeCode: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const ADeviceID: String; AQueryModes: Boolean);
    procedure CheckError;
    property Devices: TMediaDeviceList read FDevices;
    property Modes: TMediaDeviceModes read FModes;
  end;

procedure CheckCOM(ACode: HResult; const AOperation: String);
begin
  if ACode < 0 then
    if ACode = E_ACCESSDENIED then
      raise EFFmpegMediaError.Create(mecInputOutput, AOperation, 'Device access was denied', ACode)
    else
      raise EFFmpegMediaError.Create(mecInputOutput, AOperation, 'DirectShow/COM failed: ' + SysErrorMessage(ACode), ACode);
end;

function DeviceID(AKind: TMediaKind; const AMoniker: String): String;
begin
  Result:='dshow:audio:' + AMoniker;
  if AKind = mkVideo then
    Result:='dshow:video:' + AMoniker;
end;

function EnumerateOnThread(const AFindID: String; out AFound: IMoniker): TMediaDeviceInfos;
var
  Enumerator: ICreateDevEnum;
  Monikers: IEnumMoniker;
  Moniker: IMoniker;
  BindContext: IBindCtx;
  Bag: IPropertyBag;
  Display: PWideChar;
  Value: OleVariant;
  Info: TMediaDeviceInfo;
  Category: TGUID;
  Code: HResult;
  KindIndex: Integer;
begin
  Result:=nil;
  AFound:=nil;
  CheckCOM(CoCreateInstance(CLSID_SystemDeviceEnum, nil, CLSCTX_INPROC_SERVER, ICreateDevEnum, Enumerator), 'Enumerate devices');
  CheckCOM(CreateBindCtx(0, BindContext), 'Create device binding context');
  for KindIndex:=0 to 1 do
  begin
    Category:=CLSID_VideoInputDeviceCategory;
    if KindIndex = 1 then
      Category:=CLSID_AudioInputDeviceCategory;
    Monikers:=nil;
    Code:=Enumerator.CreateClassEnumerator(Category, Monikers, 0);
    // Empty categories return S_FALSE with a nil enumerator, not a failure.
    if Code = S_FALSE then
      Continue;
    CheckCOM(Code, 'Enumerate device category');
    if NOT Assigned(Monikers) then
      raise EFFmpegMediaError.Create(mecInputOutput, 'Enumerate devices', 'COM returned no category enumerator');
    while True do
    begin
      Moniker:=nil;
      Code:=Monikers.Next(1, Moniker, nil);
      if Code = S_FALSE then
        Break;
      CheckCOM(Code, 'Enumerate device');
      Info:=Default(TMediaDeviceInfo);
      Info.Backend:='dshow';
      Info.Kind:=mkVideo;
      if KindIndex = 1 then
        Info.Kind:=mkAudio;
      Display:=nil;
      try
        CheckCOM(Moniker.GetDisplayName(BindContext, nil, Display), 'Read device identifier');
        Info.ID:=DeviceID(Info.Kind, String(Display));
      finally
        CoTaskMemFree(Display);
      end;
      Bag:=nil;
      if Moniker.BindToStorage(nil, nil, IPropertyBag, Bag) >= 0 then
      begin
        Value:=Unassigned;
        try
          if Bag.Read('FriendlyName', Value, nil) >= 0 then
            Info.DisplayName:=VarToStr(Value);
        finally
          VarClear(Value);
        end;
      end;
      if Info.DisplayName = '' then
        Info.DisplayName:=Info.ID;
      ValidateName(Info.ID, 'Read device identifier');
      if Length(Result) >= 256 then
        raise EFFmpegMediaError.Create(mecUnsupported, 'Enumerate devices', 'Device count exceeds the 256-device bound');
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)]:=Info;
      if (AFindID <> '') AND SameText(Info.ID, AFindID) then
        AFound:=Moniker;
    end;
  end;
  // All COM locals release before the caller uninitializes its worker apartment.
end;

function FrameRate(AInterval: Int64): TMediaRate;
var
  Numerator, Denominator, Remainder: Int64;
  GCD, Other: Int64;
begin
  Result:=TMediaRate.Unknown;
  if AInterval <= 0 then
    Exit;
  GCD:=10000000;
  Other:=AInterval;
  while Other <> 0 do
  begin
    Remainder:=GCD MOD Other;
    GCD:=Other;
    Other:=Remainder;
  end;
  Numerator:=10000000 DIV GCD;
  Denominator:=AInterval DIV GCD;
  if (Numerator <= High(Integer)) AND (Denominator <= High(Integer)) then
    Result:=TMediaRate.Create(Integer(Numerator), Integer(Denominator));
end;

function VideoFormat(const ASubtype: TGUID): String;
begin
  Result:=GUIDToString(ASubtype);
  if IsEqualGUID(ASubtype, MEDIASUBTYPE_RGB24) then
    Exit('bgr24');
  if IsEqualGUID(ASubtype, MEDIASUBTYPE_RGB32) then
    Exit('bgr0');
  case ASubtype.D1 of
    $47504A4D: Result:='mjpeg';
    $34363248, $31435641: Result:='h264';
    $32595559: Result:='yuyv422';
    $59565955: Result:='uyvy422';
    $3231564E: Result:='nv12';
    $30323449, $56555949: Result:='yuv420p';
    $3250474D: Result:='mpeg2video';
  end;
end;

function ParseMode(AMedia: PAMMediaType; const ACaps: TBytes; const APinName: String): TMediaDeviceMode;
var
  Bitmap: PBitmapInfoHeader;
  Interval: Int64;
  Wave: PWaveFormatEx;
  VideoCaps: PVideoStreamConfigCaps;
  AudioCaps: PAudioStreamConfigCaps;
begin
  Result:=Default(TMediaDeviceMode);
  Result.PinName:=APinName;
  Result.FormatName:=GUIDToString(AMedia.subtype);
  if NOT Assigned(AMedia.pbFormat) OR (AMedia.cbFormat > 1024 * 1024) then
    Exit;
  Bitmap:=nil;
  Interval:=0;
  if IsEqualGUID(AMedia.formattype, FORMAT_VideoInfo) AND (AMedia.cbFormat >= SizeOf(TVideoInfoHeader)) then
  begin
    Bitmap:=@PVideoInfoHeader(AMedia.pbFormat).bmiHeader;
    Interval:=PVideoInfoHeader(AMedia.pbFormat).AvgTimePerFrame;
  end else
  if IsEqualGUID(AMedia.formattype, FORMAT_VideoInfo2) AND (AMedia.cbFormat >= SizeOf(TVideoInfoHeader2)) then
  begin
    Bitmap:=@PVideoInfoHeader2(AMedia.pbFormat).bmiHeader;
    Interval:=PVideoInfoHeader2(AMedia.pbFormat).AvgTimePerFrame;
  end;
  if Assigned(Bitmap) then
  begin
    if (Bitmap.biWidth < 1) OR (Bitmap.biHeight = Low(Integer)) then
      Exit;
    Result.Kind:=mkVideo;
    Result.FormatName:=VideoFormat(AMedia.subtype);
    Result.Width:=Bitmap.biWidth;
    Result.Height:=Abs(Bitmap.biHeight);
    Result.FrameRate:=FrameRate(Interval);
    if Length(ACaps) >= SizeOf(TVideoStreamConfigCaps) then
    begin
      VideoCaps:=PVideoStreamConfigCaps(@ACaps[0]);
      Result.MinWidth:=VideoCaps.MinOutputSize.cx;
      Result.MaxWidth:=VideoCaps.MaxOutputSize.cx;
      Result.MinHeight:=VideoCaps.MinOutputSize.cy;
      Result.MaxHeight:=VideoCaps.MaxOutputSize.cy;
      Result.WidthStep:=VideoCaps.OutputGranularityX;
      Result.HeightStep:=VideoCaps.OutputGranularityY;
      Result.MinFrameRate:=FrameRate(VideoCaps.MaxFrameInterval);
      Result.MaxFrameRate:=FrameRate(VideoCaps.MinFrameInterval);
    end;
  end else
  if IsEqualGUID(AMedia.formattype, FORMAT_WaveFormatEx) AND (AMedia.cbFormat >= 16) then
  begin
    Wave:=PWaveFormatEx(AMedia.pbFormat);
    Result.Kind:=mkAudio;
    if Wave.nSamplesPerSec <= Cardinal(High(Integer)) then
      Result.SampleRate:=Integer(Wave.nSamplesPerSec);
    Result.Channels:=Wave.nChannels;
    Result.BitsPerSample:=Wave.wBitsPerSample;
    if Wave.wFormatTag = WAVE_FORMAT_PCM then
      Result.FormatName:='pcm_s' + IntToStr(Wave.wBitsPerSample) + 'le'
    else
    if Wave.wFormatTag = WAVE_FORMAT_IEEE_FLOAT then
      Result.FormatName:='pcm_f' + IntToStr(Wave.wBitsPerSample) + 'le';
    if (Wave.wFormatTag = WAVE_FORMAT_PCM) AND (Wave.wBitsPerSample = 8) then
      Result.FormatName:='pcm_u8';
    if Length(ACaps) >= SizeOf(TAudioStreamConfigCaps) then
    begin
      AudioCaps:=PAudioStreamConfigCaps(@ACaps[0]);
      if AudioCaps.MinimumBitsPerSample <= Cardinal(High(Integer)) then
        Result.MinBitsPerSample:=Integer(AudioCaps.MinimumBitsPerSample);
      if AudioCaps.MaximumBitsPerSample <= Cardinal(High(Integer)) then
        Result.MaxBitsPerSample:=Integer(AudioCaps.MaximumBitsPerSample);
      if AudioCaps.BitsPerSampleGranularity <= Cardinal(High(Integer)) then
        Result.BitsPerSampleStep:=Integer(AudioCaps.BitsPerSampleGranularity);
      if AudioCaps.SampleFrequencyGranularity <= Cardinal(High(Integer)) then
        Result.SampleRateStep:=Integer(AudioCaps.SampleFrequencyGranularity);
      if AudioCaps.ChannelsGranularity <= Cardinal(High(Integer)) then
        Result.ChannelsStep:=Integer(AudioCaps.ChannelsGranularity);
      if AudioCaps.MinimumSampleFrequency <= Cardinal(High(Integer)) then
        Result.MinSampleRate:=Integer(AudioCaps.MinimumSampleFrequency);
      if AudioCaps.MaximumSampleFrequency <= Cardinal(High(Integer)) then
        Result.MaxSampleRate:=Integer(AudioCaps.MaximumSampleFrequency);
      if AudioCaps.MinimumChannels <= Cardinal(High(Integer)) then
        Result.MinChannels:=Integer(AudioCaps.MinimumChannels);
      if AudioCaps.MaximumChannels <= Cardinal(High(Integer)) then
        Result.MaxChannels:=Integer(AudioCaps.MaximumChannels);
    end;
  end;
end;

procedure FreeMediaType(var AMedia: PAMMediaType);
begin
  if NOT Assigned(AMedia) then
    Exit;
  AMedia.pUnk:=nil;
  CoTaskMemFree(AMedia.pbFormat);
  CoTaskMemFree(AMedia);
  AMedia:=nil;
end;

function ModesOnThread(const ADeviceID: String): TMediaDeviceModes;
var
  Devices: TMediaDeviceInfos;
  Moniker: IMoniker;
  Filter: IBaseFilter;
  Pins: IEnumPins;
  Pin: IPin;
  Direction: TPinDirection;
  PinInfo: TPinInfo;
  Config: IAMStreamConfig;
  Media: PAMMediaType;
  Caps: TBytes;
  Modes: TMediaDeviceModeArray;
  Mode: TMediaDeviceMode;
  Code: HResult;
  Count, CapsSize, I, PinCount: Integer;
  Supported: Boolean;
begin
  Result:=Default(TMediaDeviceModes);
  Result.DeviceID:=ADeviceID;
  Result.Status:=mdqsUnsupported;
  Devices:=EnumerateOnThread(ADeviceID, Moniker);
  if NOT Assigned(Moniker) then
    raise EFFmpegMediaError.Create(mecInputOutput, 'Query device modes', 'The device identifier is no longer present');
  if SameText(Copy(ADeviceID, 1, 12), 'dshow:video:') then
    RetainDShowCaptureModule;
  CheckCOM(Moniker.BindToObject(nil, nil, IBaseFilter, Filter), 'Open device for mode query');
  CheckCOM(Filter.EnumPins(Pins), 'Enumerate device pins');
  Supported:=False;
  PinCount:=0;
  while True do
  begin
    Pin:=nil;
    Code:=Pins.Next(1, Pin, nil);
    if Code = S_FALSE then
      Break;
    CheckCOM(Code, 'Read device pin');
    Inc(PinCount);
    if PinCount > 256 then
      raise EFFmpegMediaError.Create(mecUnsupported, 'Query device modes', 'Pin count exceeds bound');
    CheckCOM(Pin.QueryDirection(Direction), 'Read device pin direction');
    if Direction <> PINDIR_OUTPUT then
      Continue;
    Config:=nil;
    if Pin.QueryInterface(IAMStreamConfig, Config) < 0 then
      Continue;
    Count:=0;
    CapsSize:=0;
    Code:=Config.GetNumberOfCapabilities(Count, CapsSize);
    if Code = E_NOTIMPL then
      Continue;
    CheckCOM(Code, 'Read device mode count');
    if (Count < 0) OR (Count > 4096) OR (CapsSize < 1) OR (CapsSize > 1024 * 1024) then
      raise EFFmpegMediaError.Create(mecUnsupported, 'Query device modes', 'Driver capability count/size exceeds bounds');
    Supported:=True;
    SetLength(Caps, CapsSize);
    PinInfo:=Default(TPinInfo);
    CheckCOM(Pin.QueryPinInfo(PinInfo), 'Read device pin name');
    try
      for I:=0 to Count - 1 do
      begin
        Media:=nil;
        try
          CheckCOM(Config.GetStreamCaps(I, Media, Caps[0]), 'Read device mode');
          if NOT Assigned(Media) then
            raise EFFmpegMediaError.Create(mecInputOutput, 'Query device modes', 'Driver returned no media type');
          Mode:=ParseMode(Media, Caps, String(PWideChar(@PinInfo.achName[0])));
          if Length(Modes) >= 16384 then
            raise EFFmpegMediaError.Create(mecUnsupported, 'Query device modes', 'Mode count exceeds bound');
          SetLength(Modes, Length(Modes) + 1);
          Modes[High(Modes)]:=Mode;
        finally
          FreeMediaType(Media);
        end;
      end;
    finally
      PinInfo.pFilter:=nil;
    end;
  end;
  if Supported then
  begin
    Result.Status:=mdqsEmpty;
    if Length(Modes) > 0 then
      Result.Status:=mdqsAvailable;
  end;
  Result.Modes:=Modes;
end;

constructor TDeviceQueryThread.Create(const ADeviceID: String; AQueryModes: Boolean);
begin
  inherited Create(True);
  FreeOnTerminate:=False;
  FDeviceID:=ADeviceID;
  FQueryModes:=AQueryModes;
end;

procedure TDeviceQueryThread.Execute;
var
  Found: IMoniker;
begin
  try
    CheckCOM(CoInitializeEx(nil, COINIT_APARTMENTTHREADED), 'Initialize device query COM');
    try
      if FQueryModes then
        FModes:=ModesOnThread(FDeviceID)
      else
      begin
        FDevices.Backend:='dshow';
        FDevices.Devices:=EnumerateOnThread('', Found);
        FDevices.Status:=mdqsEmpty;
        if Length(FDevices.Devices) > 0 then
          FDevices.Status:=mdqsAvailable;
      end;
    finally
      Found:=nil;
      CoUninitialize;
    end;
  except
    on E: EFFmpegMediaError do
    begin
      FError:=E.Message;
      FCategory:=E.Category;
      FHasNativeCode:=E.HasNativeCode;
      FNativeCode:=E.NativeCode;
    end;
    on E: Exception do
    begin
      FError:=E.ClassName + ': ' + E.Message;
      FCategory:=mecInputOutput;
    end;
    else
    begin
      FError:='Unexpected device query failure';
      FCategory:=mecInputOutput;
    end;
  end;
end;

procedure TDeviceQueryThread.CheckError;
begin
  if FError <> '' then
    if FHasNativeCode then
      raise EFFmpegMediaError.Create(FCategory, 'Device query', FError, FNativeCode)
    else
      raise EFFmpegMediaError.Create(FCategory, 'Device query', FError);
end;
{$ENDIF}

function DShowListDevices(const ABackend: String): TMediaDeviceList;
{$IFDEF MEDIA_DSHOW_WINDOWS}
var
  Worker: TDeviceQueryThread;
{$ENDIF}
begin
  Result:=Default(TMediaDeviceList);
  Result.Backend:=ABackend;
  Result.Status:=mdqsUnsupported;
  if NOT DShowBackendAvailable(ABackend) then
    Exit;
{$IFDEF MEDIA_DSHOW_WINDOWS}
  Worker:=TDeviceQueryThread.Create('', False);
  try
    Worker.Start;
    Worker.WaitFor;
    Worker.CheckError;
    Result:=Worker.Devices;
  finally
    Worker.Free;
  end;
{$ENDIF}
end;

function DShowQueryModes(const ADeviceID: String): TMediaDeviceModes;
{$IFDEF MEDIA_DSHOW_WINDOWS}
var
  Worker: TDeviceQueryThread;
{$ENDIF}
begin
  Result:=Default(TMediaDeviceModes);
  Result.DeviceID:=ADeviceID;
  Result.Status:=mdqsUnsupported;
  ValidateName(ADeviceID, 'Query device modes');
  if NOT SameText(Copy(ADeviceID, 1, 12), 'dshow:video:') AND NOT SameText(Copy(ADeviceID, 1, 12), 'dshow:audio:') then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Query device modes', 'A backend-qualified dshow video/audio identifier is required');
  if NOT DShowBackendAvailable('dshow') then
    Exit;
{$IFDEF MEDIA_DSHOW_WINDOWS}
  Worker:=TDeviceQueryThread.Create(ADeviceID, True);
  try
    Worker.Start;
    Worker.WaitFor;
    Worker.CheckError;
    Result:=Worker.Modes;
  finally
    Worker.Free;
  end;
{$ENDIF}
end;

{$IFDEF MEDIA_DSHOW_WINDOWS}
initialization
  CaptureModuleLock:=TCriticalSection.Create;
  avdevice_register_all;

finalization
  if CaptureModule <> 0 then
    FreeLibrary(CaptureModule);
  CaptureModuleLock.Free;
{$ENDIF}

end.
