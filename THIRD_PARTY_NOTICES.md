# Third-party notices

## Pascal headers

`Headers/` contains FFmpeg Pascal translations based on DelphiFFmpeg.com, updated
to target FFmpeg 9.0.2. The original per-file copyrights, redistribution conditions
and disclaimers are retained. Some files also retain FFmpeg's upstream LGPL
notices. The wrapper license does not replace these notices.

Original translation source: [DelphiFFmpeg.com](http://www.delphiffmpeg.com).

## FFmpeg

The library interfaces with FFmpeg. FFmpeg binaries are not distributed in this
repository. Their applicable license and dependencies depend on the selected
build. The documented Win64 reference package is GPL v3; the documented Win32
configuration is LGPL v2.1 or later without external codec libraries.

[Runtime setup](Runtime/README.md) provides version requirements, source/toolchain
links and the Win32 build recipe. Retain upstream license and source materials
when distributing native binaries.

Upstream project: [FFmpeg](https://ffmpeg.org/).
Licensing information: [FFmpeg legal information](https://ffmpeg.org/legal.html).

## Wrapper code

The `Source/TFFmpeg.*` wrapper units are covered by the BSD 2-Clause notice in
[LICENSE](LICENSE). That license does not relicense the header translations or
native FFmpeg libraries.
