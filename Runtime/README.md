# FFmpeg runtime setup

This source-only repository does not distribute FFmpeg binaries. Install matching
FFmpeg 9.0.2 shared libraries separately. DLL directories, downloaded archives and
native build outputs are ignored by Git.

| Library | Windows DLL | Version |
| --- | --- | --- |
| avcodec | avcodec-63.dll | 63.1.102 |
| avformat | avformat-63.dll | 63.1.102 |
| avutil | avutil-61.dll | 61.1.102 |
| swresample | swresample-7.dll | 7.1.102 |
| avdevice | avdevice-63.dll | 63.1.102 |
| avfilter | avfilter-12.dll | 12.1.102 |
| swscale | swscale-10.dll | 10.1.102 |

Place the seven DLLs under `Runtime/Win64/` or `Runtime/Win32/` for `build.sh` to
stage them beside executables. An application using only audio wrappers normally
needs the first four libraries. Other APIs require their own libraries and any
transitive dependencies. Never mix architectures or ABI versions.

## Win64 reference package

The bindings have been tested with the Gyan full shared release:
[FFmpeg 9.0.2 full shared](https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-full_build-shared.7z).
Extract its `bin/*.dll` files into `Runtime/Win64/`. Keep the provider's license,
configuration and source information when deploying its binaries. This package
is GPL v3 and includes optional external codecs/filters.

Archive SHA-256:
`4d2060a8b34a940aa47d785142055bb92a63053781e55f2ace4546edd519a8f5`

## Win32 build recipe

`Tools/build-runtime-win32.sh` builds upstream tag `n9.0.2` using LLVM-MinGW, native
Windows Schannel HTTPS and built-in codecs/filters. External codec libraries are
disabled by default. This default configuration is LGPL v2.1 or later and uses Windows/UCRT system
libraries without GCC/LLVM runtime DLLs. Its optional codec/filter coverage differs
from the Win64 reference package. Older Windows releases are not qualified here.

Download the source archive to `Downloads/ffmpeg-n9.0.2.tar.gz`:
[FFmpeg n9.0.2 source](https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n9.0.2.tar.gz).

Source archive SHA-256, checked by the build script:
`6e374ed621e48faa40639307dff48ba6fe574a509977956d2cce9669b7cc27e9`

The reference toolchain is
[LLVM-MinGW UCRT 20261020](https://github.com/mstorsjo/llvm-mingw/releases/download/20261020/llvm-mingw-20261020-ucrt-ubuntu-22.04-x86_64.tar.xz).

Toolchain archive SHA-256:
`55064b60b991a1e1e8090b8c2f84e82b22cfe5903d12c159d65064cf5e8ae335`

From WSL with GNU make and tar installed:

```bash
LLVM_MINGW_DIR=/path/to/llvm-mingw ./Tools/build-runtime-win32.sh
```

The script prints its installation directory. Copy the seven `install/bin/*.dll`
files into `Runtime/Win32/`. Use `install/include/` for Win32 ABI checks. Keep the
source, build configuration and license materials with your binary-distribution
records. `JOBS` controls build concurrency; `FFMPEG_BUILD_ROOT` overrides the
otherwise temporary build location.

### Win32 PNG support

Enable static zlib 1.3.2 to include the built-in PNG decoder and encoder.
PNG is required by the image examples and tests. No additional zlib DLL is needed.

Obtain `zlib-1.3.2.tar.xz` from zlib upstream or a distribution source cache.
The recipe checks SHA-256:
`d7a0654783a4da529d1bb793b7ad9c3318020af77667bcae35f95d0e42a792f3`.
Retain zlib's LICENSE with build records.

```bash
LLVM_MINGW_DIR=/path/to/llvm-mingw \
  ZLIB_ARCHIVE=/path/to/zlib-1.3.2.tar.xz \
  ZLIB_BUILD_ROOT=/tmp/tffmpeg-zlib-win32 \
  ./Tools/build-zlib-win32.sh
LLVM_MINGW_DIR=/path/to/llvm-mingw \
  ZLIB_ROOT=/tmp/tffmpeg-zlib-win32/install \
  ./Tools/build-runtime-win32.sh
```

Stage all seven matching DLLs together after successful building. This remains
an FFmpeg n9.0.2 build with the same pinned library ABI versions. zlib is statically
linked; its license is additional to the FFmpeg/runtime licenses. The general media facade requires avcodec,
avformat, avutil, swresample and swscale; it does not import avdevice or avfilter.
PNG availability alone does not establish H.264/Opus or device support.

### Win32 H.264 and Opus support

The optional codec recipe builds static x264 (core 164, source commit
`4613ac3c15fd75cebc4b9f65b7fb95e70a3acce1`) and Opus 1.5.2. This variant enables
`--enable-gpl --enable-libx264 --enable-libopus` and is **GPL v2 or later**,
with the external libraries' notices retained. The script's default build remains
LGPL. No x264/Opus runtime DLL is required. Use the same LLVM-MinGW toolchain
and zlib build above. x264 assembly is disabled in this portable 32-bit recipe.

Obtain the upstream source tarballs (or distribution source-cache copies):

| Archive | SHA-256 |
| --- | --- |
| x264-0.0.20240513.tar.bz2 | `2a1b197fd1fbc85045794f18c9353648a9ae3cbe194b7b92d523d096f9445464` |
| opus-1.5.2.tar.gz | `65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1` |

`Tools/build-codecs-win32.sh` checks the pinned SHA-256 values before extraction.
Retain x264's COPYING and Opus's COPYING/AUTHORS files.

```bash
LLVM_MINGW_DIR=/path/to/llvm-mingw \
  X264_ARCHIVE=/path/to/x264-0.0.20240513.tar.bz2 \
  OPUS_ARCHIVE=/path/to/opus-1.5.2.tar.gz \
  CODECS_BUILD_ROOT=/tmp/tffmpeg-codecs-win32 \
  ./Tools/build-codecs-win32.sh
LLVM_MINGW_DIR=/path/to/llvm-mingw \
  ZLIB_ROOT=/tmp/tffmpeg-zlib-win32/install \
  CODECS_ROOT=/tmp/tffmpeg-codecs-win32/install \
  ./Tools/build-runtime-win32.sh
```

Stage all seven rebuilt DLLs together. Native Win32 writer tests use this variant;
Win64 uses the full GPL package above. Dedicated H.264/AAC/Opus tests fail if a
required encoder is missing. Windows camera/microphone capture uses the DirectShow
backend in avdevice; applications must import the device units explicitly.

## Other platforms

The headers include Linux/macOS library-name conventions. Install native libraries
with the matching ABI and follow the platform's dynamic-loader requirements.
FPC no-link validation alone does not establish native runtime compatibility.

See [third-party notices](../THIRD_PARTY_NOTICES.md) for license boundaries.
