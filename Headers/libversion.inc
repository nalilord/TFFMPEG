// TODO: check from ffmpeg.h
// deprecated features

const
  {%H-}FFMPEG_VERSION     = '9.0.2';
  {%H-}program_birth_year = 2000;
  {%H-}CONFIG_THIS_YEAR   = 2026;

  // libavcodec
  LIBAVCODEC_VERSION_MAJOR = 63;
  LIBAVCODEC_VERSION_MINOR = 1;
  LIBAVCODEC_VERSION_MICRO = 102;
  LIBAVCODEC_VERSION       = '63.1.102';
  LIBAVCODEC_VERSION_INT   = (LIBAVCODEC_VERSION_MAJOR shl 16) or
                             (LIBAVCODEC_VERSION_MINOR shl 8) or
                              LIBAVCODEC_VERSION_MICRO;
  {%H-}LIBAVCODEC_BUILD    = LIBAVCODEC_VERSION_INT;
  {%H-}LIBAVCODEC_IDENT    = 'Lavc' + LIBAVCODEC_VERSION;

(**
 * FF_API_* defines may be placed below to indicate public API that will be
 * dropped at a future version bump. The defines themselves are not part of
 * the public API and may change, break or disappear at any time.
 *
 * @note, when bumping the major version it is recommended to manually
 * disable each FF_API_* in its own commit instead of disabling them all
 * at once through the bump. This improves the git bisect-ability of the change.
 *)

{$DEFINE FF_API_INIT_PACKET}
{$DEFINE FF_API_INTRA_DC_PRECISION}
{$DEFINE FF_API_MJPEG_EXTERN_HUFF}

  // libavdevice
  LIBAVDEVICE_VERSION_MAJOR = 63;
  LIBAVDEVICE_VERSION_MINOR = 1;
  LIBAVDEVICE_VERSION_MICRO = 102;
  LIBAVDEVICE_VERSION       = '63.1.102';
  LIBAVDEVICE_VERSION_INT   = (LIBAVDEVICE_VERSION_MAJOR shl 16) or
                              (LIBAVDEVICE_VERSION_MINOR shl 8) or
                               LIBAVDEVICE_VERSION_MICRO;
  {%H-}LIBAVDEVICE_BUILD    = LIBAVDEVICE_VERSION_INT;
  {%H-}LIBAVDEVICE_IDENT    = 'Lavc' + LIBAVDEVICE_VERSION;

(**
 * FF_API_* defines may be placed below to indicate public API that will be
 * dropped at a future version bump. The defines themselves are not part of
 * the public API and may change, break or disappear at any time.
 *)



  // libavfilter
  LIBAVFILTER_VERSION_MAJOR  = 12;
  LIBAVFILTER_VERSION_MINOR  = 1;
  LIBAVFILTER_VERSION_MICRO  = 102;
  LIBAVFILTER_VERSION        = '12.1.102';
  LIBAVFILTER_VERSION_INT    = (LIBAVFILTER_VERSION_MAJOR shl 16) or
                               (LIBAVFILTER_VERSION_MINOR shl 8) or
                                LIBAVFILTER_VERSION_MICRO;
  {%H-}LIBAVFILTER_BUILD     = LIBAVFILTER_VERSION_INT;
  {%H-}LIBAVFILTER_IDENT     = 'Lavfi' + LIBAVFILTER_VERSION;

(**
 * FF_API_* defines may be placed below to indicate public API that will be
 * dropped at a future version bump. The defines themselves are not part of
 * the public API and may change, break or disappear at any time.
 *)



  // libavformat
  LIBAVFORMAT_VERSION_MAJOR = 63;
  LIBAVFORMAT_VERSION_MINOR = 1;
  LIBAVFORMAT_VERSION_MICRO = 102;
  LIBAVFORMAT_VERSION       = '63.1.102';
  LIBAVFORMAT_VERSION_INT   = (LIBAVFORMAT_VERSION_MAJOR shl 16) or
                              (LIBAVFORMAT_VERSION_MINOR shl 8) or
                               LIBAVFORMAT_VERSION_MICRO;
  {%H-}LIBAVFORMAT_BUILD    = LIBAVFORMAT_VERSION_INT;
  {%H-}LIBAVFORMAT_IDENT    = 'Lavf' + LIBAVFORMAT_VERSION;

(**
 * FF_API_* defines may be placed below to indicate public API that will be
 * dropped at a future version bump. The defines themselves are not part of
 * the public API and may change, break or disappear at any time.
 *
 * @note, when bumping the major version it is recommended to manually
 * disable each FF_API_* in its own commit instead of disabling them all
 * at once through the bump. This improves the git bisect-ability of the change.
 *
 *)

{$DEFINE FF_API_COMPUTE_PKT_FIELDS2}
{$DEFINE FF_API_FDEBUG_TS}
{$DEFINE FF_API_LCEVC_STRUCT}

{$DEFINE FF_API_R_FRAME_RATE}

  // libavutil
  LIBAVUTIL_VERSION_MAJOR = 61;
  LIBAVUTIL_VERSION_MINOR = 1;
  LIBAVUTIL_VERSION_MICRO = 102;
  LIBAVUTIL_VERSION       = '61.1.102';
  LIBAVUTIL_VERSION_INT   = (LIBAVUTIL_VERSION_MAJOR shl 16) or
                            (LIBAVUTIL_VERSION_MINOR shl 8) or
                             LIBAVUTIL_VERSION_MICRO;
  {%H-}LIBAVUTIL_BUILD    = LIBAVUTIL_VERSION_INT;
  {%H-}LIBAVUTIL_IDENT    = 'Lavu' + LIBAVUTIL_VERSION;

(**
 * @defgroup lavu_depr_guards Deprecation Guards
 * FF_API_* defines may be placed below to indicate public API that will be
 * dropped at a future version bump. The defines themselves are not part of
 * the public API and may change, break or disappear at any time.
 *
 * @note, when bumping the major version it is recommended to manually
 * disable each FF_API_* in its own commit instead of disabling them all
 * at once through the bump. This improves the git bisect-ability of the change.
 *
 * @{
 *)

{$DEFINE FF_API_CPU_FLAG_FORCE}
{$DEFINE FF_API_DOVI_L11_INVALID_PROPS}
{$DEFINE FF_API_ASSERT_FPU}
{$DEFINE FF_API_VULKAN_SYNC_QUEUES}

(**
 * @}
 *)

  // libswresample
  LIBSWRESAMPLE_VERSION_MAJOR = 7;
  LIBSWRESAMPLE_VERSION_MINOR = 1;
  LIBSWRESAMPLE_VERSION_MICRO = 102;
  LIBSWRESAMPLE_VERSION       = '7.1.102';
  LIBSWRESAMPLE_VERSION_INT   = (LIBSWRESAMPLE_VERSION_MAJOR shl 16) or
                                (LIBSWRESAMPLE_VERSION_MINOR shl 8) or
                                 LIBSWRESAMPLE_VERSION_MICRO;
  {%H-}LIBSWRESAMPLE_BUILD    = LIBSWRESAMPLE_VERSION_INT;
  {%H-}LIBSWRESAMPLE_IDENT    = 'SwS' + LIBSWRESAMPLE_VERSION;

  // libswscale
  LIBSWSCALE_VERSION_MAJOR = 10;
  LIBSWSCALE_VERSION_MINOR = 1;
  LIBSWSCALE_VERSION_MICRO = 102;
  LIBSWSCALE_VERSION       = '10.1.102';
  LIBSWSCALE_VERSION_INT   = (LIBSWSCALE_VERSION_MAJOR shl 16) or
                             (LIBSWSCALE_VERSION_MINOR shl 8) or
                              LIBSWSCALE_VERSION_MICRO;
  {%H-}LIBSWSCALE_BUILD    = LIBSWSCALE_VERSION_INT;
  {%H-}LIBSWSCALE_IDENT    = 'SwS' + LIBSWSCALE_VERSION;

(**
 * FF_API_* defines may be placed below to indicate public API that will be
 * dropped at a future version bump. The defines themselves are not part of
 * the public API and may change, break or disappear at any time.
 *)
{$IFDEF MSWINDOWS}
  CLibPrefix = '';
  CLibConnector = '-';
  CLibExtension = '.dll';
  _PU = '';
{$ENDIF}
{$IFDEF LINUX}
  CLibPrefix = 'lib';
  CLibConnector = '.so.';
  CLibExtension = '';
  _PU = '';
{$ENDIF}
{$IFDEF DARWIN}
  CLibPrefix = 'lib';
  CLibConnector = '.';
  CLibExtension = '.dylib';
  // On Mac OSX, cdecl names have a preceeding underscore
  // if x86 native backend.
  {$IF Defined(UNDERSCOREIMPORTNAME)}
    _PU = '_';
  {$ELSE}
    _PU = '';
  {$IFEND}
{$ENDIF}

  SLIBAVCODEC_VERSION_MAJOR    = '63';
  SLIBAVDEVICE_VERSION_MAJOR   = '63';
  SLIBAVFILTER_VERSION_MAJOR   = '12';
  SLIBAVFORMAT_VERSION_MAJOR   = '63';
  SLIBAVUTIL_VERSION_MAJOR     = '61';
  SLIBSWRESAMPLE_VERSION_MAJOR = '7';
  SLIBSWSCALE_VERSION_MAJOR    = '10';

  AVCODEC_LIBNAME    = CLibPrefix + 'avcodec'    + CLibConnector + SLIBAVCODEC_VERSION_MAJOR    + CLibExtension;
  AVDEVICE_LIBNAME   = CLibPrefix + 'avdevice'   + CLibConnector + SLIBAVDEVICE_VERSION_MAJOR   + CLibExtension;
  AVFILTER_LIBNAME   = CLibPrefix + 'avfilter'   + CLibConnector + SLIBAVFILTER_VERSION_MAJOR   + CLibExtension;
  AVFORMAT_LIBNAME   = CLibPrefix + 'avformat'   + CLibConnector + SLIBAVFORMAT_VERSION_MAJOR   + CLibExtension;
  AVUTIL_LIBNAME     = CLibPrefix + 'avutil'     + CLibConnector + SLIBAVUTIL_VERSION_MAJOR     + CLibExtension;
  SWRESAMPLE_LIBNAME = CLibPrefix + 'swresample' + CLibConnector + SLIBSWRESAMPLE_VERSION_MAJOR + CLibExtension;
  SWSCALE_LIBNAME    = CLibPrefix + 'swscale'    + CLibConnector + SLIBSWSCALE_VERSION_MAJOR    + CLibExtension;
