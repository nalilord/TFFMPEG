program MediaInfoSmoke;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
  Classes,
{$ELSE}
  System.SysUtils,
  System.Classes,
{$ENDIF}
  TFFmpeg.Media,
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Reader,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Errors,
  MediaTestSupport;

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

function Fixture(const AName: String): String;
begin
  Result:=ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + 'fixtures' + PathDelim + AName);
  Check(FileExists(Result), 'Generate required fixture: ' + Result);
end;

function LoadBytes(const AFilename: String): TBytes;
var
  Stream: TFileStream;
begin
  Result:=nil;
  Stream:=TFileStream.Create(AFilename, fmOpenRead OR fmShareDenyWrite);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then
      Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

function Tag(const AMetadata: TMediaMetadata; const AName: String): String;
var
  I: Integer;
begin
  Result:='';
  for I:=0 to Length(AMetadata) - 1 do
    if SameText(AMetadata[I].Key, AName) then
      Exit(AMetadata[I].Value);
end;

procedure TestKnownInfo;
var
  AudioInfo, VideoInfo, MultiInfo, ArtInfo, RotatedInfo: TMediaInfo;
  Streams: TMediaStreams;
  Metadata: TMediaMetadata;
  Dispositions: TMediaStrings;
  Bytes: TBytes;
  Failed: Boolean;
begin
  AudioInfo:=TFFmpegMedia.ProbeFile(Fixture('markers.wav'));
  Check(AudioInfo.FormatName = 'wav', 'WAV format');
  Check(AudioInfo.Seekable AND AudioInfo.Duration.Valid AND (AudioInfo.Duration.Microseconds = 100000), 'WAV duration/seekability');
  Streams:=AudioInfo.Streams;
  Check((Length(Streams) = 1) AND (Streams[0].Index = 0) AND (Streams[0].Kind = mkAudio), 'Audio-only stable index/kind');
  Check((Streams[0].CodecName = 'pcm_s16le') AND Streams[0].DecoderAvailable, 'PCM codec');
  Check((Streams[0].SampleRate = 24000) AND (Streams[0].ChannelLayout.Channels = 1), 'Audio rate/layout');
  Check((Streams[0].BitsPerSample = 16) AND (Streams[0].SampleFormatName = 's16'), 'Negotiated PCM format snapshot');
  Check(Streams[0].TimeBase.Known AND (Streams[0].Duration.Microseconds = 100000), 'Audio timing');
  Check(TMediaProbe.SelectStream(AudioInfo, mkVideo) = -1, 'Missing default kind');

  VideoInfo:=TFFmpegMedia.ProbeFile(Fixture('video.mkv'));
  Streams:=VideoInfo.Streams;
  Check((Length(Streams) = 1) AND (Streams[0].Kind = mkVideo) AND (Streams[0].CodecName = 'ffv1'), 'Video-only codec');
  Check((Streams[0].Width = 16) AND (Streams[0].Height = 12), 'Video dimensions');
  Check(Streams[0].FrameRate.Compare(TMediaRate.Create(10, 1)) = 0, 'Exact video rate');
  Check(VideoInfo.Duration.Microseconds = 300000, 'Container video duration');

  MultiInfo:=TFFmpegMedia.ProbeFile(Fixture('multi.mkv'));
  Streams:=MultiInfo.Streams;
  Check(Length(Streams) = 4, 'All streams, including decoderless attachment');
  Check((Streams[1].Index = 1) AND (Streams[2].Index = 2) AND (Streams[3].Index = 3), 'Stable source stream indexes');
  Check((Streams[1].Language = 'eng') AND (Streams[2].Language = 'deu'), 'Per-stream language');
  Check(Streams[2].DefaultTrack AND NOT Streams[1].DefaultTrack, 'Default disposition');
  Dispositions:=Streams[2].Dispositions;
  Check((Length(Dispositions) = 1) AND (Dispositions[0] = 'default'), 'Named disposition snapshot');
  Check((Streams[3].Kind = mkAttachment) AND NOT Streams[3].DecoderAvailable, 'Decoder absence must not block probe');
  Check(Tag(MultiInfo.Metadata, 'title') = 'Original synthetic multistream', 'Container metadata');
  Check(Tag(Streams[3].Metadata, 'filename') = 'original.bin', 'Attachment metadata scope');
  Check(TMediaProbe.SelectStream(MultiInfo, mkAudio) = 2, 'Default audio preference');
  Check(TMediaProbe.SelectStream(MultiInfo, mkAudio, 1) = 1, 'Explicit alternate audio');
  Check(TMediaProbe.SelectStream(MultiInfo, mkVideo, -2) = -1, 'Explicitly disabled kind');

  Bytes:=LoadBytes(Fixture('multi.mkv'));
  MultiInfo:=TFFmpegMedia.ProbeBytes(Bytes);
  FillChar(Bytes[0], Length(Bytes), 0);
  Bytes:=nil;
  Metadata:=MultiInfo.Metadata;
  Metadata[0]:=TMediaMetadataEntry.Create('caller', 'mutation');
  Streams:=MultiInfo.Streams;
  Streams[1].Language:='changed';
  Streams[3].Metadata:=Metadata;
  Streams:=MultiInfo.Streams;
  Check((Streams[1].Language = 'eng') AND (Tag(Streams[3].Metadata, 'filename') = 'original.bin'), 'Detached copied snapshots after byte mutation');
  Check(Tag(MultiInfo.Metadata, 'title') = 'Original synthetic multistream', 'Detached container metadata');

  ArtInfo:=TFFmpegMedia.ProbeFile(Fixture('cover.mp3'));
  Streams:=ArtInfo.Streams;
  Check((Length(Streams) = 2) AND Streams[1].AttachedArt, 'MP3 cover art identity');
  Check(TMediaProbe.SelectStream(ArtInfo, mkVideo) = -1, 'Default video excludes cover art');
  if Streams[1].DecoderAvailable then
    Check(TMediaProbe.SelectStream(ArtInfo, mkVideo, 1) = 1, 'Explicit attached-art selection')
  else
  begin
    Failed:=False;
    try
      TMediaProbe.SelectStream(ArtInfo, mkVideo, 1);
    except
      on E: EFFmpegMediaError do
        Failed:=E.Category = mecUnsupported;
    end;
    Check(Failed, 'Explicit unsupported art selection must report missing decoder');
    WriteLn('PASS: decoderless PNG art remains inspectable and explicit decode selection reports unsupported');
  end;
  Check(ArtInfo.StartTime.Valid AND (ArtInfo.StartTime.Microseconds > 0), 'Source start is preserved');

  RotatedInfo:=TFFmpegMedia.ProbeFile(Fixture('rotated.mp4'));
  Streams:=RotatedInfo.Streams;
  Check(Streams[0].RotationKnown AND (Abs(Streams[0].RotationDegrees - 90) < 0.001), 'Rotation metadata');
  Check(Streams[0].DisplayTransform.Known AND (Streams[0].DisplayTransform.Values[1] = -1), 'Owned full display matrix');
  Check(Streams[0].PixelAspect.Compare(TMediaRate.Create(2, 1)) = 0, 'Pixel aspect');
  Check(Streams[0].DisplayAspect.Compare(TMediaRate.Create(8, 3)) = 0, 'Coded display aspect before transform');
  Check((Streams[0].Color.Matrix = 'bt709') AND (Streams[0].Color.RangeName = 'tv'), 'SDR matrix/range tags');

  VideoInfo:=TFFmpegMedia.ProbeFile(Fixture('colors.bmp'));
  Check(NOT VideoInfo.Duration.Valid, 'Missing duration remains unknown');
  Streams:=AudioInfo.Streams;
  Check((Streams[0].SampleRate = 24000) AND (AudioInfo.Duration.Microseconds = 100000), 'Old snapshot survives unrelated reopen');
  AudioInfo:=TFFmpegMedia.ProbeFile(Fixture('channels33.wav'));
  Streams:=AudioInfo.Streams;
  Check(Streams[0].ChannelLayout.Channels = 33, 'Inspection must preserve audio layouts beyond decode limits');
  WriteLn('PASS: audio/video/multistream/art/decoderless/missing-field snapshots, aspect/color/rotation and stream selection');
end;

procedure TestErrorsAndLocalFiles;
var
  Directory: TMediaTestDirectory;
  Stream: TFileStream;
  Bytes: TBytes;
  Name: String;
  Info: TMediaInfo;
  Settings: TMediaInputSettings;
  Options: TMediaOptions;
  Source: IMediaCancellationSource;
  Failed: Boolean;
  I: Integer;
begin
  Bytes:=LoadBytes(Fixture('markers.wav'));
  Directory:=TMediaTestDirectory.Create;
  try
    Name:=Directory.FileName('literal ' + #$00E4 + #$4E2D + ' %03d.wav');
    Stream:=TFileStream.Create(Name, fmCreate);
    try
      Stream.WriteBuffer(Bytes[0], Length(Bytes));
    finally
      Stream.Free;
    end;
    Info:=TFFmpegMedia.ProbeFile(Name);
    Check(Info.Duration.Microseconds = 100000, 'Literal Unicode local path');
    Check(DeleteFile(Name), 'Probe must close local file handles');
    Info:=TFFmpegMedia.ProbeBytes(Bytes);
    Check(Info.Duration.Microseconds = 100000, 'Owned bytes survive original deletion');
  finally
    Directory.Free;
  end;

  Settings:=TMediaInputSettings.Default;
  SetLength(Options, 1);
  Options[0]:=TMediaOption.Create(mosDemuxer, 'tffmpeg_unknown_option', '1');
  Settings.Options:=Options;
  Source:=TMediaCancellation.CreateSource;
  Source.Cancel;
  for I:=0 to 7 do
  begin
    Failed:=False;
    try
      case I of
        0: Info:=TFFmpegMedia.ProbeFile('missing-tffmpeg-input.wav');
        1: Info:=TFFmpegMedia.ProbeBytes(nil);
        2: Info:=TFFmpegMedia.ProbeFile(Fixture('markers.wav'), Settings);
        3: Info:=TFFmpegMedia.ProbeFile(Fixture('markers.wav'), TMediaInputSettings.Default, Source.Token);
        4: Info:=TFFmpegMedia.ProbeFile(Fixture('markers.wav'), Default(TMediaInputSettings));
        5: Info:=TFFmpegMedia.ProbeFile('http://127.0.0.1/tffmpeg-never-a-local-file');
        6: Info:=TFFmpegMedia.ProbeFile('bad' + #0 + 'filename');
        7:
        begin
          SetLength(Bytes, 32);
          FillChar(Bytes[0], Length(Bytes), 0);
          Info:=TFFmpegMedia.ProbeBytes(Bytes);
        end;
      end;
    except
      on E: EFFmpegMediaError do
      begin
        case I of
          0, 5, 7: Failed:=(E.Category = mecInputOutput) AND E.HasNativeCode;
          1, 2, 4, 6: Failed:=E.Category = mecInvalidSettings;
          3: Failed:=(E IS EMediaCancelled) AND (E.Category = mecCancelled);
        end;
      end;
    end;
    Check(Failed, 'Probe error case ' + IntToStr(I));
    Info:=TFFmpegMedia.ProbeFile(Fixture('markers.wav'));
    Check(Info.Duration.Microseconds = 100000, 'Successful reopen after failure');
  end;

  for I:=0 to 2 do
  begin
    Failed:=False;
    try
      case I of
        0: TMediaProbe.SelectStream(Info, mkVideo, 0);
        1: TMediaProbe.SelectStream(Info, mkAudio, 1234);
        2: TMediaProbe.SelectStream(Info, mkSubtitle);
      end;
    except
      on E: EFFmpegMediaError do
        Failed:=E.Category = mecInvalidSettings;
    end;
    Check(Failed, 'Invalid stream selection case ' + IntToStr(I));
  end;
  WriteLn('PASS: literal Unicode file/byte ownership, failure cleanup, cancellation and invalid settings/options/selections');

  Settings:=TMediaInputSettings.Default;
  Settings.MaxStreams:=1;
  Failed:=False;
  try
    Info:=TFFmpegMedia.ProbeFile(Fixture('multi.mkv'), Settings);
  except
    on E: EFFmpegMediaError do
      Failed:=True;
  end;
  Check(Failed, 'Configured stream limit must be enforced');
  Info:=TFFmpegMedia.ProbeFile(Fixture('markers.wav'));
  Check(Info.Duration.Microseconds = 100000, 'Recovery after a resource-limit failure');
  WriteLn('PASS: stream resource limit enforcement and recovery');
end;

begin
  try
    TestKnownInfo;
    TestErrorsAndLocalFiles;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
