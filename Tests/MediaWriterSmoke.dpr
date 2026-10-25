program MediaWriterSmoke;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
  Classes,
{$ELSE}
  System.SysUtils,
  System.Classes,
{$ENDIF}
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Errors,
  TFFmpeg.Media.Control,
  TFFmpeg.Media.Frames,
  TFFmpeg.Media.Reader,
  TFFmpeg.Media.Writer,
  MediaTestSupport;

type
  IDelayedWriterToken = interface(IMediaCancellationToken)
    ['{BDA5D030-7800-41DF-87F7-619FC5A20170}']
    procedure Arm;
  end;

  TDelayedWriterToken = class(TInterfacedObject, IMediaCancellationToken, IDelayedWriterToken)
  private
    FArmed: Boolean;
  public
    procedure Arm;
    function IsCancellationRequested: Boolean;
    procedure ThrowIfCancellationRequested(const AOperation: String);
  end;

procedure TDelayedWriterToken.Arm;
begin
  FArmed:=True;
end;

function TDelayedWriterToken.IsCancellationRequested: Boolean;
begin
  Result:=False;
  if FArmed then
    Sleep(1100);
end;

procedure TDelayedWriterToken.ThrowIfCancellationRequested(const AOperation: String);
begin
  IsCancellationRequested;
end;

procedure Check(ACondition: Boolean; const AMessage: String);
begin
  if NOT ACondition then
    raise Exception.Create(AMessage);
end;

function Video(AIndex: Integer): IMediaVideoFrame;
var
  Bytes: TBytes;
  I: Integer;
begin
  Result:=nil;
  SetLength(Bytes, 32 * 24 * 4);
  for I:=0 to 32 * 24 - 1 do
  begin
    Bytes[I * 4]:=10 + AIndex * 11;
    Bytes[I * 4 + 1]:=20 + AIndex * 13;
    Bytes[I * 4 + 2]:=30 + AIndex * 17;
    Bytes[I * 4 + 3]:=255;
  end;
  Result:=TMediaFrames.CopyVideo(Bytes, 32, 24, 128, mpfBGRA32, TMediaTime.Unknown);
end;

function Audio(AOffset, ACount, ARate: Integer): IMediaAudioBuffer;
var
  Bytes: TBytes;
  I: Integer;
  Value: SmallInt;
begin
  Result:=nil;
  SetLength(Bytes, ACount * 2);
  for I:=0 to ACount - 1 do
  begin
    Value:=10000 - ((I + AOffset) MOD 2) * 20000;
    if I + AOffset = 0 then
      Value:=1234;
    if I + AOffset = 2399 then
      Value:=-2345;
    Move(Value, Bytes[I * 2], 2);
  end;
  Result:=TMediaFrames.CopyAudio(Bytes, ACount, ARate, msfS16, TMediaChannelLayout.Mono, TMediaTime.Unknown);
end;

procedure CheckNoSibling(const AFilename: String);
var
  Search: TSearchRec;
begin
  if FindFirst(AFilename + '.tffmpeg-*', faAnyFile, Search) = 0 then
  begin
    FindClose(Search);
    raise Exception.Create('Leaked output sibling: ' + AFilename);
  end;
end;

procedure CheckWave(const AFilename: String; AExpected: Integer; ACheckEdges: Boolean);
var
  Reader: IMediaReader;
  Settings: TMediaReaderSettings;
  Sample: IMediaSample;
  Buffer: IMediaAudioBuffer;
  Bytes: TBytes;
  First, Last: SmallInt;
  Count: Integer;
begin
  Settings:=TMediaReaderSettings.Default;
  Settings.VideoStreamIndex:=-2;
  Settings.Channels:=1;
  Settings.SampleRate:=48000;
  Reader:=TMediaReader.OpenFile(AFilename, Settings);
  Count:=0;
  First:=0;
  Last:=0;
  while Reader.ReadSample(Sample) = mrsSample do
  begin
    Buffer:=Sample AS IMediaAudioBuffer;
    Check(Buffer.Timestamp.Microseconds = Int64(Count) * 1000000 DIV 48000, 'Generated audio sample timestamps');
    Bytes:=Buffer.CopyBytes;
    if Count = 0 then
      Move(Bytes[0], First, 2);
    Move(Bytes[Length(Bytes) - 2], Last, 2);
    Inc(Count, Buffer.SampleCount);
  end;
  Check(Count = AExpected, 'Decoded audio sample count: ' + IntToStr(Count));
  if ACheckEdges then
    Check((First = 1234) AND (Last = -2345), 'Final partial PCM frame preserves edge samples');
  Reader.Close;
end;

procedure TestPCM(const AFilename: String);
var
  Writer: IMediaWriter;
  Buffer: IMediaAudioBuffer;
  I: Integer;
begin
  Writer:=TMediaWriter.OpenFile(AFilename, TMediaWriterSettings.PCMWave(48000, 1));
  Check((Writer.State = mwsConfiguring) AND NOT FileExists(AFilename), 'Configuring has no destination');
  Check((Writer.AudioEncoderName = 'pcm_s16le') AND (Writer.AudioCodecName = 'pcm_s16le'), 'Concrete encoder and codec reporting');
  Writer.Start;
  Writer.Start;
  Check(Writer.State = mwsWriting, 'Start is idempotent while writing');
  for I:=0 to 1 do
  begin
    Buffer:=Audio(I * 1177, 1177, 48000);
    Writer.SubmitAudio(Buffer);
    Buffer:=nil;
  end;
  Writer.SubmitAudio(Audio(2354, 46, 48000));
  Check(NOT FileExists(AFilename), 'Submission does not publish');
  Writer.Finish;
  Writer.Finish;
  Writer.Abort;
  Check((Writer.State = mwsFinished) AND FileExists(AFilename), 'Finish publishes once; abort does not remove successful output');
  CheckWave(AFilename, 2400, True);
  try
    Writer.SubmitAudio(Audio(0, 1, 48000));
    Check(False, 'Submission after finish must fail');
  except
    on E: EFFmpegMediaError do
      Check(E.Category = mecInvalidState, 'Finished submission category');
  end;
  CheckNoSibling(AFilename);
end;

procedure TestResample(const AFilename: String);
var
  Writer: IMediaWriter;
begin
  Writer:=TMediaWriter.OpenFile(AFilename, TMediaWriterSettings.PCMWave(48000, 1));
  Writer.SubmitAudio(Audio(0, 1201, 24000));
  Writer.SubmitAudio(Audio(1201, 1199, 24000));
  Writer.Finish;
  CheckWave(AFilename, 4800, False);
end;

procedure TestH264(const AFilename: String);
var
  Writer: IMediaWriter;
  Reader: IMediaReader;
  Settings: TMediaReaderSettings;
  Sample: IMediaSample;
  Frame: IMediaVideoFrame;
  Bytes: TBytes;
  Count: Integer;
  WriterSettings: TMediaWriterSettings;
  Encoding: TMediaVideoEncoding;
begin
  WriterSettings:=TMediaWriterSettings.H264MP4(32, 24, TMediaRate.Create(10, 1));
  Encoding:=WriterSettings.Video;
  Encoding.Options:=[TMediaOption.Create(mosEncoder, 'x264-params', 'b-adapt=0')];
  WriterSettings.Video:=Encoding;
  Writer:=TMediaWriter.OpenFile(AFilename, WriterSettings);
  Check((Writer.VideoEncoderName = 'libx264') AND (Writer.VideoCodecName = 'h264'), 'Required H264 encoder preflight/report');
  for Count:=0 to 11 do
  begin
    Frame:=Video(Count);
    Writer.SubmitVideo(Frame);
    Frame:=nil;
  end;
  Writer.Finish;
  CheckNoSibling(AFilename);
  Settings:=TMediaReaderSettings.Default;
  Settings.AudioStreamIndex:=-2;
  Reader:=TMediaReader.OpenFile(AFilename, Settings);
  Count:=0;
  while Reader.ReadSample(Sample) = mrsSample do
  begin
    Check(Count < 12, 'No extra delayed video frame');
    Frame:=Sample AS IMediaVideoFrame;
    Check((Frame.Width = 32) AND (Frame.Height = 24), 'Encoded geometry');
    Check(Frame.Timestamp.Microseconds = Int64(Count) * 100000, 'Generated CFR presentation timestamps');
    Bytes:=Frame.CopyBytes;
    Check((Abs(Integer(Bytes[0]) - (10 + Count * 11)) <= 5) AND
      (Abs(Integer(Bytes[1]) - (20 + Count * 13)) <= 5) AND
      (Abs(Integer(Bytes[2]) - (30 + Count * 17)) <= 5), 'Decoded H264 frame identity ' + IntToStr(Count));
    Inc(Count);
  end;
  Check(Count = 12, 'All delayed H264 frames drained');
  Check(Abs(Reader.Info.Duration.Microseconds - 1200000) <= 100000, 'MP4 duration within one frame');
  Reader.Close;
end;

procedure TestCompressedAudio(const AFilename: String; APlanar: Boolean);
var
  Writer: IMediaWriter;
  Reader: IMediaReader;
  Settings: TMediaWriterSettings;
  Encoding: TMediaAudioEncoding;
  ReaderSettings: TMediaReaderSettings;
  Sample: IMediaSample;
  Buffer: IMediaAudioBuffer;
  Count: Integer;
begin
  Settings:=TMediaWriterSettings.OggOpus(1, 64000);
  if APlanar then
  begin
    Settings.MuxerName:='mp4';
    Encoding:=Settings.Audio;
    Encoding.EncoderName:='aac';
    Settings.Audio:=Encoding;
  end;
  Writer:=TMediaWriter.OpenFile(AFilename, Settings);
  Writer.SubmitAudio(Audio(0, 1177, 24000));
  Writer.SubmitAudio(Audio(1177, 1223, 24000));
  Writer.Finish;
  ReaderSettings:=TMediaReaderSettings.Default;
  ReaderSettings.VideoStreamIndex:=-2;
  ReaderSettings.Channels:=1;
  Reader:=TMediaReader.OpenFile(AFilename, ReaderSettings);
  Count:=0;
  while Reader.ReadSample(Sample) = mrsSample do
  begin
    Buffer:=Sample AS IMediaAudioBuffer;
    Inc(Count, Buffer.SampleCount);
  end;
  Check(Count = 4800, 'Compressed audio delay and final partial padding trim exactly once: ' + Writer.AudioEncoderName);
  Check(Abs(Reader.Info.Duration.Microseconds - 100000) <= 20000, 'Compressed audio presentation duration');
  Reader.Close;
end;

procedure TestCombined(const AFilename: String);
var
  Writer: IMediaWriter;
  Reader: IMediaReader;
  Settings: TMediaWriterSettings;
  ReaderSettings: TMediaReaderSettings;
  Sample: IMediaSample;
  Frames, Samples, I: Integer;
begin
  Settings:=TMediaWriterSettings.H264MP4(32, 24, TMediaRate.Create(10, 1));
  Settings.MuxerName:='matroska';
  Settings.Audio:=TMediaAudioEncoding.PCM(48000, 1);
  Writer:=TMediaWriter.OpenFile(AFilename, Settings);
  Writer.SubmitAudio(Audio(0, 2400, 48000));
  for I:=0 to 11 do
    Writer.SubmitVideo(Video(I));
  Writer.Finish;
  ReaderSettings:=TMediaReaderSettings.Default;
  ReaderSettings.Channels:=1;
  Reader:=TMediaReader.OpenFile(AFilename, ReaderSettings);
  Frames:=0;
  Samples:=0;
  while Reader.ReadSample(Sample) = mrsSample do
    if Sample.Kind = mkVideo then
      Inc(Frames)
    else
      Inc(Samples, (Sample AS IMediaAudioBuffer).SampleCount);
  Check((Frames = 12) AND (Samples = 2400), 'Unequal-length audio/video streams interleave and fully drain');
  Reader.Close;
end;

procedure TestHeaderFailure(const ADirectory: String);
var
  Writer: IMediaWriter;
  Search: TSearchRec;
  Filename, Temporary: String;
begin
  Check(CreateDir(ADirectory), 'Create header failure directory');
  Filename:=IncludeTrailingPathDelimiter(ADirectory) + 'header.wav';
  Writer:=TMediaWriter.OpenFile(Filename, TMediaWriterSettings.PCMWave(48000, 1));
  Check(FindFirst(Filename + '.tffmpeg-*', faAnyFile, Search) = 0, 'Find reserved sibling');
  Temporary:=IncludeTrailingPathDelimiter(ADirectory) + Search.Name;
  FindClose(Search);
  Check(DeleteFile(Temporary) AND RemoveDir(ADirectory), 'Remove destination directory before header IO');
  try
    Writer.Start;
    Check(False, 'Header IO failure must surface');
  except
    on E: EFFmpegMediaError do
      Check((E.Category = mecInputOutput) AND E.HasNativeCode AND (Writer.State = mwsFailed), 'Header IO error/category/state');
  end;
  Check(NOT FileExists(Filename) AND NOT FileExists(Temporary), 'Header failure publishes nothing');
end;

procedure TestTimeout(const AFilename: String);
var
  Token: IDelayedWriterToken;
  Writer: IMediaWriter;
  Settings: TMediaWriterSettings;
begin
  Token:=TDelayedWriterToken.Create;
  Settings:=TMediaWriterSettings.PCMWave(48000, 1);
  Settings.TimeoutMilliseconds:=1000;
  Writer:=TMediaWriter.OpenFile(AFilename, Settings, Token);
  Token.Arm;
  try
    Writer.SubmitAudio(Audio(0, 100, 48000));
    Check(False, 'Timed-out writer submission must fail');
  except
    on E: EMediaTimedOut do
      Check(Writer.State = mwsFailed, 'Timed-out writer is terminal');
  end;
  Check(NOT FileExists(AFilename), 'Timed-out writer does not publish');
  CheckNoSibling(AFilename);
end;

procedure WriteSentinel(const AFilename: String);
var
  Stream: TFileStream;
  Value: Byte;
begin
  Stream:=TFileStream.Create(AFilename, fmCreate);
  try
    Value:=71;
    Stream.WriteBuffer(Value, 1);
  finally
    Stream.Free;
  end;
end;

procedure CheckSentinel(const AFilename: String);
var
  Stream: TFileStream;
  Value: Byte;
begin
  Stream:=TFileStream.Create(AFilename, fmOpenRead OR fmShareDenyNone);
  try
    Check(Stream.Size = 1, 'Existing destination size preserved');
    Stream.ReadBuffer(Value, 1);
    Check(Value = 71, 'Existing destination bytes preserved');
  finally
    Stream.Free;
  end;
end;

procedure TestFailures(const AFilename: String);
var
  Writer: IMediaWriter;
  Settings: TMediaWriterSettings;
  Encoding: TMediaAudioEncoding;
  Source: IMediaCancellationSource;
begin
  Settings:=TMediaWriterSettings.PCMWave(48000, 1);
  Encoding:=Settings.Audio;
  Encoding.EncoderName:='tffmpeg_missing_encoder';
  Settings.Audio:=Encoding;
  try
    Writer:=TMediaWriter.OpenFile(AFilename, Settings);
    Check(False, 'Missing encoder must fail before file creation');
  except
    on E: EFFmpegMediaError do
      Check(E.Category = mecUnsupported, 'Missing encoder category');
  end;
  CheckNoSibling(AFilename);
  Check(NOT FileExists(AFilename), 'Missing encoder does not publish');
  try
    Writer:=TMediaWriter.OpenFile(AFilename, TMediaWriterSettings.H264MP4(31, 24, TMediaRate.Create(10, 1)));
    Check(False, 'Odd dimensions require explicit caller padding');
  except
    on E: EFFmpegMediaError do
      Check(E.Category = mecInvalidSettings, 'Odd geometry category');
  end;
  Settings:=TMediaWriterSettings.PCMWave(48000, 1);
  Writer:=TMediaWriter.OpenFile(AFilename, Settings);
  Writer.SubmitAudio(Audio(0, 100, 48000));
  Writer.Abort;
  Writer.Abort;
  Check((Writer.State = mwsAborted) AND NOT FileExists(AFilename), 'Abort discards unfinished output');
  CheckNoSibling(AFilename);
  Writer:=TMediaWriter.OpenFile(AFilename, Settings);
  Writer.SubmitAudio(Audio(0, 100, 48000));
  Writer:=nil;
  Check(NOT FileExists(AFilename), 'Destructor does not publish');
  CheckNoSibling(AFilename);
  Writer:=TMediaWriter.OpenFile(AFilename, Settings);
  Writer.SubmitAudio(Audio(0, 100, 48000));
  WriteSentinel(AFilename);
  try
    Writer.Finish;
    Check(False, 'Competing destination creation must fail publication');
  except
    on E: EFFmpegMediaError do
      Check((E.Category = mecInputOutput) AND (Writer.State = mwsFailed), 'Publication failure state');
  end;
  CheckSentinel(AFilename);
  CheckNoSibling(AFilename);
  Settings.Overwrite:=True;
  Source:=TMediaCancellation.CreateSource;
  Writer:=TMediaWriter.OpenFile(AFilename, Settings, Source.Token);
  Writer.SubmitAudio(Audio(0, 100, 48000));
  Source.Cancel;
  try
    Writer.Finish;
    Check(False, 'Cancelled finish must fail');
  except
    on E: EMediaCancelled do
      Check(Writer.State = mwsFailed, 'Cancelled writer is terminal');
  end;
  Writer.Abort;
  CheckSentinel(AFilename);
  CheckNoSibling(AFilename);
  Writer:=TMediaWriter.OpenFile(AFilename, Settings);
  Writer.SubmitAudio(Audio(0, 2400, 48000));
  Writer.Finish;
  CheckWave(AFilename, 2400, True);
  CheckNoSibling(AFilename);
end;

procedure TestTypedOptionAliases(const AFilename: String);
const
  Keys: Array[0..4] of String = ('ab', 'ch_layout', 'flags', 'pixel_format', 'video_size');
  Values: Array[0..4] of String = ('64000', '5.1', '0', 'bgra', '16x16');
var
  Settings: TMediaWriterSettings;
  AudioEncoding: TMediaAudioEncoding;
  VideoEncoding: TMediaVideoEncoding;
  Writer: IMediaWriter;
  I: Integer;
begin
  for I:=0 to High(Keys) do
  begin
    if I < 3 then
    begin
      Settings:=TMediaWriterSettings.PCMWave(48000, 1);
      AudioEncoding:=Settings.Audio;
      AudioEncoding.Options:=[TMediaOption.Create(mosEncoder, Keys[I], Values[I])];
      Settings.Audio:=AudioEncoding;
    end else
    begin
      Settings:=TMediaWriterSettings.H264MP4(32, 24, TMediaRate.Create(10, 1));
      VideoEncoding:=Settings.Video;
      VideoEncoding.Options:=[TMediaOption.Create(mosEncoder, Keys[I], Values[I])];
      Settings.Video:=VideoEncoding;
    end;
    try
      Writer:=TMediaWriter.OpenFile(AFilename, Settings);
      Check(False, 'Native alias must not override a fixed stream/header setting');
    except
      on E: EFFmpegMediaError do
        Check((E.Category = mecInvalidSettings) AND (Pos(Keys[I], E.Message) > 0), 'Typed option alias conflict diagnostic');
    end;
    CheckNoSibling(AFilename);
    Check(NOT FileExists(AFilename) AND NOT Assigned(Writer), 'Typed conflict fails before output creation');
  end;
end;

var
  Directory: TMediaTestDirectory;
begin
  try
    Directory:=TMediaTestDirectory.Create;
    try
      TestPCM(Directory.FileName('pcm.wav'));
      TestResample(Directory.FileName('resampled.wav'));
      TestH264(Directory.FileName('video.mp4'));
      TestCompressedAudio(Directory.FileName('planar.m4a'), True);
      TestCompressedAudio(Directory.FileName('opus.ogg'), False);
      TestCombined(Directory.FileName('combined.mkv'));
      TestHeaderFailure(Directory.FileName('missing-directory'));
      TestTimeout(Directory.FileName('timeout.wav'));
      TestFailures(Directory.FileName('failure.wav'));
      TestTypedOptionAliases(Directory.FileName('typed-conflict.tmp'));
      WriteLn('PASS: public writer PCM, planar AAC, Opus, AV interleaving, H264 identities/timing, lifecycle and publication');
    finally
      Directory.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
