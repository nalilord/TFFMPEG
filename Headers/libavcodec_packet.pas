(*
 * AVPacket public API
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 *)

(*
 * FFVCL - Delphi FFmpeg VCL Components
 * http://www.DelphiFFmpeg.com
 *
 * Original file: libavcodec/packet.h
 * Ported by CodeCoolie@CNSW 2020/11/11 -> $Date:: 2025-01-17 #$
 *)

(*
FFmpeg Delphi/Pascal Headers and Examples License Agreement

A modified part of FFVCL - Delphi FFmpeg VCL Components.
Copyright (c) 2008-2025 DelphiFFmpeg.com
All rights reserved.
http://www.DelphiFFmpeg.com

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

This source code is provided "as is" by DelphiFFmpeg.com without
warranty of any kind, either expressed or implied, including but not
limited to the implied warranties of merchantability and/or fitness
for a particular purpose.

Please also notice the License agreement of FFmpeg libraries.
*)

unit libavcodec_packet;

interface

{$I CompilerDefines.inc}

uses
  libavutil_buffer,
  libavutil_dict,
  libavutil_rational,
  FFTypes;

{$I libversion.inc}

(**
 * @defgroup lavc_packet_side_data AVPacketSideData
 *
 * Types and functions for working with AVPacketSideData.
 * @{
 *)
type
  TAVPacketSideDataType = (
    AV_PKT_DATA_PALETTE,
    AV_PKT_DATA_NEW_EXTRADATA,
    AV_PKT_DATA_PARAM_CHANGE,
    AV_PKT_DATA_H263_MB_INFO,
    AV_PKT_DATA_REPLAYGAIN,
    AV_PKT_DATA_DISPLAYMATRIX,
    AV_PKT_DATA_STEREO3D,
    AV_PKT_DATA_AUDIO_SERVICE_TYPE,
    AV_PKT_DATA_QUALITY_STATS,
    AV_PKT_DATA_FALLBACK_TRACK,
    AV_PKT_DATA_CPB_PROPERTIES,
    AV_PKT_DATA_SKIP_SAMPLES,
    AV_PKT_DATA_JP_DUALMONO,
    AV_PKT_DATA_STRINGS_METADATA,
    AV_PKT_DATA_SUBTITLE_POSITION,
    AV_PKT_DATA_MATROSKA_BLOCKADDITIONAL,
    AV_PKT_DATA_WEBVTT_IDENTIFIER,
    AV_PKT_DATA_WEBVTT_SETTINGS,
    AV_PKT_DATA_METADATA_UPDATE,
    AV_PKT_DATA_MPEGTS_STREAM_ID,
    AV_PKT_DATA_MASTERING_DISPLAY_METADATA,
    AV_PKT_DATA_SPHERICAL,
    AV_PKT_DATA_CONTENT_LIGHT_LEVEL,
    AV_PKT_DATA_A53_CC,
    AV_PKT_DATA_ENCRYPTION_INIT_INFO,
    AV_PKT_DATA_ENCRYPTION_INFO,
    AV_PKT_DATA_AFD,
    AV_PKT_DATA_PRFT,
    AV_PKT_DATA_ICC_PROFILE,
    AV_PKT_DATA_DOVI_CONF,
    AV_PKT_DATA_S12M_TIMECODE,
    AV_PKT_DATA_DYNAMIC_HDR10_PLUS,
    AV_PKT_DATA_IAMF_MIX_GAIN_PARAM,
    AV_PKT_DATA_IAMF_DEMIXING_INFO_PARAM,
    AV_PKT_DATA_IAMF_RECON_GAIN_INFO_PARAM,
    AV_PKT_DATA_AMBIENT_VIEWING_ENVIRONMENT,
    AV_PKT_DATA_FRAME_CROPPING,
    AV_PKT_DATA_LCEVC,
    AV_PKT_DATA_3D_REFERENCE_DISPLAYS,
    AV_PKT_DATA_RTCP_SR,
    AV_PKT_DATA_EXIF,
    AV_PKT_DATA_DYNAMIC_HDR_SMPTE_2094_APP5,
    AV_PKT_DATA_HEVC_CONF,
    AV_PKT_DATA_NB
  );

{$IFDEF FF_API_QUALITY_FACTOR}
const
  AV_PKT_DATA_QUALITY_FACTOR = AV_PKT_DATA_QUALITY_STATS; //DEPRECATED
{$ENDIF}

(**
 * This structure stores auxiliary information for decoding, presenting, or
 * otherwise processing the coded stream. It is typically exported by demuxers
 * and encoders and can be fed to decoders and muxers either in a per packet
 * basis, or as global side data (applying to the entire coded stream).
 *
 * Global side data is handled as follows:
 * - During demuxing, it may be exported through
 *   @ref AVStream.codecpar.side_data "AVStream's codec parameters", which can
 *   then be passed as input to decoders through the
 *   @ref AVCodecContext.coded_side_data "decoder context's side data", for
 *   initialization.
 * - For muxing, it can be fed through @ref AVStream.codecpar.side_data
 *   "AVStream's codec parameters", typically  the output of encoders through
 *   the @ref AVCodecContext.coded_side_data "encoder context's side data", for
 *   initialization.
 *
 * Packet specific side data is handled as follows:
 * - During demuxing, it may be exported through @ref AVPacket.side_data
 *   "AVPacket's side data", which can then be passed as input to decoders.
 * - For muxing, it can be fed through @ref AVPacket.side_data "AVPacket's
 *   side data", typically the output of encoders.
 *
 * Different modules may accept or export different types of side data
 * depending on media type and codec. Refer to @ref AVPacketSideDataType for a
 * list of defined types and where they may be found or used.
 *)
type
  PPAVPacketSideData = ^PAVPacketSideData;
  PAVPacketSideData = ^TAVPacketSideData;
  TAVPacketSideData = record
    data: PByte;
    size: Size_t;
    type_: TAVPacketSideDataType;
  end;

(**
 * Allocate a new packet side data.
 *
 * @param sd    pointer to an array of side data to which the side data should
 *              be added. *sd may be NULL, in which case the array will be
 *              initialized.
 * @param nb_sd pointer to an integer containing the number of entries in
 *              the array. The integer value will be increased by 1 on success.
 * @param type  side data type
 * @param size  desired side data size
 * @param flags currently unused. Must be zero
 *
 * @return pointer to freshly allocated side data on success, or NULL otherwise.
 *)
function av_packet_side_data_new(psd: PPAVPacketSideData; pnb_sd: PInteger;
                                          type_: TAVPacketSideDataType;
                                          size: Size_t; flags: Integer): PAVPacketSideData; cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_side_data_new';

(**
 * Wrap existing data as packet side data.
 *
 * @param sd    pointer to an array of side data to which the side data should
 *              be added. *sd may be NULL, in which case the array will be
 *              initialized
 * @param nb_sd pointer to an integer containing the number of entries in
 *              the array. The integer value will be increased by 1 on success.
 * @param type  side data type
 * @param data  a data array. It must be allocated with the av_malloc() family
 *              of functions. The ownership of the data is transferred to the
 *              side data array on success
 * @param size  size of the data array
 * @param flags currently unused. Must be zero
 *
 * @return pointer to freshly allocated side data on success, or NULL otherwise
 *         On failure, the side data array is unchanged and the data remains
 *         owned by the caller.
 *)
function av_packet_side_data_add(sd: PPAVPacketSideData; nb_sd: PInteger;
                                          type_: TAVPacketSideDataType;
                                          data: Pointer; size: Size_t; flags: Integer): PAVPacketSideData; cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_side_data_add';

(**
 * Get side information from a side data array.
 *
 * @param sd    the array from which the side data should be fetched
 * @param nb_sd value containing the number of entries in the array.
 * @param type  desired side information type
 *
 * @return pointer to side data if present or NULL otherwise
 *)
function av_packet_side_data_get(const sd: PAVPacketSideData;
                                                nb_sd: Integer;
                                                type_: TAVPacketSideDataType): PAVPacketSideData; cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_side_data_get';

(**
 * Remove side data of the given type from a side data array.
 *
 * @param sd    the array from which the side data should be removed
 * @param nb_sd pointer to an integer containing the number of entries in
 *              the array. Will be reduced by the amount of entries removed
 *              upon return
 * @param type  side information type
 *)
procedure av_packet_side_data_remove(sd: PAVPacketSideData; nb_sd: PInteger;
                                type_: TAVPacketSideDataType); cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_side_data_remove';

(**
 * Convenience function to free all the side data stored in an array, and
 * the array itself.
 *
 * @param sd    pointer to array of side data to free. Will be set to NULL
 *              upon return.
 * @param nb_sd pointer to an integer containing the number of entries in
 *              the array. Will be set to 0 upon return.
 *)
procedure av_packet_side_data_free(sd: PPAVPacketSideData; nb_sd: PInteger); cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_side_data_free';

function av_packet_side_data_name(type_: TAVPacketSideDataType): PAnsiChar; cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_side_data_name';

(**
 * @}
 *)

(**
 * @defgroup lavc_packet AVPacket
 *
 * Types and functions for working with AVPacket.
 * @{
 *)

(**
 * This structure stores compressed data. It is typically exported by demuxers
 * and then passed as input to decoders, or received as output from encoders and
 * then passed to muxers.
 *
 * For video, it should typically contain one compressed frame. For audio it may
 * contain several compressed frames. Encoders are allowed to output empty
 * packets, with no compressed data, containing only side data
 * (e.g. to update some stream parameters at the end of encoding).
 *
 * AVPacket is one of the few structs in FFmpeg, whose size is a part of public
 * ABI. Thus it may be allocated on stack and no new fields can be added to it
 * without libavcodec and libavformat major bump.
 *
 * The semantics of data ownership depends on the buf field.
 * If it is set, the packet data is dynamically allocated and is
 * valid indefinitely until a call to av_packet_unref() reduces the
 * reference count to 0.
 *
 * If the buf field is not set av_packet_ref() would make a copy instead
 * of increasing the reference count.
 *
 * The side data is always allocated with av_malloc(), copied by
 * av_packet_ref() and freed by av_packet_unref().
 *
 * sizeof(AVPacket) being a part of the public ABI is deprecated. once
 * av_init_packet() is removed, new packets will only be able to be allocated
 * with av_packet_alloc(), and new fields may be added to the end of the struct
 * with a minor bump.
 *
 * @see av_packet_alloc
 * @see av_packet_ref
 * @see av_packet_unref
 *)
type
  PPAVPacket = ^PAVPacket;
  PAVPacket = ^TAVPacket;
  TAVPacket = record
    (**
     * A reference to the reference-counted buffer where the packet data is
     * stored.
     * May be NULL, then the packet data is not reference-counted.
     *)
    buf: PAVBufferRef;
    (**
     * Presentation timestamp in AVStream->time_base units; the time at which
     * the decompressed packet will be presented to the user.
     * Can be AV_NOPTS_VALUE if it is not stored in the file.
     * pts MUST be larger or equal to dts as presentation cannot happen before
     * decompression, unless one wants to view hex dumps. Some formats misuse
     * the terms dts and pts/cts to mean something different. Such timestamps
     * must be converted to true pts/dts before they are stored in AVPacket.
     *)
    pts: Int64;
    (**
     * Decompression timestamp in AVStream->time_base units; the time at which
     * the packet is decompressed.
     * Can be AV_NOPTS_VALUE if it is not stored in the file.
     *)
    dts: Int64;
    data: PByte;
    size: Integer;
    stream_index: Integer;
    (**
     * A combination of AV_PKT_FLAG values
     *)
    flags: Integer;
    (**
     * Additional packet data that can be provided by the container.
     * Packet can contain several types of side information.
     *)
    side_data: PAVPacketSideData;
    side_data_elems: Integer;

    (**
     * Duration of this packet in AVStream->time_base units, 0 if unknown.
     * Equals next_pts - this_pts in presentation order.
     *)
    duration: Int64;

    pos: Int64;             ///< byte position in stream, -1 if unknown

    (**
     * for some private data of the user
     *)
    opaque: Pointer;

    (**
     * AVBufferRef for free use by the API user. FFmpeg will never check the
     * contents of the buffer ref. FFmpeg calls av_buffer_unref() on it when
     * the packet is unreferenced. av_packet_copy_props() calls create a new
     * reference with av_buffer_ref() for the target packet's opaque_ref field.
     *
     * This is unrelated to the opaque field, although it serves a similar
     * purpose.
     *)
    opaque_ref: PAVBufferRef;

    (**
     * Time base of the packet's timestamps.
     * In the future, this field may be set on packets output by encoders or
     * demuxers, but its value will be by default ignored on input to decoders
     * or muxers.
     *)
    time_base: TAVRational;
  end;

const
  AV_PKT_FLAG_KEY     = $0001; ///< The packet contains a keyframe
  AV_PKT_FLAG_CORRUPT = $0002; ///< The packet content is corrupted
(**
 * Flag is used to discard packets which are required to maintain valid
 * decoder state but are not required for output and should be dropped
 * after decoding.
 **)
  AV_PKT_FLAG_DISCARD = $0004;
(**
 * The packet comes from a trusted source.
 *
 * Otherwise-unsafe constructs such as arbitrary pointers to data
 * outside the packet may be followed.
 *)
  AV_PKT_FLAG_TRUSTED = $0008;
(**
 * Flag is used to indicate packets that contain frames that can
 * be discarded by the decoder.  I.e. Non-reference frames.
 *)
  AV_PKT_FLAG_DISPOSABLE = $0010;

type
  TAVSideDataParamChangeFlags = (
    AV_SIDE_DATA_PARAM_CHANGE_SAMPLE_RATE    = $0004,
    AV_SIDE_DATA_PARAM_CHANGE_DIMENSIONS     = $0008
  );

(**
 * Allocate an AVPacket and set its fields to default values.  The resulting
 * struct must be freed using av_packet_free().
 *
 * @return An AVPacket filled with default values or NULL on failure.
 *
 * @note this only allocates the AVPacket itself, not the data buffers. Those
 * must be allocated through other means such as av_new_packet.
 *
 * @see av_new_packet
 *)
function av_packet_alloc: PAVPacket; cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_alloc';

(**
 * Create a new packet that references the same data as src.
 *
 * This is a shortcut for av_packet_alloc()+av_packet_ref().
 *
 * @return newly created AVPacket on success, NULL on error.
 *
 * @see av_packet_alloc
 * @see av_packet_ref
 *)
function av_packet_clone(const src: PAVPacket): PAVPacket; cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_clone';

(**
 * Free the packet, if the packet is reference counted, it will be
 * unreferenced first.
 *
 * @param pkt packet to be freed. The pointer will be set to NULL.
 * @note passing NULL is a no-op.
 *)
procedure av_packet_free(pkt: PPAVPacket); cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_free';

{$IFDEF FF_API_INIT_PACKET}
(**
 * Initialize optional fields of a packet with default values.
 *
 * Note, this does not touch the data and size members, which have to be
 * initialized separately.
 *
 * @param pkt packet
 *
 * @see av_packet_alloc
 * @see av_packet_unref
 *
 * @deprecated This function is deprecated. Once it's removed,
               sizeof(AVPacket) will not be a part of the ABI anymore.
 *)
procedure av_init_packet(pkt: PAVPacket); cdecl; external AVCODEC_LIBNAME name _PU + 'av_init_packet';
{$ENDIF}

(**
 * Allocate the payload of a packet and initialize its fields with
 * default values.
 *
 * @param pkt packet
 * @param size wanted payload size
 * @return 0 if OK, AVERROR_xxx otherwise
 *)
function av_new_packet(pkt: PAVPacket; size: Integer): Integer; cdecl; external AVCODEC_LIBNAME name _PU + 'av_new_packet';

(**
 * Reduce packet size, correctly zeroing padding
 *
 * @param pkt packet
 * @param size new size
 *)
procedure av_shrink_packet(pkt: PAVPacket; size: Integer); cdecl; external AVCODEC_LIBNAME name _PU + 'av_shrink_packet';

(**
 * Increase packet size, correctly zeroing padding
 *
 * @param pkt packet
 * @param grow_by number of bytes by which to increase the size of the packet
 *)
function av_grow_packet(pkt: PAVPacket; grow_by: Integer): Integer; cdecl; external AVCODEC_LIBNAME name _PU + 'av_grow_packet';

(**
 * Initialize a reference-counted packet from av_malloc()ed data.
 *
 * @param pkt packet to be initialized. This function will set the data, size,
 *        and buf fields, all others are left untouched.
 * @param data Data allocated by av_malloc() to be used as packet data. If this
 *        function returns successfully, the data is owned by the underlying AVBuffer.
 *        The caller may not access the data through other means.
 * @param size size of data in bytes, without the padding. I.e. the full buffer
 *        size is assumed to be size + AV_INPUT_BUFFER_PADDING_SIZE.
 *
 * @return 0 on success, a negative AVERROR on error
 *)
function av_packet_from_data(pkt: PAVPacket; data: PByte; size: Integer): Integer; cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_from_data';

(**
 * Allocate new information of a packet.
 *
 * @param pkt packet
 * @param type side information type
 * @param size side information size
 * @return pointer to fresh allocated data or NULL otherwise
 *)
function av_packet_new_side_data(pkt: PAVPacket; type_: TAVPacketSideDataType;
                                 size: Size_t): PByte; cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_new_side_data';

(**
 * Wrap an existing array as a packet side data.
 *
 * @param pkt packet
 * @param type side information type
 * @param data the side data array. It must be allocated with the av_malloc()
 *             family of functions. The ownership of the data is transferred to
 *             pkt.
 * @param size side information size
 * @return a non-negative number on success, a negative AVERROR code on
 *         failure. On failure, the packet is unchanged and the data remains
 *         owned by the caller.
 *)
function av_packet_add_side_data(pkt: PAVPacket; type_: TAVPacketSideDataType;
                            data: PByte; size: Size_t): Integer; cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_add_side_data';

(**
 * Shrink the already allocated side data buffer
 *
 * @param pkt packet
 * @param type side information type
 * @param size new side information size
 * @return 0 on success, < 0 on failure
 *)
function av_packet_shrink_side_data(pkt: PAVPacket; type_: TAVPacketSideDataType;
                               size: Size_t): Integer; cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_shrink_side_data';

(**
 * Get side information from packet.
 *
 * @param pkt packet
 * @param type desired side information type
 * @param size If supplied, *size will be set to the size of the side data
 *             or to zero if the desired side data is not present.
 * @return pointer to data if present or NULL otherwise
 *)
function av_packet_get_side_data(const pkt: PAVPacket; type_: TAVPacketSideDataType;
                                 size: PSize_t): PByte; cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_get_side_data';

(**
 * Pack a dictionary for use in side_data.
 *
 * @param dict The dictionary to pack.
 * @param size pointer to store the size of the returned data
 * @return pointer to data if successful, NULL otherwise
 *)
function av_packet_pack_dictionary(dict: PAVDictionary; size: PSize_t): PByte; cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_pack_dictionary';

(**
 * Unpack a dictionary from side_data.
 *
 * @param data data from side_data
 * @param size size of the data
 * @param dict the metadata storage dictionary
 * @return 0 on success, < 0 on failure
 *)
function av_packet_unpack_dictionary(const data: PByte; size: Size_t; dict: PPAVDictionary): Integer; cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_unpack_dictionary';

(**
 * Convenience function to free all the side data stored.
 * All the other fields stay untouched.
 *
 * @param pkt packet
 *)
procedure av_packet_free_side_data(pkt: PAVPacket); cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_free_side_data';

(**
 * Setup a new reference to the data described by a given packet
 *
 * If src is reference-counted, setup dst as a new reference to the
 * buffer in src. Otherwise allocate a new buffer in dst and copy the
 * data from src into it.
 *
 * All the other fields are copied from src.
 *
 * @see av_packet_unref
 *
 * @param dst Destination packet. Will be completely overwritten.
 * @param src Source packet
 *
 * @return 0 on success, a negative AVERROR on error. On error, dst
 *         will be blank (as if returned by av_packet_alloc()).
 *)
function av_packet_ref(dst: PAVPacket; const src: PAVPacket): Integer; cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_ref';

(**
 * Wipe the packet.
 *
 * Unreference the buffer referenced by the packet and reset the
 * remaining packet fields to their default values.
 *
 * @param pkt The packet to be unreferenced.
 *)
procedure av_packet_unref(pkt: PAVPacket); cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_unref';

(**
 * Move every field in src to dst and reset src.
 *
 * @see av_packet_unref
 *
 * @param src Source packet, will be reset
 * @param dst Destination packet
 *)
procedure av_packet_move_ref(dst, src: PAVPacket); cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_move_ref';

(**
 * Copy only "properties" fields from src to dst.
 *
 * Properties for the purpose of this function are all the fields
 * beside those related to the packet data (buf, data, size)
 *
 * @param dst Destination packet
 * @param src Source packet
 *
 * @return 0 on success AVERROR on failure.
 *)
function av_packet_copy_props(dst: PAVPacket; const src: PAVPacket): Integer; cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_copy_props';

(**
 * Ensure the data described by a given packet is reference counted.
 *
 * @note This function does not ensure that the reference will be writable.
 *       Use av_packet_make_writable instead for that purpose.
 *
 * @see av_packet_ref
 * @see av_packet_make_writable
 *
 * @param pkt packet whose data should be made reference counted.
 *
 * @return 0 on success, a negative AVERROR on error. On failure, the
 *         packet is unchanged.
 *)
function av_packet_make_refcounted(pkt: PAVPacket): Integer; cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_make_refcounted';

(**
 * Create a writable reference for the data described by a given packet,
 * avoiding data copy if possible.
 *
 * @param pkt Packet whose data should be made writable.
 *
 * @return 0 on success, a negative AVERROR on failure. On failure, the
 *         packet is unchanged.
 *)
function av_packet_make_writable(pkt: PAVPacket): Integer; cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_make_writable';

(**
 * Convert valid timing fields (timestamps / durations) in a packet from one
 * timebase to another. Timestamps with unknown values (AV_NOPTS_VALUE) will be
 * ignored.
 *
 * @param pkt packet on which the conversion will be performed
 * @param tb_src source timebase, in which the timing fields in pkt are
 *               expressed
 * @param tb_dst destination timebase, to which the timing fields will be
 *               converted
 *)
procedure av_packet_rescale_ts(pkt: PAVPacket; tb_src, tb_dst: TAVRational); cdecl; external AVCODEC_LIBNAME name _PU + 'av_packet_rescale_ts';

(**
 * @}
 *)

implementation

end.
