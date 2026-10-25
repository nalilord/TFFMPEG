unit TFFmpeg.Media.Devices;

interface

uses
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Frames;

type
  TMediaDeviceQueryStatus = (mdqsAvailable, mdqsEmpty, mdqsUnsupported);

  TMediaDeviceInfo = record
  private
    FID: String;
    FBackend: String;
    FDisplayName: String;
    FKind: TMediaKind;
  public
    property ID: String read FID write FID;
    property Backend: String read FBackend write FBackend;
    property DisplayName: String read FDisplayName write FDisplayName;
    property Kind: TMediaKind read FKind write FKind;
  end;
  TMediaDeviceInfos = Array of TMediaDeviceInfo;

  TMediaDeviceList = record
  private
    FStatus: TMediaDeviceQueryStatus;
    FBackend: String;
    FDevices: TMediaDeviceInfos;
    function GetDevices: TMediaDeviceInfos;
    procedure SetDevices(const AValue: TMediaDeviceInfos);
  public
    property Status: TMediaDeviceQueryStatus read FStatus write FStatus;
    property Backend: String read FBackend write FBackend;
    property Devices: TMediaDeviceInfos read GetDevices write SetDevices;
  end;

  TMediaDeviceMode = record
  private
    FKind: TMediaKind;
    FPinName: String;
    FFormatName: String;
    FWidth: Integer;
    FHeight: Integer;
    FFrameRate: TMediaRate;
    FMinFrameRate: TMediaRate;
    FMaxFrameRate: TMediaRate;
    FSampleRate: Integer;
    FChannels: Integer;
    FBitsPerSample: Integer;
    FMinSampleRate: Integer;
    FMaxSampleRate: Integer;
    FMinChannels: Integer;
    FMaxChannels: Integer;
    FMinWidth: Integer;
    FMaxWidth: Integer;
    FMinHeight: Integer;
    FMaxHeight: Integer;
    FWidthStep: Integer;
    FHeightStep: Integer;
    FMinBitsPerSample: Integer;
    FMaxBitsPerSample: Integer;
    FBitsPerSampleStep: Integer;
    FSampleRateStep: Integer;
    FChannelsStep: Integer;
  public
    property Kind: TMediaKind read FKind write FKind;
    property PinName: String read FPinName write FPinName;
    property FormatName: String read FFormatName write FFormatName;
    property Width: Integer read FWidth write FWidth;
    property Height: Integer read FHeight write FHeight;
    property FrameRate: TMediaRate read FFrameRate write FFrameRate;
    property MinFrameRate: TMediaRate read FMinFrameRate write FMinFrameRate;
    property MaxFrameRate: TMediaRate read FMaxFrameRate write FMaxFrameRate;
    property SampleRate: Integer read FSampleRate write FSampleRate;
    property Channels: Integer read FChannels write FChannels;
    property BitsPerSample: Integer read FBitsPerSample write FBitsPerSample;
    property MinSampleRate: Integer read FMinSampleRate write FMinSampleRate;
    property MaxSampleRate: Integer read FMaxSampleRate write FMaxSampleRate;
    property MinChannels: Integer read FMinChannels write FMinChannels;
    property MaxChannels: Integer read FMaxChannels write FMaxChannels;
    property MinWidth: Integer read FMinWidth write FMinWidth;
    property MaxWidth: Integer read FMaxWidth write FMaxWidth;
    property MinHeight: Integer read FMinHeight write FMinHeight;
    property MaxHeight: Integer read FMaxHeight write FMaxHeight;
    property WidthStep: Integer read FWidthStep write FWidthStep;
    property HeightStep: Integer read FHeightStep write FHeightStep;
    property MinBitsPerSample: Integer read FMinBitsPerSample write FMinBitsPerSample;
    property MaxBitsPerSample: Integer read FMaxBitsPerSample write FMaxBitsPerSample;
    property BitsPerSampleStep: Integer read FBitsPerSampleStep write FBitsPerSampleStep;
    property SampleRateStep: Integer read FSampleRateStep write FSampleRateStep;
    property ChannelsStep: Integer read FChannelsStep write FChannelsStep;
  end;
  TMediaDeviceModeArray = Array of TMediaDeviceMode;

  TMediaDeviceModes = record
  private
    FStatus: TMediaDeviceQueryStatus;
    FDeviceID: String;
    FModes: TMediaDeviceModeArray;
    function GetModes: TMediaDeviceModeArray;
    procedure SetModes(const AValue: TMediaDeviceModeArray);
  public
    property Status: TMediaDeviceQueryStatus read FStatus write FStatus;
    property DeviceID: String read FDeviceID write FDeviceID;
    property Modes: TMediaDeviceModeArray read GetModes write SetModes;
  end;

  TMediaCapturePolicy = (mcpPreview, mcpRecording);
  TMediaAudioOverflow = (maoFail, maoDropOldest);
  TMediaCaptureAudioTiming = (mcatPreserve, mcatSampleClock);
  TMediaCaptureState = (mcsOpening, mcsCapturing, mcsStopping, mcsStopped, mcsCancelled, mcsFailed);
  TMediaCaptureReadStatus = (mcrSample, mcrStopped, mcrCancelled, mcrTimedOut);

  TMediaCaptureSettings = record
  private
    FVideoDeviceID: String;
    FAudioDeviceID: String;
    FUseVideoDeviceTimestamps: Boolean;
    FRequireFixedVideoCadence: Boolean;
    FAudioTiming: TMediaCaptureAudioTiming;
    FAudioTimestampToleranceMilliseconds: Cardinal;
    FVideoMode: TMediaDeviceMode;
    FAudioMode: TMediaDeviceMode;
    FPixelFormat: TMediaPixelFormat;
    FSampleFormat: TMediaSampleFormat;
    FSampleRate: Integer;
    FChannels: Integer;
    FPolicy: TMediaCapturePolicy;
    FAudioOverflow: TMediaAudioOverflow;
    FMaxVideoFrames: Integer;
    FMaxAudioBuffers: Integer;
    FMaxQueueBytes: Integer;
    FNativeBufferBytes: Integer;
    FProbeBufferBytes: Integer;
    FAudioBufferMilliseconds: Integer;
    FOperationTimeoutMilliseconds: Cardinal;
    FMaxClockDriftMilliseconds: Cardinal;
  public
    class function Default: TMediaCaptureSettings; static;
    procedure Validate;
    property VideoDeviceID: String read FVideoDeviceID write FVideoDeviceID;
    property AudioDeviceID: String read FAudioDeviceID write FAudioDeviceID;
    property RequireFixedVideoCadence: Boolean read FRequireFixedVideoCadence write FRequireFixedVideoCadence;
    property AudioTiming: TMediaCaptureAudioTiming read FAudioTiming write FAudioTiming;
    property AudioTimestampToleranceMilliseconds: Cardinal read FAudioTimestampToleranceMilliseconds write FAudioTimestampToleranceMilliseconds;
    property UseVideoDeviceTimestamps: Boolean read FUseVideoDeviceTimestamps write FUseVideoDeviceTimestamps;
    property VideoMode: TMediaDeviceMode read FVideoMode write FVideoMode;
    property AudioMode: TMediaDeviceMode read FAudioMode write FAudioMode;
    property PixelFormat: TMediaPixelFormat read FPixelFormat write FPixelFormat;
    property SampleFormat: TMediaSampleFormat read FSampleFormat write FSampleFormat;
    property SampleRate: Integer read FSampleRate write FSampleRate;
    property Channels: Integer read FChannels write FChannels;
    property Policy: TMediaCapturePolicy read FPolicy write FPolicy;
    property AudioOverflow: TMediaAudioOverflow read FAudioOverflow write FAudioOverflow;
    property MaxVideoFrames: Integer read FMaxVideoFrames write FMaxVideoFrames;
    property MaxAudioBuffers: Integer read FMaxAudioBuffers write FMaxAudioBuffers;
    property MaxQueueBytes: Integer read FMaxQueueBytes write FMaxQueueBytes;
    property ProbeBufferBytes: Integer read FProbeBufferBytes write FProbeBufferBytes;
    property NativeBufferBytes: Integer read FNativeBufferBytes write FNativeBufferBytes;
    property AudioBufferMilliseconds: Integer read FAudioBufferMilliseconds write FAudioBufferMilliseconds;
    property OperationTimeoutMilliseconds: Cardinal read FOperationTimeoutMilliseconds write FOperationTimeoutMilliseconds;
    property MaxClockDriftMilliseconds: Cardinal read FMaxClockDriftMilliseconds write FMaxClockDriftMilliseconds;
  end;

  TMediaCaptureStats = record
  private
    FVideoFramesReceived: Int64;
    FAudioBuffersReceived: Int64;
    FVideoFramesDropped: Int64;
    FAudioBuffersDropped: Int64;
    FDiscontinuities: Int64;
    FVideoCadenceChanges: Int64;
    FAudioTimestampChanges: Int64;
    FAudioClockDrift: TMediaTime;
    FAudioBuffersRetimed: Int64;
    FVideoQueueFrames: Integer;
    FAudioQueueBuffers: Integer;
    FQueuedBytes: Int64;
    FPeakQueuedBytes: Int64;
    FAudioVideoDrift: TMediaTime;
    FStopLatencyMilliseconds: UInt64;
  public
    property VideoFramesReceived: Int64 read FVideoFramesReceived write FVideoFramesReceived;
    property AudioBuffersReceived: Int64 read FAudioBuffersReceived write FAudioBuffersReceived;
    property VideoFramesDropped: Int64 read FVideoFramesDropped write FVideoFramesDropped;
    property AudioBuffersDropped: Int64 read FAudioBuffersDropped write FAudioBuffersDropped;
    property VideoCadenceChanges: Int64 read FVideoCadenceChanges write FVideoCadenceChanges;
    property AudioTimestampChanges: Int64 read FAudioTimestampChanges write FAudioTimestampChanges;
    property AudioClockDrift: TMediaTime read FAudioClockDrift write FAudioClockDrift;
    property AudioBuffersRetimed: Int64 read FAudioBuffersRetimed write FAudioBuffersRetimed;
    property Discontinuities: Int64 read FDiscontinuities write FDiscontinuities;
    property VideoQueueFrames: Integer read FVideoQueueFrames write FVideoQueueFrames;
    property AudioQueueBuffers: Integer read FAudioQueueBuffers write FAudioQueueBuffers;
    property QueuedBytes: Int64 read FQueuedBytes write FQueuedBytes;
    property PeakQueuedBytes: Int64 read FPeakQueuedBytes write FPeakQueuedBytes;
    property AudioVideoDrift: TMediaTime read FAudioVideoDrift write FAudioVideoDrift;
    property StopLatencyMilliseconds: UInt64 read FStopLatencyMilliseconds write FStopLatencyMilliseconds;
  end;

  TMediaCapturedSample = record
  private
    FSample: IMediaSample;
    FSourceTimestamp: TMediaTime;
    FTimestampAdjusted: Boolean;
    FDiscontinuity: Boolean;
  public
    property Sample: IMediaSample read FSample write FSample;
    property SourceTimestamp: TMediaTime read FSourceTimestamp write FSourceTimestamp;
    property TimestampAdjusted: Boolean read FTimestampAdjusted write FTimestampAdjusted;
    property Discontinuity: Boolean read FDiscontinuity write FDiscontinuity;
  end;

  IMediaCapture = interface
    ['{2164AC0D-971B-4F2D-905C-05D038BB95A3}']
    function GetInfo: TMediaInfo;
    function GetState: TMediaCaptureState;
    function GetStats: TMediaCaptureStats;
    function ReadSample(out ASample: TMediaCapturedSample; AWaitMilliseconds: Cardinal = 1000): TMediaCaptureReadStatus;
    procedure Stop;
    property Info: TMediaInfo read GetInfo;
    property State: TMediaCaptureState read GetState;
    property Stats: TMediaCaptureStats read GetStats;
  end;

  TMediaDevices = class sealed
  public
    class function OpenCapture(const ASettings: TMediaCaptureSettings;
      const AToken: IMediaCancellationToken = nil): IMediaCapture; static;
    class function BackendAvailable(const ABackend: String = 'dshow'): Boolean; static;
    class function ListDevices(const ABackend: String = 'dshow'): TMediaDeviceList; static;
    class function QueryModes(const ADeviceID: String): TMediaDeviceModes; static;
  end;

implementation

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Internal.Devices.DShow,
  TFFmpeg.Media.Internal.Capture;

class function TMediaCaptureSettings.Default: TMediaCaptureSettings;
begin
  Result:=System.Default(TMediaCaptureSettings);
  Result.FPixelFormat:=mpfBGRA32;
  Result.FSampleFormat:=msfS16;
  Result.FSampleRate:=48000;
  Result.FChannels:=2;
  Result.FMaxVideoFrames:=8;
  Result.FMaxAudioBuffers:=32;
  Result.FMaxQueueBytes:=64 * 1024 * 1024;
  Result.FNativeBufferBytes:=32 * 1024 * 1024;
  Result.FProbeBufferBytes:=64 * 1024 * 1024;
  Result.FOperationTimeoutMilliseconds:=5000;
  Result.FMaxClockDriftMilliseconds:=250;
end;

procedure TMediaCaptureSettings.Validate;
begin
  if (FVideoDeviceID = '') AND (FAudioDeviceID = '') then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Open capture', 'Select at least one camera or microphone');
  if ((FVideoDeviceID <> '') AND NOT SameText(Copy(FVideoDeviceID, 1, 12), 'dshow:video:')) OR
    ((FAudioDeviceID <> '') AND NOT SameText(Copy(FAudioDeviceID, 1, 12), 'dshow:audio:')) OR
    (Pos(#0, FVideoDeviceID + FAudioDeviceID + FVideoMode.PinName + FAudioMode.PinName) > 0) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Open capture', 'Use backend-qualified IDs of the requested media kind without NUL');
  if NOT (FVideoMode.Kind IN [mkUnknown, mkVideo]) OR NOT (FAudioMode.Kind IN [mkUnknown, mkAudio]) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Open capture', 'A device mode must match its selected media kind');
  if (FAudioMode.FormatName <> '') AND (FAudioMode.FormatName <> 'pcm_s16le') AND (FAudioMode.FormatName <> 'pcm_u8') then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Open capture', 'Explicit audio device format selection supports PCM U8/S16');
  if (FVideoMode.Width < 0) OR (FVideoMode.Height < 0) OR ((FVideoMode.Width = 0) <> (FVideoMode.Height = 0)) OR
    (Int64(FVideoMode.Width) * FVideoMode.Height > MEDIA_MAX_PIXELS) OR
    (FVideoMode.FrameRate.Known AND (FVideoMode.FrameRate.Value > 240)) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Open capture', 'Video dimensions/rate exceed the capture limits');
  if (FVideoMode.FormatName <> '') AND (FVideoMode.FormatName <> 'bgr24') AND (FVideoMode.FormatName <> 'bgr0') AND
    (FVideoMode.FormatName <> 'bgra') AND (FVideoMode.FormatName <> 'yuyv422') AND (FVideoMode.FormatName <> 'uyvy422') AND
    (FVideoMode.FormatName <> 'nv12') AND (FVideoMode.FormatName <> 'yuv420p') then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Open capture', 'Explicit video mode selection currently supports raw pixel formats');
  if (FAudioMode.SampleRate <> 0) AND ((FAudioMode.SampleRate < 8000) OR (FAudioMode.SampleRate > 192000)) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Open capture', 'Audio device rate must be default or 8-192 kHz');
  if (FAudioMode.Channels < 0) OR (FAudioMode.Channels > 2) OR
    NOT (FAudioMode.BitsPerSample IN [0, 8, 16]) then
    raise EFFmpegMediaError.Create(mecUnsupported, 'Open capture', 'Explicit audio device modes support mono/stereo 8/16-bit PCM');
  if NOT (FPixelFormat IN [mpfRGB24, mpfBGRA32]) OR NOT (FSampleFormat IN [msfS16, msfFloat32]) OR
    (FSampleRate < 8000) OR (FSampleRate > 192000) OR (FChannels < 1) OR (FChannels > 2) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Open capture', 'Decoded samples require RGB/BGRA and 8-192 kHz mono/stereo PCM');
  if NOT (FAudioTiming IN [mcatPreserve, mcatSampleClock]) OR (FAudioTimestampToleranceMilliseconds > 1000) OR
    ((FAudioTiming = mcatPreserve) AND (FAudioTimestampToleranceMilliseconds <> 0)) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Open capture', 'Audio timestamp tolerance requires an explicit sample-clock policy and at most 1000 ms');
  if NOT (FPolicy IN [mcpPreview, mcpRecording]) OR NOT (FAudioOverflow IN [maoFail, maoDropOldest]) OR
    ((FPolicy = mcpRecording) AND (FAudioOverflow <> maoFail)) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Open capture', 'Recording requires failure on audio overflow');
  if (FMaxVideoFrames < 1) OR (FMaxVideoFrames > 256) OR (FMaxAudioBuffers < 1) OR (FMaxAudioBuffers > 4096) OR
    (FMaxQueueBytes < 1) OR (FMaxQueueBytes > MEDIA_MAX_BUFFER_BYTES) OR
    (FProbeBufferBytes < 2048) OR (FProbeBufferBytes > MEDIA_MAX_BUFFER_BYTES) OR
    (FNativeBufferBytes < 1024 * 1024) OR (FNativeBufferBytes > MEDIA_MAX_BUFFER_BYTES) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Open capture', 'Queue/native buffer bounds are invalid');
  if (FAudioBufferMilliseconds < 0) OR (FAudioBufferMilliseconds > 1000) OR
    (FOperationTimeoutMilliseconds = 0) OR (FMaxClockDriftMilliseconds < 50) OR (FMaxClockDriftMilliseconds > 60000) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Open capture', 'A finite operation deadline and valid latency/drift limits are required');
end;

class function TMediaDevices.OpenCapture(const ASettings: TMediaCaptureSettings; const AToken: IMediaCancellationToken): IMediaCapture;
begin
  Result:=OpenDeviceCapture(ASettings, AToken);
end;

function TMediaDeviceList.GetDevices: TMediaDeviceInfos;
begin
  Result:=Copy(FDevices);
end;

procedure TMediaDeviceList.SetDevices(const AValue: TMediaDeviceInfos);
begin
  FDevices:=Copy(AValue);
end;

function TMediaDeviceModes.GetModes: TMediaDeviceModeArray;
begin
  Result:=Copy(FModes);
end;

procedure TMediaDeviceModes.SetModes(const AValue: TMediaDeviceModeArray);
begin
  FModes:=Copy(AValue);
end;

class function TMediaDevices.BackendAvailable(const ABackend: String): Boolean;
begin
  Result:=DShowBackendAvailable(ABackend);
end;

class function TMediaDevices.ListDevices(const ABackend: String): TMediaDeviceList;
begin
  Result:=DShowListDevices(ABackend);
end;

class function TMediaDevices.QueryModes(const ADeviceID: String): TMediaDeviceModes;
begin
  Result:=DShowQueryModes(ADeviceID);
end;

end.
