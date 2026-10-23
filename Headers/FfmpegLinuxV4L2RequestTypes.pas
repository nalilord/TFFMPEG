unit FfmpegLinuxV4L2RequestTypes;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  libavutil_hwcontext;

const
  AV_HWDEVICE_TYPE_V4L2REQUEST_ORD = Ord(AV_HWDEVICE_TYPE_OHCODEC) + 1;

type
  PAVV4L2RequestFramesContext = ^TAVV4L2RequestFramesContext;
  TAVV4L2RequestFramesContext = record
    internal: Pointer;
    pixelformat: UInt32;
    bit_depth: UInt32;
    init_controls: Pointer;
    nb_init_controls: Integer;
  end;

implementation

end.
