unit TFFmpeg.Media.Frames;

interface

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  TFFmpeg.Media.Types;

type
  IMediaSample = interface
    ['{F2BCC3E5-A62A-4B53-9755-A678FC756864}']
    function GetKind: TMediaKind;
    function GetStreamIndex: Integer;
    function GetTimestamp: TMediaTime;
    function GetDuration: TMediaTime;
    function GetFormatChanged: Boolean;
    function CopyBytes: TBytes;
    property Kind: TMediaKind read GetKind;
    property StreamIndex: Integer read GetStreamIndex;
    property Timestamp: TMediaTime read GetTimestamp;
    property Duration: TMediaTime read GetDuration;
    property FormatChanged: Boolean read GetFormatChanged;
  end;

  IMediaVideoFrame = interface(IMediaSample)
    ['{2F769B62-645F-4970-A51A-150747353916}']
    function GetWidth: Integer;
    function GetHeight: Integer;
    function GetStride: Integer;
    function GetPixelFormat: TMediaPixelFormat;
    property Width: Integer read GetWidth;
    property Height: Integer read GetHeight;
    property Stride: Integer read GetStride;
    property PixelFormat: TMediaPixelFormat read GetPixelFormat;
  end;

  IMediaAudioBuffer = interface(IMediaSample)
    ['{9D85B12C-AD52-4A84-BB44-F5E9F7620538}']
    function GetSampleCount: Integer;
    function GetSampleRate: Integer;
    function GetSampleFormat: TMediaSampleFormat;
    function GetChannelLayout: TMediaChannelLayout;
    property SampleCount: Integer read GetSampleCount;
    property SampleRate: Integer read GetSampleRate;
    property SampleFormat: TMediaSampleFormat read GetSampleFormat;
    property ChannelLayout: TMediaChannelLayout read GetChannelLayout;
  end;

  TMediaFrames = class sealed
  public
    // Top-down RGB byte order or BGRA byte order, straight alpha; positive stride.
    class function CopyVideo(const ABytes: TBytes; AWidth, AHeight, AStride: Integer; APixelFormat: TMediaPixelFormat;
      const ATimestamp: TMediaTime; AStreamIndex: Integer = -1; AFormatChanged: Boolean = False): IMediaVideoFrame; static;
    // Interleaved native-endian PCM, SampleCount is per channel, not byte count.
    class function CopyAudio(const ABytes: TBytes; ASampleCount, ASampleRate: Integer; ASampleFormat: TMediaSampleFormat;
      const AChannelLayout: TMediaChannelLayout; const ATimestamp: TMediaTime; AStreamIndex: Integer = -1;
      AFormatChanged: Boolean = False): IMediaAudioBuffer; static;
  end;

implementation

uses
  TFFmpeg.Media.Internal.Frames;

class function TMediaFrames.CopyVideo(const ABytes: TBytes; AWidth, AHeight, AStride: Integer; APixelFormat: TMediaPixelFormat;
  const ATimestamp: TMediaTime; AStreamIndex: Integer; AFormatChanged: Boolean): IMediaVideoFrame;
begin
  Result:=CreateVideoCopy(ABytes, AWidth, AHeight, AStride, APixelFormat, ATimestamp, AStreamIndex, AFormatChanged);
end;

class function TMediaFrames.CopyAudio(const ABytes: TBytes; ASampleCount, ASampleRate: Integer; ASampleFormat: TMediaSampleFormat;
  const AChannelLayout: TMediaChannelLayout; const ATimestamp: TMediaTime; AStreamIndex: Integer;
  AFormatChanged: Boolean): IMediaAudioBuffer;
begin
  Result:=CreateAudioCopy(ABytes, ASampleCount, ASampleRate, ASampleFormat, AChannelLayout, ATimestamp, AStreamIndex, AFormatChanged);
end;

end.
