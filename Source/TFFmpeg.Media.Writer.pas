unit TFFmpeg.Media.Writer;

interface

uses
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Images;

type
  TMediaWriterState = (mwsConfiguring, mwsWriting, mwsFinished, mwsAborted, mwsFailed);
  TMediaWriterTiming = (mwtGenerate, mwtPreserve);

  TMediaVideoEncoding = record
  private
    FEnabled: Boolean;
    FEncoderName: String;
    FWidth: Integer;
    FHeight: Integer;
    FFrameRate: TMediaRate;
    FBitRate: Int64;
    FOptions: TMediaOptions;
    function GetOptions: TMediaOptions;
    procedure SetOptions(const AValue: TMediaOptions);
  public
    class function H264(AWidth, AHeight: Integer; const AFrameRate: TMediaRate): TMediaVideoEncoding; static;
    property Enabled: Boolean read FEnabled write FEnabled;
    property EncoderName: String read FEncoderName write FEncoderName;
    property Width: Integer read FWidth write FWidth;
    property Height: Integer read FHeight write FHeight;
    property FrameRate: TMediaRate read FFrameRate write FFrameRate;
    property BitRate: Int64 read FBitRate write FBitRate;
    property Options: TMediaOptions read GetOptions write SetOptions;
  end;

  TMediaAudioEncoding = record
  private
    FEnabled: Boolean;
    FEncoderName: String;
    FSampleRate: Integer;
    FChannels: Integer;
    FBitRate: Int64;
    FOptions: TMediaOptions;
    function GetOptions: TMediaOptions;
    procedure SetOptions(const AValue: TMediaOptions);
  public
    class function PCM(ASampleRate, AChannels: Integer): TMediaAudioEncoding; static;
    class function Opus(AChannels: Integer = 2; ABitRate: Int64 = 128000): TMediaAudioEncoding; static;
    class function AAC(ASampleRate: Integer = 48000; AChannels: Integer = 2; ABitRate: Int64 = 128000): TMediaAudioEncoding; static;
    property Enabled: Boolean read FEnabled write FEnabled;
    property EncoderName: String read FEncoderName write FEncoderName;
    property SampleRate: Integer read FSampleRate write FSampleRate;
    property Channels: Integer read FChannels write FChannels;
    property BitRate: Int64 read FBitRate write FBitRate;
    property Options: TMediaOptions read GetOptions write SetOptions;
  end;

  TMediaWriterSettings = record
  private
    FMuxerName: String;
    FVideo: TMediaVideoEncoding;
    FAudio: TMediaAudioEncoding;
    FOverwrite: Boolean;
    FTimeoutMilliseconds: Cardinal;
    FOptions: TMediaOptions;
    FMetadata: TMediaMetadata;
    FTiming: TMediaWriterTiming;
    function GetOptions: TMediaOptions;
    procedure SetOptions(const AValue: TMediaOptions);
    function GetMetadata: TMediaMetadata;
    procedure SetMetadata(const AValue: TMediaMetadata);
  public
    class function H264MP4(AWidth, AHeight: Integer; const AFrameRate: TMediaRate): TMediaWriterSettings; static;
    class function PCMWave(ASampleRate, AChannels: Integer): TMediaWriterSettings; static;
    class function OggOpus(AChannels: Integer = 2; ABitRate: Int64 = 128000): TMediaWriterSettings; static;
    procedure Validate;
    property MuxerName: String read FMuxerName write FMuxerName;
    property Video: TMediaVideoEncoding read FVideo write FVideo;
    property Audio: TMediaAudioEncoding read FAudio write FAudio;
    property Overwrite: Boolean read FOverwrite write FOverwrite;
    property TimeoutMilliseconds: Cardinal read FTimeoutMilliseconds write FTimeoutMilliseconds;
    property Options: TMediaOptions read GetOptions write SetOptions;
    property Metadata: TMediaMetadata read GetMetadata write SetMetadata;
    property Timing: TMediaWriterTiming read FTiming write FTiming;
  end;

  // Thread-confined. Submission borrows immutable samples only for the call.
  // Generated timing starts at zero; preservation requires explicit presentation times.
  IMediaWriter = interface
    ['{96D8C656-057A-4999-B4DE-6E6B803C3777}']
    function GetState: TMediaWriterState;
    function GetVideoEncoderName: String;
    function GetAudioEncoderName: String;
    function GetVideoCodecName: String;
    function GetAudioCodecName: String;
    procedure Start;
    procedure SubmitVideo(const AFrame: IMediaVideoFrame);
    procedure SubmitAudio(const ABuffer: IMediaAudioBuffer);
    procedure Finish;
    procedure Abort;
    procedure SubmitVideoAt(const AFrame: IMediaVideoFrame; const ATimestamp, ADuration: TMediaTime);
    property State: TMediaWriterState read GetState;
    property VideoEncoderName: String read GetVideoEncoderName;
    property AudioEncoderName: String read GetAudioEncoderName;
    property VideoCodecName: String read GetVideoCodecName;
    property AudioCodecName: String read GetAudioCodecName;
  end;

  TMediaWriter = class sealed
  public
    // Preflights all enabled encoders and reserves a sibling; header waits for Start/submission.
    class function OpenFile(const AFilename: String; const ASettings: TMediaWriterSettings;
      const AToken: IMediaCancellationToken = nil): IMediaWriter; static;
  end;

  TMediaSequenceImage = record
  private
    FFrame: IMediaVideoFrame;
    FFilename: String;
    FDuration: TMediaTime;
  public
    class function FromFrame(const AFrame: IMediaVideoFrame; const ADuration: TMediaTime): TMediaSequenceImage; static;
    class function FromFile(const AFilename: String; const ADuration: TMediaTime): TMediaSequenceImage; static;
    property Frame: IMediaVideoFrame read FFrame;
    property Filename: String read FFilename;
    property Duration: TMediaTime read FDuration;
  end;

  TMediaImageSequenceSettings = record
  private
    FWriter: TMediaWriterSettings;
    FFit: TMediaFit;
    FBackgroundRGB: Cardinal;
  public
    class function H264MP4(AWidth, AHeight: Integer; const AFrameRate: TMediaRate): TMediaImageSequenceSettings; static;
    property Writer: TMediaWriterSettings read FWriter write FWriter;
    property Fit: TMediaFit read FFit write FFit;
    property BackgroundRGB: Cardinal read FBackgroundRGB write FBackgroundRGB;
  end;

  TMediaImageSequenceResult = record
  private
    FFrameCount: Int64;
    FRequestedDuration: TMediaTime;
    FEncodedDuration: TMediaTime;
    FEncoderName: String;
  public
    property FrameCount: Int64 read FFrameCount;
    property RequestedDuration: TMediaTime read FRequestedDuration;
    property EncodedDuration: TMediaTime read FEncodedDuration;
    property EncoderName: String read FEncoderName;
  end;

  TMediaImageSequence = class sealed
  public
    // Floor cumulative duration to rational frame boundaries. A short item may
    // receive zero frames; total error stays below one frame, without item drift.
    class function WriteFile(const AFilename: String; const AImages: Array of TMediaSequenceImage;
      const ASettings: TMediaImageSequenceSettings; const AToken: IMediaCancellationToken = nil): TMediaImageSequenceResult; static;
  end;

implementation

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Internal.Writer;

procedure ValidateName(const AName, ADescription: String);
begin
  if (AName = '') OR (Pos(#0, AName) > 0) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Writer settings', ADescription + ' requires an explicit name without NUL');
end;

procedure ValidateOptions(const AOptions: TMediaOptions; AScope: TMediaOptionScope);
var
  I, J: Integer;
begin
  for I:=0 to Length(AOptions) - 1 do
  begin
    ValidateName(AOptions[I].Key, 'Option');
    if (AOptions[I].Scope <> AScope) OR (Pos(#0, AOptions[I].Value) > 0) then
      raise EFFmpegMediaError.Create(mecInvalidSettings, 'Writer settings', 'Invalid option scope or embedded NUL');
    for J:=0 to I - 1 do
      if AOptions[J].Key = AOptions[I].Key then
        raise EFFmpegMediaError.Create(mecInvalidSettings, 'Writer settings', 'Duplicate option: ' + AOptions[I].Key);
    if (AScope = mosEncoder) AND ((AOptions[I].Key = 'b') OR (AOptions[I].Key = 'ab') OR (AOptions[I].Key = 'ar') OR (AOptions[I].Key = 'ac') OR
      (AOptions[I].Key = 'r') OR (AOptions[I].Key = 's') OR (AOptions[I].Key = 'pix_fmt') OR (AOptions[I].Key = 'sample_fmt') OR
      (AOptions[I].Key = 'time_base') OR (AOptions[I].Key = 'channel_layout') OR (AOptions[I].Key = 'ch_layout') OR
      (AOptions[I].Key = 'pixel_format') OR (AOptions[I].Key = 'video_size') OR (AOptions[I].Key = 'flags')) then
      raise EFFmpegMediaError.Create(mecInvalidSettings, 'Writer settings', 'Option conflicts with typed settings: ' + AOptions[I].Key);
  end;
end;

class function TMediaVideoEncoding.H264(AWidth, AHeight: Integer; const AFrameRate: TMediaRate): TMediaVideoEncoding;
begin
  Result:=Default(TMediaVideoEncoding);
  Result.FEnabled:=True;
  Result.FEncoderName:='libx264';
  Result.FWidth:=AWidth;
  Result.FHeight:=AHeight;
  Result.FFrameRate:=AFrameRate;
  Result.FBitRate:=2000000;
end;

function TMediaVideoEncoding.GetOptions: TMediaOptions;
begin
  Result:=Copy(FOptions);
end;

procedure TMediaVideoEncoding.SetOptions(const AValue: TMediaOptions);
begin
  FOptions:=Copy(AValue);
end;

class function TMediaAudioEncoding.PCM(ASampleRate, AChannels: Integer): TMediaAudioEncoding;
begin
  Result:=Default(TMediaAudioEncoding);
  Result.FEnabled:=True;
  Result.FEncoderName:='pcm_s16le';
  Result.FSampleRate:=ASampleRate;
  Result.FChannels:=AChannels;
end;

class function TMediaAudioEncoding.Opus(AChannels: Integer; ABitRate: Int64): TMediaAudioEncoding;
begin
  Result:=PCM(48000, AChannels);
  Result.FEncoderName:='libopus';
  Result.FBitRate:=ABitRate;
end;

class function TMediaAudioEncoding.AAC(ASampleRate, AChannels: Integer; ABitRate: Int64): TMediaAudioEncoding;
begin
  Result:=PCM(ASampleRate, AChannels);
  Result.FEncoderName:='aac';
  Result.FBitRate:=ABitRate;
end;

function TMediaAudioEncoding.GetOptions: TMediaOptions;
begin
  Result:=Copy(FOptions);
end;

procedure TMediaAudioEncoding.SetOptions(const AValue: TMediaOptions);
begin
  FOptions:=Copy(AValue);
end;

class function TMediaWriterSettings.H264MP4(AWidth, AHeight: Integer; const AFrameRate: TMediaRate): TMediaWriterSettings;
begin
  Result:=Default(TMediaWriterSettings);
  Result.FMuxerName:='mp4';
  Result.FVideo:=TMediaVideoEncoding.H264(AWidth, AHeight, AFrameRate);
end;

class function TMediaWriterSettings.PCMWave(ASampleRate, AChannels: Integer): TMediaWriterSettings;
begin
  Result:=Default(TMediaWriterSettings);
  Result.FMuxerName:='wav';
  Result.FAudio:=TMediaAudioEncoding.PCM(ASampleRate, AChannels);
end;

class function TMediaWriterSettings.OggOpus(AChannels: Integer; ABitRate: Int64): TMediaWriterSettings;
begin
  Result:=Default(TMediaWriterSettings);
  // FFmpeg's opus muxer is the dedicated Ogg/Opus container writer. Its codec
  // support is queryable before IO, unlike the generic ogg muxer's extra codecs.
  Result.FMuxerName:='opus';
  Result.FAudio:=TMediaAudioEncoding.Opus(AChannels, ABitRate);
end;

function TMediaWriterSettings.GetOptions: TMediaOptions;
begin
  Result:=Copy(FOptions);
end;

procedure TMediaWriterSettings.SetOptions(const AValue: TMediaOptions);
begin
  FOptions:=Copy(AValue);
end;

function TMediaWriterSettings.GetMetadata: TMediaMetadata;
begin
  Result:=Copy(FMetadata);
end;

procedure TMediaWriterSettings.SetMetadata(const AValue: TMediaMetadata);
begin
  FMetadata:=Copy(AValue);
end;

procedure TMediaWriterSettings.Validate;
var
  I, J: Integer;
begin
  ValidateName(FMuxerName, 'Muxer');
  if NOT (FTiming IN [mwtGenerate, mwtPreserve]) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Writer settings', 'Unsupported timestamp policy');
  if NOT FVideo.Enabled AND NOT FAudio.Enabled then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Writer settings', 'Enable at least one stream');
  if FVideo.Enabled then
  begin
    ValidateName(FVideo.EncoderName, 'Video encoder');
    if (FVideo.Width < 2) OR (FVideo.Height < 2) OR (Int64(FVideo.Width) * FVideo.Height > MEDIA_MAX_PIXELS) OR
      ((FVideo.Width MOD 2) <> 0) OR ((FVideo.Height MOD 2) <> 0) then
      raise EFFmpegMediaError.Create(mecInvalidSettings, 'Writer settings', 'YUV420 output requires positive even dimensions within 64 million pixels');
    if NOT FVideo.FrameRate.Known OR (FVideo.FrameRate.Value > 240) OR (FVideo.BitRate < 1) OR (FVideo.BitRate > 1000000000) then
      raise EFFmpegMediaError.Create(mecInvalidSettings, 'Writer settings', 'Video requires a known rate up to 240 fps and bitrate of 1-1000000000 bits/s');
    ValidateOptions(FVideo.Options, mosEncoder);
  end;
  if FAudio.Enabled then
  begin
    ValidateName(FAudio.EncoderName, 'Audio encoder');
    if (FAudio.SampleRate < 8000) OR (FAudio.SampleRate > 192000) OR (FAudio.Channels < 1) OR (FAudio.Channels > 2) OR
      (FAudio.BitRate < 0) OR (FAudio.BitRate > 1000000000) then
      raise EFFmpegMediaError.Create(mecInvalidSettings, 'Writer settings', 'Audio requires 8-192 kHz, mono/stereo and bitrate in bits/s (zero selects encoder default)');
    ValidateOptions(FAudio.Options, mosEncoder);
  end;
  ValidateOptions(FOptions, mosMuxer);
  if FTiming = mwtPreserve then
    for I:=0 to Length(FOptions) - 1 do
      if SameText(FOptions[I].Key, 'avoid_negative_ts') then
        raise EFFmpegMediaError.Create(mecInvalidSettings, 'Writer settings', 'avoid_negative_ts conflicts with timestamp preservation');
  for I:=0 to Length(FMetadata) - 1 do
  begin
    ValidateName(FMetadata[I].Key, 'Metadata');
    if Pos(#0, FMetadata[I].Value) > 0 then
      raise EFFmpegMediaError.Create(mecInvalidSettings, 'Writer settings', 'Metadata value contains NUL');
    for J:=0 to I - 1 do
      if SameText(FMetadata[J].Key, FMetadata[I].Key) then
        raise EFFmpegMediaError.Create(mecInvalidSettings, 'Writer settings', 'Duplicate metadata key: ' + FMetadata[I].Key);
  end;
end;

class function TMediaWriter.OpenFile(const AFilename: String; const ASettings: TMediaWriterSettings;
  const AToken: IMediaCancellationToken): IMediaWriter;
begin
  Result:=OpenMediaOutput(AFilename, ASettings, AToken);
end;

class function TMediaSequenceImage.FromFrame(const AFrame: IMediaVideoFrame; const ADuration: TMediaTime): TMediaSequenceImage;
begin
  Result:=Default(TMediaSequenceImage);
  Result.FFrame:=AFrame;
  Result.FDuration:=ADuration;
end;

class function TMediaSequenceImage.FromFile(const AFilename: String; const ADuration: TMediaTime): TMediaSequenceImage;
begin
  Result:=Default(TMediaSequenceImage);
  Result.FFilename:=AFilename;
  Result.FDuration:=ADuration;
end;

class function TMediaImageSequenceSettings.H264MP4(AWidth, AHeight: Integer; const AFrameRate: TMediaRate): TMediaImageSequenceSettings;
begin
  Result:=Default(TMediaImageSequenceSettings);
  Result.FWriter:=TMediaWriterSettings.H264MP4(AWidth, AHeight, AFrameRate);
  Result.FFit:=mfFit;
end;

class function TMediaImageSequence.WriteFile(const AFilename: String; const AImages: Array of TMediaSequenceImage;
  const ASettings: TMediaImageSequenceSettings; const AToken: IMediaCancellationToken): TMediaImageSequenceResult;
var
  Writer: IMediaWriter;
  Frame: IMediaVideoFrame;
  Settings: TMediaImageSettings;
  Total: TMediaTime;
  TimeBase: TMediaRate;
  Boundary, Submitted: Int64;
  I: Integer;
begin
  Result:=Default(TMediaImageSequenceResult);
  ASettings.Writer.Validate;
  if NOT ASettings.Writer.Video.Enabled OR ASettings.Writer.Audio.Enabled OR (Length(AImages) = 0) OR
    (ASettings.Writer.Timing <> mwtGenerate) then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Image sequence', 'A generated video-only writer and at least one image are required');
  Settings:=TMediaImageSettings.Default;
  Settings.Width:=ASettings.Writer.Video.Width;
  Settings.Height:=ASettings.Writer.Video.Height;
  Settings.Fit:=ASettings.Fit;
  Settings.BackgroundRGB:=ASettings.BackgroundRGB;
  Settings.TimeoutMilliseconds:=ASettings.Writer.TimeoutMilliseconds;
  Settings.Validate;
  TimeBase:=TMediaRate.Create(ASettings.Writer.Video.FrameRate.Denominator, ASettings.Writer.Video.FrameRate.Numerator);
  Total:=TMediaTime.FromMicroseconds(0);
  for I:=0 to Length(AImages) - 1 do
  begin
    if NOT AImages[I].Duration.Valid OR (AImages[I].Duration.Microseconds <= 0) OR
      (NOT Assigned(AImages[I].Frame) AND (AImages[I].Filename = '')) then
      raise EFFmpegMediaError.Create(mecInvalidSettings, 'Image sequence', 'Every image requires a source and positive known duration');
    Total:=Total.Add(AImages[I].Duration);
  end;
  Result.FRequestedDuration:=Total;
  Result.FFrameCount:=Total.ToTicks(TimeBase);
  if Result.FFrameCount < 1 then
    raise EFFmpegMediaError.Create(mecInvalidSettings, 'Image sequence', 'Total duration is shorter than one output frame');
  // Validate conversion/overflow before creating any output.
  Result.FEncodedDuration:=TMediaTime.FromTicks(Result.FFrameCount, TimeBase);
  Writer:=TMediaWriter.OpenFile(AFilename, ASettings.Writer, AToken);
  try
    Result.FEncoderName:=Writer.VideoEncoderName;
    Total:=TMediaTime.FromMicroseconds(0);
    Submitted:=0;
    for I:=0 to Length(AImages) - 1 do
    begin
      if Assigned(AToken) then
        AToken.ThrowIfCancellationRequested('Image sequence');
      Total:=Total.Add(AImages[I].Duration);
      Boundary:=Total.ToTicks(TimeBase);
      if Boundary = Submitted then
        Continue;
      if Assigned(AImages[I].Frame) then
        Frame:=TMediaImages.Render(AImages[I].Frame, Settings, AToken)
      else
        Frame:=TMediaImages.LoadFile(AImages[I].Filename, Settings, AToken);
      while Submitted < Boundary do
      begin
        Writer.SubmitVideo(Frame);
        Inc(Submitted);
      end;
      Frame:=nil;
    end;
    Writer.Finish;
  finally
    Writer.Abort;
  end;
end;

end.
