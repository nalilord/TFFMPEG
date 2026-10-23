unit FfmpegLinuxDrmTypes;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  ctypes;

const
  AV_DRM_MAX_PLANES = 4;

type
  PAVDRMObjectDescriptor = ^TAVDRMObjectDescriptor;
  TAVDRMObjectDescriptor = record
    fd: Integer;
    size: csize_t;
    format_modifier: UInt64;
  end;

  PAVDRMPlaneDescriptor = ^TAVDRMPlaneDescriptor;
  TAVDRMPlaneDescriptor = record
    object_index: Integer;
    offset: NativeInt;
    pitch: NativeInt;
  end;

  PAVDRMLayerDescriptor = ^TAVDRMLayerDescriptor;
  TAVDRMLayerDescriptor = record
    format: UInt32;
    nb_planes: Integer;
    planes: array[0..AV_DRM_MAX_PLANES - 1] of TAVDRMPlaneDescriptor;
  end;

  PAVDRMFrameDescriptor = ^TAVDRMFrameDescriptor;
  TAVDRMFrameDescriptor = record
    nb_objects: Integer;
    objects: array[0..AV_DRM_MAX_PLANES - 1] of TAVDRMObjectDescriptor;
    nb_layers: Integer;
    layers: array[0..AV_DRM_MAX_PLANES - 1] of TAVDRMLayerDescriptor;
  end;

  PAVDRMDeviceContext = ^TAVDRMDeviceContext;
  TAVDRMDeviceContext = record
    fd: Integer;
  end;

implementation

end.
