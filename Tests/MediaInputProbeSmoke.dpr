program MediaInputProbeSmoke;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
  Classes,
{$ELSE}
  System.SysUtils,
  System.Classes,
{$ENDIF}
  libavformat_avio,
  libavcodec_codec,
  libavcodec_codec_id,
  libavcodec_codec_par,
  libavutil,
  libavutil_dict,
  TFFmpeg.Decoder,
  TFFmpeg.Input;

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

function CancelRead(AOpaque: Pointer): Integer; cdecl;
begin
  Result:=1;
  Inc(PInteger(AOpaque)^);
end;

procedure Run;
var
  Input: TFFmpegInput;
  Options: PAVDictionary;
  Interrupt: TAVIOInterruptCB;
  AudioName, VideoName: String;
  Calls, I: Integer;
  Stream: TFileStream;
  Bytes: TBytes;
  Decoder: TFFmpegDecoder;
  Parameters: PAVCodecParameters;
begin
  AudioName:=ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + 'fixtures' + PathDelim + 'markers.wav');
  VideoName:=ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + 'fixtures' + PathDelim + 'video.mkv');
  Stream:=TFileStream.Create(AudioName, fmOpenRead OR fmShareDenyWrite);
  try
    SetLength(Bytes, Stream.Size);
    Stream.ReadBuffer(Bytes[0], Length(Bytes));
  finally
    Stream.Free;
  end;
  Input:=TFFmpegInput.Create;
  Options:=nil;
  try
    Interrupt:=Default(TAVIOInterruptCB);
    for I:=0 to 9 do
    begin
      Check(Input.ProbeFile(VideoName, Options, Interrupt) = 0, 'Video-only probing without default audio decoder');
      Check((Input.StreamIndex = -1) AND NOT Assigned(Input.Codec), 'Probe must not select a decoder');
      Check(Input.OpenFile(VideoName, Options, Interrupt) < 0, 'Legacy open still requires default audio stream');
      Check(NOT Assigned(Input.FormatContext), 'Failed legacy selection closes context');
      Check(Input.ProbeBytes(Bytes, Options, Interrupt) = 0, 'Byte probing');
      Check((Input.StreamIndex = -1) AND NOT Assigned(Input.Codec), 'Byte probe has no selection');
      Check(Input.OpenFile(AudioName, Options, Interrupt) = 0, 'Legacy default audio selection remains available');
      Check((Input.StreamIndex = 0) AND Assigned(Input.Codec), 'Legacy selected audio contract');
      Check(Input.ProbeBytes(nil, Options, Interrupt) < 0, 'Empty probe must fail');
      Check(NOT Assigned(Input.FormatContext), 'Failed byte probe closes old context');
    end;

    Calls:=0;
    Interrupt.callback:=CancelRead;
    Interrupt.opaque:=@Calls;
    Check(Input.ProbeBytes(Bytes, Options, Interrupt) < 0, 'Native memory-input cancellation');
    Check((Calls > 0) AND NOT Assigned(Input.FormatContext), 'Cancelled probe invokes callback and closes owned state');
    Interrupt:=Default(TAVIOInterruptCB);
    Check(Input.ProbeBytes(Bytes, Options, Interrupt) = 0, 'Probe reopens after native cancellation');
    Input.Close;
    Check((Input.StreamIndex = -1) AND NOT Assigned(Input.FormatContext), 'Close clears selection/context');
  finally
    Input.Free;
    av_dict_free(@Options);
  end;
  Decoder:=TFFmpegDecoder.Create;
  Parameters:=nil;
  try
    Parameters:=avcodec_parameters_alloc;
    Check(Assigned(Parameters), 'Allocate failure-path codec parameters');
    Parameters.codec_type:=AVMEDIA_TYPE_AUDIO;
    Parameters.codec_id:=AV_CODEC_ID_PCM_S16LE;
    for I:=0 to 9 do
    begin
      Check(Decoder.Open(avcodec_find_decoder(AV_CODEC_ID_PCM_S16LE), Parameters) < 0, 'Invalid native decoder open must fail');
      Check(NOT Assigned(Decoder.CodecContext) AND NOT Assigned(Decoder.Codec), 'Failed native open must release the context');
      Decoder.Reset;
    end;
  finally
    avcodec_parameters_free(@Parameters);
    Decoder.Free;
  end;
  WriteLn('PASS: lower-level decoder-independent probe, legacy selection, failure/cancellation cleanup and repeated reopen');
end;

begin
  try
    Run;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
