unit TFFmpeg.Media.Types;

{$IFDEF FPC}
{$mode delphi}
{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils;
{$ELSE}
  System.SysUtils;
{$ENDIF}

const
  MEDIA_MAX_BUFFER_BYTES = 256 * 1024 * 1024;
  MEDIA_MAX_PIXELS = 64000000;
  MEDIA_MAX_CHANNELS = 32;

type
  TMediaKind = (mkUnknown, mkVideo, mkAudio, mkSubtitle, mkAttachment, mkData);
  TMediaPixelFormat = (mpfUnknown, mpfRGB24, mpfBGRA32);
  TMediaSampleFormat = (msfUnknown, msfS16, msfFloat32);
  TMediaReadStatus = (mrsSample, mrsEndOfInput, mrsTimedOut, mrsCancelled);
  TMediaFit = (mfFit, mfFill, mfStretch);
  TMediaOptionScope = (mosDemuxer, mosDecoder, mosEncoder, mosMuxer, mosDevice);
  TMediaStrings = Array of String;

  TMediaDisplayTransform = record
  private
    FKnown: Boolean;
    FValues: Array[0..8] of Double;
    function GetValue(AIndex: Integer): Double;
  public
    class function Create(const AValues: Array of Double): TMediaDisplayTransform; static;
    property Known: Boolean read FKnown;
    property Values[AIndex: Integer]: Double read GetValue;
  end;

  TMediaColorInfo = record
  private
    FMatrix: String;
    FRange: String;
    FPrimaries: String;
    FTransfer: String;
    FChromaLocation: String;
  public
    property Matrix: String read FMatrix write FMatrix;
    property RangeName: String read FRange write FRange;
    property Primaries: String read FPrimaries write FPrimaries;
    property Transfer: String read FTransfer write FTransfer;
    property ChromaLocation: String read FChromaLocation write FChromaLocation;
  end;

  TMediaRate = record
  private
    FNumerator: Integer;
    FDenominator: Integer;
    function GetKnown: Boolean;
    function GetValue: Double;
  public
    class function Unknown: TMediaRate; static;
    class function Create(ANumerator, ADenominator: Integer): TMediaRate; static;
    function Compare(const AOther: TMediaRate): Integer;
    property Known: Boolean read GetKnown;
    property Numerator: Integer read FNumerator;
    property Denominator: Integer read FDenominator;
    property Value: Double read GetValue;
  end;

  TMediaTime = record
  private
    FMicroseconds: Int64;
    FValid: Boolean;
    FEstimated: Boolean;
    function GetMicroseconds: Int64;
    function GetSeconds: Double;
  public
    class function Unknown: TMediaTime; static;
    class function FromMicroseconds(AValue: Int64; AEstimated: Boolean = False): TMediaTime; static;
    class function FromSeconds(AValue: Double): TMediaTime; static;
    class function FromTicks(ATicks: Int64; const ATimeBase: TMediaRate; AEstimated: Boolean = False): TMediaTime; static;
    function ToTicks(const ATimeBase: TMediaRate): Int64;
    function Add(const AOther: TMediaTime): TMediaTime;
    function Subtract(const AOther: TMediaTime): TMediaTime;
    function Compare(const AOther: TMediaTime): Integer;
    property Valid: Boolean read FValid;
    property Estimated: Boolean read FEstimated;
    property Microseconds: Int64 read GetMicroseconds;
    property Seconds: Double read GetSeconds;
  end;

  TMediaOptionalInt64 = record
  private
    FValue: Int64;
    FKnown: Boolean;
    FEstimated: Boolean;
    function GetValue: Int64;
  public
    class function Unknown: TMediaOptionalInt64; static;
    class function Create(AValue: Int64; AEstimated: Boolean = False): TMediaOptionalInt64; static;
    property Value: Int64 read GetValue;
    property Known: Boolean read FKnown;
    property Estimated: Boolean read FEstimated;
  end;

  TMediaChannelLayout = record
  private
    FChannels: Integer;
    FName: String;
    FChannelNames: TMediaStrings;
    function GetChannelNames: TMediaStrings;
  public
    class function Mono: TMediaChannelLayout; static;
    class function Stereo: TMediaChannelLayout; static;
    class function Discrete(AChannels: Integer): TMediaChannelLayout; static;
    class function Described(AChannels: Integer; const AName: String; const AChannelNames: TMediaStrings): TMediaChannelLayout; static;
    procedure Validate;
    property Channels: Integer read FChannels;
    property Name: String read FName;
    property ChannelNames: TMediaStrings read GetChannelNames;
  end;

  TMediaMetadataEntry = record
  private
    FKey: String;
    FValue: String;
  public
    class function Create(const AKey, AValue: String): TMediaMetadataEntry; static;
    property Key: String read FKey;
    property Value: String read FValue;
  end;
  TMediaMetadata = Array of TMediaMetadataEntry;

  TMediaOption = record
  private
    FScope: TMediaOptionScope;
    FKey: String;
    FValue: String;
  public
    class function Create(AScope: TMediaOptionScope; const AKey, AValue: String): TMediaOption; static;
    property Scope: TMediaOptionScope read FScope;
    property Key: String read FKey;
    property Value: String read FValue;
  end;
  TMediaOptions = Array of TMediaOption;

  TMediaInputSettings = record
  private
    FMaxStreams: Integer;
    FMaxProbeBytes: Int64;
    FTimeoutMilliseconds: Cardinal;
    FOptions: TMediaOptions;
    function GetOptions: TMediaOptions;
    procedure SetOptions(const AValue: TMediaOptions);
  public
    class function Default: TMediaInputSettings; static;
    procedure Validate;
    property MaxStreams: Integer read FMaxStreams write FMaxStreams;
    property MaxProbeBytes: Int64 read FMaxProbeBytes write FMaxProbeBytes;
    property TimeoutMilliseconds: Cardinal read FTimeoutMilliseconds write FTimeoutMilliseconds;
    property Options: TMediaOptions read GetOptions write SetOptions;
  end;

  TMediaStreamInfo = record
  private
    FIndex: Integer;
    FKind: TMediaKind;
    FCodecName: String;
    FPixelFormatName: String;
    FSampleFormatName: String;
    FBitsPerSample: Integer;
    FProfile: String;
    FLanguage: String;
    FDecoderAvailable: Boolean;
    FAttachedArt: Boolean;
    FDefaultTrack: Boolean;
    FDuration: TMediaTime;
    FStartTime: TMediaTime;
    FTimeBase: TMediaRate;
    FFrameRate: TMediaRate;
    FPixelAspect: TMediaRate;
    FWidth: Integer;
    FHeight: Integer;
    FSampleRate: Integer;
    FChannelLayout: TMediaChannelLayout;
    FBitRate: TMediaOptionalInt64;
    FFrameCount: TMediaOptionalInt64;
    FDisplayAspect: TMediaRate;
    FDisplayTransform: TMediaDisplayTransform;
    FRotationDegrees: Double;
    FRotationKnown: Boolean;
    FColor: TMediaColorInfo;
    FDispositions: TMediaStrings;
    FMetadata: TMediaMetadata;
    function GetDispositions: TMediaStrings;
    procedure SetDispositions(const AValue: TMediaStrings);
    function GetMetadata: TMediaMetadata;
    procedure SetMetadata(const AValue: TMediaMetadata);
  public
    property Index: Integer read FIndex write FIndex;
    property Kind: TMediaKind read FKind write FKind;
    property CodecName: String read FCodecName write FCodecName;
    property PixelFormatName: String read FPixelFormatName write FPixelFormatName;
    property SampleFormatName: String read FSampleFormatName write FSampleFormatName;
    property BitsPerSample: Integer read FBitsPerSample write FBitsPerSample;
    property Profile: String read FProfile write FProfile;
    property Language: String read FLanguage write FLanguage;
    property DecoderAvailable: Boolean read FDecoderAvailable write FDecoderAvailable;
    property AttachedArt: Boolean read FAttachedArt write FAttachedArt;
    property DefaultTrack: Boolean read FDefaultTrack write FDefaultTrack;
    property Duration: TMediaTime read FDuration write FDuration;
    property StartTime: TMediaTime read FStartTime write FStartTime;
    property TimeBase: TMediaRate read FTimeBase write FTimeBase;
    property FrameRate: TMediaRate read FFrameRate write FFrameRate;
    property PixelAspect: TMediaRate read FPixelAspect write FPixelAspect;
    property Width: Integer read FWidth write FWidth;
    property Height: Integer read FHeight write FHeight;
    property SampleRate: Integer read FSampleRate write FSampleRate;
    property ChannelLayout: TMediaChannelLayout read FChannelLayout write FChannelLayout;
    property BitRate: TMediaOptionalInt64 read FBitRate write FBitRate;
    property FrameCount: TMediaOptionalInt64 read FFrameCount write FFrameCount;
    property DisplayAspect: TMediaRate read FDisplayAspect write FDisplayAspect;
    property DisplayTransform: TMediaDisplayTransform read FDisplayTransform write FDisplayTransform;
    property RotationDegrees: Double read FRotationDegrees write FRotationDegrees;
    property RotationKnown: Boolean read FRotationKnown write FRotationKnown;
    property Color: TMediaColorInfo read FColor write FColor;
    property Dispositions: TMediaStrings read GetDispositions write SetDispositions;
    property Metadata: TMediaMetadata read GetMetadata write SetMetadata;
  end;
  TMediaStreams = Array of TMediaStreamInfo;

  TMediaInfo = record
  private
    FFormatName: String;
    FFormatDescription: String;
    FDuration: TMediaTime;
    FStartTime: TMediaTime;
    FBitRate: TMediaOptionalInt64;
    FSeekable: Boolean;
    FMetadata: TMediaMetadata;
    FStreams: TMediaStreams;
    function GetMetadata: TMediaMetadata;
    procedure SetMetadata(const AValue: TMediaMetadata);
    function GetStreams: TMediaStreams;
    procedure SetStreams(const AValue: TMediaStreams);
  public
    property FormatName: String read FFormatName write FFormatName;
    property FormatDescription: String read FFormatDescription write FFormatDescription;
    property Duration: TMediaTime read FDuration write FDuration;
    property StartTime: TMediaTime read FStartTime write FStartTime;
    property BitRate: TMediaOptionalInt64 read FBitRate write FBitRate;
    property Seekable: Boolean read FSeekable write FSeekable;
    property Metadata: TMediaMetadata read GetMetadata write SetMetadata;
    property Streams: TMediaStreams read GetStreams write SetStreams;
  end;

implementation

uses
{$IFDEF FPC}
  Math,
{$ELSE}
  System.Math,
{$ENDIF}
  TFFmpeg.Media.Errors;

procedure InvalidValue(const AMessage: String);
begin
  raise EFFmpegMediaError.Create(mecInvalidSettings, 'Media value', AMessage);
end;

class function TMediaDisplayTransform.Create(const AValues: Array of Double): TMediaDisplayTransform;
var
  I: Integer;
begin
  Result:=Default(TMediaDisplayTransform);
  if Length(AValues) <> 9 then
    InvalidValue('A display transform requires nine coefficients');
  for I:=0 to 8 do
  begin
    if IsNan(AValues[I]) OR IsInfinite(AValues[I]) then
      InvalidValue('Display transform must be finite');
    Result.FValues[I]:=AValues[I];
  end;
  Result.FKnown:=True;
end;

function TMediaDisplayTransform.GetValue(AIndex: Integer): Double;
begin
  Result:=0;
  if NOT FKnown OR (AIndex < 0) OR (AIndex > 8) then
    InvalidValue('Unknown display transform or invalid coefficient index');
  Result:=FValues[AIndex];
end;

// Bitwise multiply/divide avoids overflowing an intermediate product when the
// final quotient fits Int64. All inputs except the signed value are positive.
function CheckedScale(AValue: Int64; AMultiplier, ADivisor: UInt64): Int64;
var
  Magnitude, Quotient, Remainder, Base, Fraction, BitValue: UInt64;
  I: Integer;
  Negative: Boolean;
begin
  Result:=0;
  if ADivisor = 0 then
    InvalidValue('Division by zero');

  Negative:=AValue < 0;
  if Negative then
    Magnitude:=UInt64(-(AValue + 1)) + 1
  else
    Magnitude:=UInt64(AValue);

  Base:=AMultiplier DIV ADivisor;
  Fraction:=AMultiplier MOD ADivisor;
  Quotient:=0;
  Remainder:=0;
  for I:=63 downto 0 do
  begin
    if Quotient > High(UInt64) DIV 2 then
      InvalidValue('Time conversion overflow');
    Quotient:=Quotient * 2;

    // Remainder * 2, reduced before addition, cannot overflow.
    BitValue:=0;
    if Remainder >= ADivisor - Remainder then
    begin
      Remainder:=Remainder - (ADivisor - Remainder);
      BitValue:=1;
    end else
      Remainder:=Remainder * 2;

    if ((Magnitude SHR I) AND 1) <> 0 then
    begin
      if Base > High(UInt64) - BitValue then
        InvalidValue('Time conversion overflow');
      BitValue:=BitValue + Base;
      if Remainder >= ADivisor - Fraction then
      begin
        Remainder:=Remainder - (ADivisor - Fraction);
        if BitValue = High(UInt64) then
          InvalidValue('Time conversion overflow');
        Inc(BitValue);
      end else
        Remainder:=Remainder + Fraction;
    end;

    if Quotient > High(UInt64) - BitValue then
      InvalidValue('Time conversion overflow');
    Quotient:=Quotient + BitValue;
  end;

  if Negative then
  begin
    if Quotient > UInt64(High(Int64)) + 1 then
      InvalidValue('Time conversion overflow');
    if Quotient = UInt64(High(Int64)) + 1 then
      Result:=Low(Int64)
    else
      Result:=-Int64(Quotient);
  end else
  begin
    if Quotient > UInt64(High(Int64)) then
      InvalidValue('Time conversion overflow');
    Result:=Int64(Quotient);
  end;
end;

class function TMediaRate.Unknown: TMediaRate;
begin
  Result:=Default(TMediaRate);
end;

class function TMediaRate.Create(ANumerator, ADenominator: Integer): TMediaRate;
begin
  Result:=Unknown;
  if (ANumerator <= 0) OR (ADenominator <= 0) then
    InvalidValue('A rational rate requires positive numerator and denominator');
  Result.FNumerator:=ANumerator;
  Result.FDenominator:=ADenominator;
end;

function TMediaRate.GetKnown: Boolean;
begin
  Result:=(FNumerator > 0) AND (FDenominator > 0);
end;

function TMediaRate.GetValue: Double;
begin
  Result:=0;
  if NOT Known then
    InvalidValue('Unknown rational rate');
  Result:=FNumerator / FDenominator;
end;

function TMediaRate.Compare(const AOther: TMediaRate): Integer;
var
  LeftValue, RightValue: Int64;
begin
  Result:=0;
  if NOT Known OR NOT AOther.Known then
    InvalidValue('Cannot compare unknown rational rates');
  LeftValue:=Int64(FNumerator) * AOther.FDenominator;
  RightValue:=Int64(AOther.FNumerator) * FDenominator;
  if LeftValue < RightValue then
    Result:=-1
  else
  if LeftValue > RightValue then
    Result:=1;
end;

class function TMediaTime.Unknown: TMediaTime;
begin
  Result:=Default(TMediaTime);
end;

class function TMediaTime.FromMicroseconds(AValue: Int64; AEstimated: Boolean): TMediaTime;
begin
  Result:=Unknown;
  Result.FMicroseconds:=AValue;
  Result.FValid:=True;
  Result.FEstimated:=AEstimated;
end;

class function TMediaTime.FromSeconds(AValue: Double): TMediaTime;
var
  Scaled: Double;
begin
  Result:=Unknown;
  Scaled:=AValue * 1000000;
  if IsNan(Scaled) OR IsInfinite(Scaled) then
    InvalidValue('Time must be finite');
  if (Scaled >= 9223372036854775808.0) OR (Scaled < -9223372036854775808.0) then
    InvalidValue('Time conversion overflow');
  Result:=FromMicroseconds(Round(Scaled));
end;

class function TMediaTime.FromTicks(ATicks: Int64; const ATimeBase: TMediaRate; AEstimated: Boolean): TMediaTime;
begin
  Result:=Unknown;
  if NOT ATimeBase.Known then
    InvalidValue('Unknown time base');
  Result:=FromMicroseconds(CheckedScale(ATicks, UInt64(ATimeBase.Numerator) * 1000000, ATimeBase.Denominator), AEstimated);
end;

function TMediaTime.ToTicks(const ATimeBase: TMediaRate): Int64;
begin
  Result:=0;
  if NOT ATimeBase.Known then
    InvalidValue('Unknown time base');
  Result:=CheckedScale(Microseconds, ATimeBase.Denominator, UInt64(ATimeBase.Numerator) * 1000000);
end;

function TMediaTime.GetMicroseconds: Int64;
begin
  Result:=0;
  if NOT FValid then
    InvalidValue('Unknown time');
  Result:=FMicroseconds;
end;

function TMediaTime.GetSeconds: Double;
begin
  Result:=Microseconds / 1000000;
end;

function TMediaTime.Add(const AOther: TMediaTime): TMediaTime;
var
  LeftValue, RightValue: Int64;
begin
  Result:=Unknown;
  LeftValue:=Microseconds;
  RightValue:=AOther.Microseconds;
  if ((RightValue > 0) AND (LeftValue > High(Int64) - RightValue)) OR
    ((RightValue < 0) AND (LeftValue < Low(Int64) - RightValue)) then
    InvalidValue('Time addition overflow');
  Result:=FromMicroseconds(LeftValue + RightValue, FEstimated OR AOther.FEstimated);
end;

function TMediaTime.Subtract(const AOther: TMediaTime): TMediaTime;
var
  LeftValue, RightValue: Int64;
begin
  Result:=Unknown;
  LeftValue:=Microseconds;
  RightValue:=AOther.Microseconds;
  if ((RightValue < 0) AND (LeftValue > High(Int64) + RightValue)) OR
    ((RightValue > 0) AND (LeftValue < Low(Int64) + RightValue)) then
    InvalidValue('Time subtraction overflow');
  Result:=FromMicroseconds(LeftValue - RightValue, FEstimated OR AOther.FEstimated);
end;

function TMediaTime.Compare(const AOther: TMediaTime): Integer;
begin
  Result:=0;
  if Microseconds < AOther.Microseconds then
    Result:=-1
  else
  if Microseconds > AOther.Microseconds then
    Result:=1;
end;

class function TMediaOptionalInt64.Unknown: TMediaOptionalInt64;
begin
  Result:=Default(TMediaOptionalInt64);
end;

class function TMediaOptionalInt64.Create(AValue: Int64; AEstimated: Boolean): TMediaOptionalInt64;
begin
  Result:=Unknown;
  Result.FValue:=AValue;
  Result.FKnown:=True;
  Result.FEstimated:=AEstimated;
end;

function TMediaOptionalInt64.GetValue: Int64;
begin
  Result:=0;
  if NOT FKnown then
    InvalidValue('Unknown optional value');
  Result:=FValue;
end;

class function TMediaChannelLayout.Mono: TMediaChannelLayout;
begin
  Result:=Discrete(1);
  Result.FName:='mono';
  SetLength(Result.FChannelNames, 1);
  Result.FChannelNames[0]:='FC';
end;

class function TMediaChannelLayout.Stereo: TMediaChannelLayout;
begin
  Result:=Discrete(2);
  Result.FName:='stereo';
  SetLength(Result.FChannelNames, 2);
  Result.FChannelNames[0]:='FL';
  Result.FChannelNames[1]:='FR';
end;

class function TMediaChannelLayout.Described(AChannels: Integer; const AName: String;
  const AChannelNames: TMediaStrings): TMediaChannelLayout;
begin
  Result:=Default(TMediaChannelLayout);
  if AChannels < 1 then
    InvalidValue('A described layout requires a positive channel count');
  if (Length(AChannelNames) <> 0) AND (Length(AChannelNames) <> AChannels) then
    InvalidValue('Channel names must describe every channel or be empty');
  // Metadata may describe more channels than this pipeline can decode/convert.
  // Validate is applied when a layout is used for actual PCM, not inspection.
  Result.FChannels:=AChannels;
  Result.FName:=AName;
  Result.FChannelNames:=Copy(AChannelNames);
end;

function TMediaChannelLayout.GetChannelNames: TMediaStrings;
begin
  Result:=Copy(FChannelNames);
end;

class function TMediaChannelLayout.Discrete(AChannels: Integer): TMediaChannelLayout;
begin
  Result:=Default(TMediaChannelLayout);
  Result.FChannels:=AChannels;
  Result.FName:='discrete';
  Result.Validate;
end;

procedure TMediaChannelLayout.Validate;
begin
  if (FChannels < 1) OR (FChannels > MEDIA_MAX_CHANNELS) then
    InvalidValue('Channel count must be between 1 and 32');
end;

class function TMediaMetadataEntry.Create(const AKey, AValue: String): TMediaMetadataEntry;
begin
  Result:=Default(TMediaMetadataEntry);
  Result.FKey:=AKey;
  Result.FValue:=AValue;
end;

class function TMediaOption.Create(AScope: TMediaOptionScope; const AKey, AValue: String): TMediaOption;
begin
  Result:=Default(TMediaOption);
  if (AKey = '') OR (Pos(#0, AKey) > 0) OR (Pos(#0, AValue) > 0) then
    InvalidValue('Options require a nonempty key and cannot contain NUL');
  Result.FScope:=AScope;
  Result.FKey:=AKey;
  Result.FValue:=AValue;
end;

class function TMediaInputSettings.Default: TMediaInputSettings;
begin
  Result:=System.Default(TMediaInputSettings);
  Result.FMaxStreams:=256;
  Result.FMaxProbeBytes:=5000000;
end;

procedure TMediaInputSettings.Validate;
var
  I, J: Integer;
begin
  if (FMaxStreams < 1) OR (FMaxStreams > 256) then
    InvalidValue('MaxStreams must be between 1 and 256; use Default settings');
  if (FMaxProbeBytes < 2048) OR (FMaxProbeBytes > MEDIA_MAX_BUFFER_BYTES) then
    InvalidValue('MaxProbeBytes must be between 2048 and 256 MiB');
  for I:=0 to Length(FOptions) - 1 do
  begin
    if (FOptions[I].Key = '') OR (Pos(#0, FOptions[I].Key) > 0) OR (Pos(#0, FOptions[I].Value) > 0) then
      InvalidValue('Invalid advanced option');
    if FOptions[I].Scope <> mosDemuxer then
      InvalidValue('Input settings accept only demuxer options');
    if SameText(FOptions[I].Key, 'protocol_whitelist') OR SameText(FOptions[I].Key, 'max_streams') OR
      SameText(FOptions[I].Key, 'probesize') then
      InvalidValue('Advanced option conflicts with input policy or typed settings');
    for J:=0 to I - 1 do
      if SameText(FOptions[I].Key, FOptions[J].Key) then
        InvalidValue('Duplicate advanced option');
  end;
end;

function TMediaInputSettings.GetOptions: TMediaOptions;
begin
  Result:=Copy(FOptions);
end;

procedure TMediaInputSettings.SetOptions(const AValue: TMediaOptions);
begin
  FOptions:=Copy(AValue);
end;

function TMediaStreamInfo.GetMetadata: TMediaMetadata;
begin
  Result:=Copy(FMetadata);
end;

function TMediaStreamInfo.GetDispositions: TMediaStrings;
begin
  Result:=Copy(FDispositions);
end;

procedure TMediaStreamInfo.SetDispositions(const AValue: TMediaStrings);
begin
  FDispositions:=Copy(AValue);
end;

procedure TMediaStreamInfo.SetMetadata(const AValue: TMediaMetadata);
begin
  FMetadata:=Copy(AValue);
end;

function TMediaInfo.GetMetadata: TMediaMetadata;
begin
  Result:=Copy(FMetadata);
end;

procedure TMediaInfo.SetMetadata(const AValue: TMediaMetadata);
begin
  FMetadata:=Copy(AValue);
end;

function TMediaInfo.GetStreams: TMediaStreams;
begin
  Result:=Copy(FStreams);
end;

procedure TMediaInfo.SetStreams(const AValue: TMediaStreams);
begin
  FStreams:=Copy(AValue);
end;

end.
