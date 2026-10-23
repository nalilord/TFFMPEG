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
disabled. This configuration is LGPL v2.1 or later and uses Windows/UCRT system
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

## Other platforms

The headers include Linux/macOS library-name conventions. Install native libraries
with the matching ABI and follow the platform's dynamic-loader requirements.
FPC no-link validation alone does not establish native runtime compatibility.

See [third-party notices](../THIRD_PARTY_NOTICES.md) for license boundaries.
