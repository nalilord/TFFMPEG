unit FfmpegLinuxHwAccelProbe;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  libavcodec,
  libavcodec_codec,
  libavcodec_codec_id,
  libavformat,
  libavutil,
  libavutil_hwcontext;

type
  TCodecHwAccelProbe = record
    CodecName: string;
    DecoderFound: Boolean;
    HwConfigCount: Integer;
    SupportsDrmPrime: Boolean;
    SupportsHwDeviceDrm: Boolean;
    SupportsHwFramesDrm: Boolean;
    SupportsV4L2Request: Boolean;
    SupportsHwDeviceV4L2Request: Boolean;
    SupportsHwFramesV4L2Request: Boolean;
  end;

  TLinuxHwAccelProbeReport = record
    RuntimeAvUtilVersion: Cardinal;
    RuntimeAvCodecVersion: Cardinal;
    RuntimeAvFormatVersion: Cardinal;
    DeviceDrmAvailable: Boolean;
    DeviceV4L2RequestAvailable: Boolean;
    H264: TCodecHwAccelProbe;
    HEVC: TCodecHwAccelProbe;
  end;

function ProbeLinuxHwAccelReport: TLinuxHwAccelProbeReport;
function LinuxHwAccelReportSummary(const AReport: TLinuxHwAccelProbeReport): string;
function LinuxHwAccelCodecSummary(const AProbe: TCodecHwAccelProbe): string;

implementation

uses
  SysUtils,
  libavutil_pixfmt,
  FfmpegLinuxV4L2RequestTypes,
  TRTMP.FFmpeg.API;

function VersionToString(AVersion: Cardinal): string;
begin
  Result := Format('%d.%d.%d', [(AVersion shr 16) and $FF,
    (AVersion shr 8) and $FF, AVersion and $FF]);
end;

function BoolWord(AValue: Boolean): string;
begin
  if AValue then
    Result := 'yes'
  else
    Result := 'no';
end;

function ProbeCodec(AID: TAVCodecID; const AName: string): TCodecHwAccelProbe;
var
  Codec: PAVCodec;
  Config: PAVCodecHWConfig;
  DeviceTypeOrd: Integer;
  Index: Integer;
begin
  Result := Default(TCodecHwAccelProbe);
  Result.CodecName := AName;

  Codec := TRtmpFFmpegApi.FindDecoder(AID);
  Result.DecoderFound := Assigned(Codec);
  if not Result.DecoderFound then
    Exit;

  Index := 0;
  while True do
  begin
    Config := avcodec_get_hw_config(Codec, Index);
    if not Assigned(Config) then
      Break;

    Inc(Result.HwConfigCount);
    DeviceTypeOrd := Ord(Config^.device_type);

    if Config^.pix_fmt = AV_PIX_FMT_DRM_PRIME then
      Result.SupportsDrmPrime := True;

    if DeviceTypeOrd = Ord(AV_HWDEVICE_TYPE_DRM) then
    begin
      Result.SupportsHwDeviceDrm :=
        Result.SupportsHwDeviceDrm or
        ((Config^.methods and AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) <> 0);
      Result.SupportsHwFramesDrm :=
        Result.SupportsHwFramesDrm or
        ((Config^.methods and AV_CODEC_HW_CONFIG_METHOD_HW_FRAMES_CTX) <> 0);
    end;

    if DeviceTypeOrd = AV_HWDEVICE_TYPE_V4L2REQUEST_ORD then
    begin
      Result.SupportsV4L2Request := True;
      Result.SupportsHwDeviceV4L2Request :=
        Result.SupportsHwDeviceV4L2Request or
        ((Config^.methods and AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) <> 0);
      Result.SupportsHwFramesV4L2Request :=
        Result.SupportsHwFramesV4L2Request or
        ((Config^.methods and AV_CODEC_HW_CONFIG_METHOD_HW_FRAMES_CTX) <> 0);
    end;

    Inc(Index);
  end;
end;

function ProbeLinuxHwAccelReport: TLinuxHwAccelProbeReport;
var
  DeviceType: TAVHWDeviceType;
begin
  Result := Default(TLinuxHwAccelProbeReport);
  Result.RuntimeAvUtilVersion := avutil_version;
  Result.RuntimeAvCodecVersion := avcodec_version;
  Result.RuntimeAvFormatVersion := avformat_version;

  DeviceType := av_hwdevice_find_type_by_name('drm');
  Result.DeviceDrmAvailable := Ord(DeviceType) = Ord(AV_HWDEVICE_TYPE_DRM);

  DeviceType := av_hwdevice_find_type_by_name('v4l2request');
  Result.DeviceV4L2RequestAvailable :=
    Ord(DeviceType) = AV_HWDEVICE_TYPE_V4L2REQUEST_ORD;

  Result.H264 := ProbeCodec(AV_CODEC_ID_H264, 'h264');
  Result.HEVC := ProbeCodec(AV_CODEC_ID_HEVC, 'hevc');
end;

function LinuxHwAccelCodecSummary(const AProbe: TCodecHwAccelProbe): string;
begin
  if not AProbe.DecoderFound then
    Exit(Format('%s decoder not found', [AProbe.CodecName]));

  Result := Format(
    '%s hwcfg=%d drmPrime=%s drm(device=%s frames=%s) v4l2request=%s (device=%s frames=%s)',
    [AProbe.CodecName, AProbe.HwConfigCount, BoolWord(AProbe.SupportsDrmPrime),
     BoolWord(AProbe.SupportsHwDeviceDrm), BoolWord(AProbe.SupportsHwFramesDrm),
     BoolWord(AProbe.SupportsV4L2Request),
     BoolWord(AProbe.SupportsHwDeviceV4L2Request),
     BoolWord(AProbe.SupportsHwFramesV4L2Request)]);
end;

function LinuxHwAccelReportSummary(const AReport: TLinuxHwAccelProbeReport): string;
begin
  Result := Format(
    'runtime lavu=%s lavc=%s lavf=%s devices drm=%s v4l2request=%s; %s; %s',
    [VersionToString(AReport.RuntimeAvUtilVersion),
     VersionToString(AReport.RuntimeAvCodecVersion),
     VersionToString(AReport.RuntimeAvFormatVersion),
     BoolWord(AReport.DeviceDrmAvailable),
     BoolWord(AReport.DeviceV4L2RequestAvailable),
     LinuxHwAccelCodecSummary(AReport.H264),
     LinuxHwAccelCodecSummary(AReport.HEVC)]);
end;

end.
