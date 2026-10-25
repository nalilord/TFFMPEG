# TFFMPEG

**Inspect, decode, convert and record media in Delphi — powered by FFmpeg.**

[![FFmpeg](https://img.shields.io/badge/FFmpeg-9.0.2-007808)](Runtime/README.md)
[![Delphi](https://img.shields.io/badge/Delphi-Win32%20%7C%20Win64-CC0000)](#compatibility)
[![License](https://img.shields.io/badge/Wrapper_license-BSD--2--Clause-blue)](LICENSE)

TFFMPEG brings FFmpeg to Pascal applications through a high-level media API,
reusable native wrappers and translated headers. Read files, extract frames,
write audio/video, convert formats and capture cameras or microphones using
ordinary Pascal records and interfaces. The media API owns the native packets,
frames, codecs and processing loops for you.

Use the source units directly in console, desktop or service applications.
No VCL or FMX dependency is required.

[Get started](#get-started) · [Examples](#examples) · [Runtime setup](Runtime/README.md) · [Build and test](#build-and-test)

## What you can build

| Task | Included capabilities |
| --- | --- |
| **Inspect media** | Container and stream metadata, codecs, duration, dimensions, channel layouts and decoder availability |
| **Read audio and video** | File, byte-array and HTTP/HTTPS input; decoded samples, seeking, timestamps and retained buffers |
| **Extract and transform images** | Screenshots, BMP/PNG/JPEG, fit/fill/stretch, alpha compositing, pixel aspect and supported orientation transforms |
| **Create media** | Raw audio/video encoding, still-image sequences, H.264 MP4, PCM WAV and Ogg/Opus |
| **Convert files** | MP3 to Opus, selected-track audio conversion, H.264/Opus Matroska and H.264/AAC MP4 presets |
| **Capture and record** | Windows DirectShow discovery, mode queries, camera/microphone capture, bounded preview queues and timed or gracefully stopped recording |

Progress callbacks, cancellation, operation timeouts and explicit memory bounds
are part of the API. Writers publish completed output only after successful
finalization; existing destinations are protected by default.

## Get started

### 1. Install matching native libraries

This repository contains source code. Download or build **FFmpeg 9.0.2 shared
libraries** for your application's architecture and deploy them beside the
executable. The [runtime guide](Runtime/README.md) lists the exact DLL versions,
downloads and optional Win32 build recipes.

The H.264 presets require `libx264`; Opus presets require `libopus`. PNG support
requires a runtime built with zlib. Presets report missing capabilities explicitly.

### 2. Add the Pascal units

Add these directories to your project's unit search path:

```text
Source
Headers
```

Also add `Headers` to the include path. Rebuild all units when changing the
FFmpeg binding or ABI version.

### 3. Inspect a file and save a screenshot

```pascal
program MediaQuickStart;

{$APPTYPE CONSOLE}

uses
  TFFmpeg.Media,
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Images;

var
  Info: TMediaInfo;
  Screenshot: TMediaScreenshot;
begin
  Info:=TFFmpegMedia.ProbeFile('movie.mp4');
  WriteLn('Container: ', Info.FormatName);
  WriteLn('Streams: ', Length(Info.Streams));

  Screenshot:=TFFmpegMedia.SaveScreenshot(
    'movie.mp4', TMediaTime.FromSeconds(1.5), 'screenshot.png');
  WriteLn('Selected frame: ', Screenshot.ActualTime.Seconds:0:3, ' s');
end.
```

Screenshot extraction selects the first displayed frame at or after the requested
time and reports the actual timestamp. Returned metadata and image buffers remain
valid after the input closes.

### Convert audio or video

For MP3 to Ogg/Opus, the default preset produces 48 kHz stereo at 128 kbit/s:

```pascal
uses
  TFFmpeg.Media,
  TFFmpeg.Media.Convert;

var
  Converted: TMediaConversionResult;
begin
  Converted:=TFFmpegMedia.ConvertAudio('music.mp3', 'music.opus');
  WriteLn('Audio samples per channel: ', Converted.AudioSamples);
end;
```

For coordinated audio/video conversion, choose the output size and preset:

```pascal
uses
  TFFmpeg.Media,
  TFFmpeg.Media.Types,
  TFFmpeg.Media.Convert;

var
  Settings: TMediaAVConvertSettings;
  Converted: TMediaConversionResult;
begin
  Settings:=TMediaAVConvertSettings.H264OpusMatroska(
    1280, 720, TMediaRate.Create(30000, 1001));
  Converted:=TFFmpegMedia.ConvertFile('input.mp4', 'output.mkv', Settings);
  WriteLn('Video frames: ', Converted.VideoFrames);
end;
```

Video conversion preserves source timing by default. Set
`Settings.VideoTiming:=mvpConstantRate` to request constant-rate output. Use
`ConvertURL` for explicit HTTP/HTTPS input.

## Examples

Every high-level example is a complete console program using public units.

| Example | What it demonstrates |
| --- | --- |
| [MediaInfo](Examples/MediaInfo.dpr) | Inspect container and stream information |
| [ReadMedia](Examples/ReadMedia.dpr) | Read decoded audio/video with end, timeout and cancellation handling |
| [ReadURL](Examples/ReadURL.dpr) | Read HTTP/HTTPS input with an operation timeout |
| [GrabFrame](Examples/GrabFrame.dpr) | Save a screenshot as BMP, PNG or JPEG |
| [WriteSamples](Examples/WriteSamples.dpr) | Generate and write raw PCM audio |
| [ImagesToMP4](Examples/ImagesToMP4.dpr) | Turn still images into H.264 video with rational timing |
| [ConvertAudio](Examples/ConvertAudio.dpr) | Convert audio with progress and cancellation |
| [ConvertVideo](Examples/ConvertVideo.dpr) | Convert AV tracks with preserved timing or explicit CFR |
| [ListDevices](Examples/ListDevices.dpr) | Enumerate cameras, microphones and their modes |
| [CaptureDevice](Examples/CaptureDevice.dpr) | Consume live samples through bounded queues |
| [RecordDevice](Examples/RecordDevice.dpr) | Record video, audio or both; finish gracefully or cancel |

[DecodeAudio](Examples/DecodeAudio.dpr) demonstrates the lower-level wrappers
when you need direct control over native decoding and resampling.

### Camera and microphone recording

Build the device examples, then inspect the current device list:

```bash
./build.sh Examples/ListDevices.dpr Win64
./build.sh Examples/RecordDevice.dpr Win64
./Bin/win64/ListDevices.exe --modes
```

Pass the listed video and audio indexes to `RecordDevice`. For example, **if** your
camera is index `0` and microphone is index `2`:

```bash
./Bin/win64/RecordDevice.exe 0 2 10 recording.mkv
```

Use `-1` to disable a source: video-only recordings use H.264 MP4; audio-only
recordings use Ogg/Opus. Optional `--stop-after-ms 5000` finalizes queued media;
`--cancel-after-ms 5000` aborts without publishing output.

Application code uses `TFFmpeg.Media.Devices` and `TFFmpeg.Media.Recording`.
Importing the file-only facade does not add an `avdevice` dependency.

## API essentials

- **Start with defaults or a preset.** Use constructors such as
  `TMediaReaderSettings.Default` and `TMediaWriterSettings.H264MP4`; a zeroed
  settings record is not necessarily valid.
- **Samples own their data.** Audio/video samples are immutable, reference-counted
  interfaces. Retained samples survive subsequent reads, seeks and session closure.
- **Time is explicit.** `TMediaTime` distinguishes known, unknown and estimated
  timestamps; `TMediaRate` represents rational rates. Reader audio defaults to
  interleaved S16 at 48 kHz stereo, and video to BGRA32.
- **Finish output deliberately.** `IMediaWriter.Finish` drains encoders and publishes
  the file. `Abort` or destruction discards unfinished output. Overwriting is opt-in.
- **Handle read outcomes.** Readers distinguish samples, EOF, cancellation and
  timeout. Other failures use `EFFmpegMediaError` with an operation, category and
  optional native error code.
- **Stop capture before releasing it.** `Stop` cancels native reads and joins the
  worker. Preview can drop old video frames; recording reports queue overruns.
  Recording presets use explicitly estimated audio sample-clock timing with
  bounded native jitter and drift, while preserving variable video cadence.

The public entry points live in [TFFmpeg.Media](Source/TFFmpeg.Media.pas).
Reader, writer, image, conversion and device settings are declared in the
corresponding `TFFmpeg.Media.*` units. `TFFmpeg.Media.Internal.*` units are
implementation details.

For native integration, the `TFFmpeg.Input`, `.Decoder`, `.Encoder`, `.Output`,
`.AudioResampler`, `.VideoScaler` and `.StillImage` wrappers remain available.
Their native pointers and ownership rules differ from the high-level interfaces;
see the lower-level example before mixing APIs.

## Compatibility

| Target | Validation |
| --- | --- |
| **Delphi Win64** | Native tests and examples with compiler 36.0 and FFmpeg 9.0.2 |
| **Delphi Win32** | Native tests and examples with compiler 36.0 and the matching Win32 runtime |
| **FPC 3.2.2 / Linux** | Shared units and examples compile with `--no-link`; native Linux runtime support is not validated |
| **DirectShow devices** | Physical Logitech C922 camera/microphone tested on both Windows targets, including recording, busy access, USB disconnect and repeated stop/reopen |

The high-level capture backend requires Delphi on Windows. Device stop latency
and timestamp behavior depend on the driver. There is no automatic reconnect or
long-term clock-rate correction. H.264/AAC MP4 conversion rejects delayed audio
starts that the current preset cannot preserve; H.264/Opus Matroska supports
relative AV offsets. HDR tone mapping and hardware-accelerated decoding are outside
the high-level API's current scope.

## Build and test

The build scripts run from **WSL** with a licensed Delphi installation. Place all
seven matching DLLs in `Runtime/Win64/` or `Runtime/Win32/`; `build.sh` stages them
beside the executable in `Bin/`.

```bash
./build.sh Examples/MediaInfo.dpr Win64
./Bin/win64/MediaInfo.exe 'C:\Media\movie.mp4'

./build.sh Examples/MediaInfo.dpr Win32
./Bin/win32/MediaInfo.exe 'C:\Media\movie.mp4'
```

Arguments passed to Windows executables must use Windows-compatible paths.
`BDS_DIR` selects the RAD Studio installation using a WSL path; `BDS_VERSION`
defaults to `23.0`. Individual overrides are `DCC32`, `DCC64`,
`DELPHI_LIB_WIN32` and `DELPHI_LIB_WIN64`. You can also build the `.dpr` examples
in the Delphi IDE using the search paths above.

Run the media test suite and compile the examples:

```bash
./Tools/validate-media.sh Win64
./Tools/validate-media.sh Win32
./Tools/validate-media.sh fpc
```

The full suite needs Python 3, `flock`, OpenSSL and an FFmpeg CLI with the encoders
used by the [synthetic fixtures](Tests/Fixtures/README.md). Fixture hashes are
pinned to FFmpeg CLI 8.1.3, independently of the 9.0.2 library runtime under test.
Runs serialize access to shared fixtures. Tests cover timing, ownership, decoding,
encoding, publication, cancellation, HTTP/HTTPS and resource growth; physical
capture tests are opt-in and require selected devices.

For a standalone FPC compilation check without generating fixtures:

```bash
./build-fpc.sh Examples/MediaInfo.dpr --no-link
```

For a quick source check:

```bash
python3 Tools/test_media_tools.py
./Tools/check-code-style.sh
python3 Tools/check-media-boundary.py Tests/MediaContractCompile.dpr
```

See [migration and ABI validation](MIGRATION-9.0.2.md) for native header/export
checks and guidance when moving from FFmpeg 8.1.

## Repository layout

```text
Headers/     FFmpeg Pascal declarations
Source/      High-level media API and native wrappers
Examples/    Console programs for common workflows
Tests/       Smoke tests, hardware tests and synthetic fixture generators
Tools/       Validation tools and native runtime build scripts
Runtime/     Native library setup instructions
```

Native binaries, generated fixtures, build outputs and local development notes
are excluded from Git.

## License

The wrapper code is licensed under [BSD 2-Clause](LICENSE). Translated headers
retain their original notices. FFmpeg and optional codec libraries have separate
licenses determined by the runtime build; see [third-party notices](THIRD_PARTY_NOTICES.md)
and the [runtime guide](Runtime/README.md).
