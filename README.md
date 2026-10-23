# TFFMPEG

Delphi/Pascal bindings and reusable wrappers for **FFmpeg 9.0.2**. The library
provides input, decoding, encoding, audio resampling, software video scaling and
still-image helpers. Use the source units directly in a console, desktop or
service application.

This repository contains source code only. Install matching FFmpeg shared
libraries separately; see [runtime setup](Runtime/README.md). The wrapper API does
not implement a player, output devices, a media graph or a complete transcoder.

## Contents

| Location | Purpose |
| --- | --- |
| `Headers/` | Pascal declarations for codec, format, utility, filter, device, resampling and scaling APIs |
| `Source/TFFmpeg.Input.pas` | Owned file/URL input, stream discovery, stream selection and packet reading |
| `Source/TFFmpeg.Decoder.pas` | Decoder context and send/receive lifecycle |
| `Source/TFFmpeg.Encoder.pas` | Encoder allocation, configuration, opening and send/receive lifecycle |
| `Source/TFFmpeg.AudioResampler.pas` | Packed PCM conversion with an owned reusable output buffer |
| `Source/TFFmpeg.VideoScaler.pas` | Software-frame scaling into independently owned storage |
| `Source/TFFmpeg.StillImage.pas` | Local BMP/PNG/JPEG decoding and opaque BMP encoding |
| `Source/TFFmpeg.Api.pas`, `TFFmpeg.Utils.pas`, `TFFmpeg.Resample.pas` | Allocation, error, dictionary, network and resampling helpers |
| `Examples/` | Standalone audio decoding example |
| `Tests/` | Audio, encoder, native API and video-scaling smoke tests |
| `Tools/` | ABI comparison, export audit and a Win32 runtime build recipe |

## Integration

Add these directories, relative to your checkout, to the Delphi unit search path:

```text
Source
Headers
```

Add `Headers` to the include path. Rebuild all units when changing the binding or
FFmpeg ABI version. Deploy the matching architecture's DLLs beside the executable.
Audio wrappers require `avcodec-63.dll`, `avformat-63.dll`, `avutil-61.dll` and
`swresample-7.dll`; other APIs need their additional libraries and dependencies.

Start with:

```pascal
uses
  TFFmpeg.Input,
  TFFmpeg.Decoder,
  TFFmpeg.AudioResampler;
```

[DecodeAudio.dpr](Examples/DecodeAudio.dpr) demonstrates the complete lifecycle:
open input, open the selected decoder, configure resampling, read packets, send
selected packets, receive decoded frames and convert them to PCM. At EOF, send a
nil packet, receive remaining decoder output, then flush the resampler until empty.
The example counts output bytes without opening an audio device.

## Ownership and error handling

- Integer status results use FFmpeg's negative error codes. Check every result;
  `TFFmpeg.Utils.FFmpegErrorText` produces a readable message.
- Input objects own their format contexts. Stream and codec-parameter pointers
  remain valid while the input is open. Decoder/encoder objects own their contexts.
- Callers own packets, frames and option dictionaries. FFmpeg consumes recognized
  options; free the remaining dictionary with `av_dict_free`.
- Unreference packets and frames between uses, then free them at shutdown.
- Resampler output is borrowed memory, valid until the next conversion, flush,
  close or destruction. Copy it when longer ownership is needed.
- High-level audio output is packed/interleaved. Planar output formats are rejected;
  use the low-level resampling API when planar output is required.
- Use separate instances per worker and stop workers before destroying objects.
- `Decoder.Flush` sends an end-of-input packet. It is not a seeking/reset operation.

`Input.OpenFile` treats its argument as a literal local filename using owned custom
file I/O. It restricts I/O and demuxer access to the file protocol; callers can add
`format_whitelist` restrictions. Its interrupt callback and opaque state are
borrowed until close. `Input.Open` remains the general file/URL API.

## Encoding, scaling and still images

For encoding, call `Allocate(codecID)`, configure `CodecContext`, then `Open`.
A failed open frees the context; allocate again before retrying. Send frames and
receive packets until EAGAIN. When sending returns EAGAIN, receive output and retry
the same unconsumed frame. Send nil to start draining, retrying after output if
necessary, then receive until EOF. Configure timestamps, frame sizes, padding and
muxing in the application; do not modify a successfully opened context.

`TFFmpegVideoScaler.Scale` borrows a software frame and returns a caller-owned
frame. It bounds allocations to 64 million pixels and uses area scaling by default.
Timing is retained; source color-space tags are not copied onto converted RGB data.

`TFFmpegStillImage.DecodeFile` accepts literal local BMP/PNG/JPEG files, rejects
other demuxers and requires exactly one decoded frame. Returned frame storage is
caller-owned. An optional native interrupt callback is borrowed during decoding.
`EncodeBMP` scales and composites straight alpha onto an explicit RGB background,
then encodes opaque 24-bit BMP bytes. EXIF orientation, ICC processing and file
publication are outside these helpers.

## Build and test

From WSL with a licensed Delphi installation and matching runtimes installed:

```bash
./build.sh Examples/DecodeAudio.dpr Win64
./build.sh Tests/FFmpegSmoke.dpr Win64
./Bin/win64/FFmpegSmoke.exe
./build.sh Tests/EncoderSmoke.dpr Win64
./Bin/win64/EncoderSmoke.exe
./build.sh Tests/FFmpegAPISmoke.dpr Win64
./Bin/win64/FFmpegAPISmoke.exe
./build.sh Tests/VideoScalerSmoke.dpr Win64
./Bin/win64/VideoScalerSmoke.exe
```

Use `Win32` for a 32-bit target. `build.sh` copies the seven runtime DLLs from
`Runtime/Win64` or `Runtime/Win32` to the output directory. These directories are
ignored by Git and are not included in a clone.

`BDS_DIR` selects the RAD Studio installation using a WSL path. Otherwise,
`BDS_VERSION` selects a version under the standard Windows installation directory
(default `23.0`). `DCC32`, `DCC64`, `DELPHI_LIB_WIN32` and `DELPHI_LIB_WIN64` override
individual compiler/library paths. The scripts only build this repository.

For FPC syntax/unit checks without native Linux FFmpeg libraries:

```bash
./build-fpc.sh Examples/DecodeAudio.dpr --no-link
./build-fpc.sh Tests/FFmpegSmoke.dpr --no-link
```

Omit `--no-link` when compatible FFmpeg libraries and linker dependencies are
installed. A no-link build does not validate the native Linux ABI or playback.

The tests cover input failure/reopen, decoding/draining, non-silent resampling,
encoder backpressure and lifecycle, native library versions, codec IDs, filters,
program copying, known pixel values, scaling ownership/bounds and BMP layout/alpha
compositing. They do not certify every codec, device or hardware-acceleration path.

See [migration and ABI validation](MIGRATION-9.0.2.md) for changes from 8.1.
The historical `libavfilter_formats` and `libavformat_url` units describe internal
APIs not exported by standard shared builds; use the corresponding public APIs.

## Licensing

The wrapper license is [BSD 2-Clause](LICENSE). Header files retain their original
copyright and license notices. FFmpeg runtime licensing is separate and depends on
the chosen build; see [third-party notices](THIRD_PARTY_NOTICES.md).
