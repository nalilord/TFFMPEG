# FFmpeg 9.0.2 migration

The bindings target FFmpeg 9.0.2. Native binaries, older source snapshots and local
build artifacts are not included in this repository. Applications migrating from
8.1 must rebuild all Pascal units and deploy matching native libraries.

## Binding changes

- Updated all seven library versions, library names and deprecation guards.
- Removed obsolete codec capability fields and filter/parser internals. Use
  `avcodec_get_supported_config` instead of old `AVCodec` capability arrays.
- Synchronized codec IDs and packet/frame side-data enums. Removed codec IDs
  change subsequent numeric values; do not reuse units compiled against 8.1.
- Added layered-video/TREF stream groups, program-copy APIs and new swscale
  settings, retaining the upstream LCEVC compatibility alias.
- Corrected alpha-mode fields, tile-grid side data, filter-format configuration,
  format-context name, color enums and the pointer return of `sws_getCoefficients`.
- Removed unavailable native imports. Declarations under disabled `FF_API_*`
  guards are not available to callers.

## Validation tools

The Windows ABI probe compares Delphi declarations with matching C development
headers using LLVM-MinGW and a Delphi installation. Run from WSL:

```bash
python3 Tools/check_abi.py --arch Win64 \
  --toolchain /path/to/llvm-mingw --include /path/to/ffmpeg/include \
  --bds-dir /path/to/rad-studio
python3 Tools/check_abi.py --arch Win32 \
  --toolchain /path/to/llvm-mingw --include /path/to/win32-ffmpeg/include \
  --bds-dir /path/to/rad-studio
python3 Tools/check_exports.py Win64
python3 Tools/check_exports.py Win32
```

`BDS_DIR` can replace `--bds-dir`. Each target requires the matching architecture's
C headers/configuration. Generated probes and results go under ignored `Bin/`.
The export audit reads DLLs installed under `Runtime/Win32` and `Runtime/Win64`.

The reference comparison covers 37 core record sizes, 612 named field offsets
and 1,228 enum values on each Windows architecture. The export audit checks 793
public native imports after resolving `FF_API_*` guards. These checks cover the
selected public declarations, not every translated record or feature. Internal
`libavfilter_formats` and `libavformat_url` declarations are excluded from the
public export audit and are unsupported by standard shared runtimes.

Smoke-test commands and their coverage are in [README.md](README.md). Native Linux
ABI behavior, hardware acceleration and older Windows releases require separate
qualification for each application's supported platforms.

## Version isolation

Keep an older binding and its matching native binaries together when maintaining
an older application. Select one version's source/include paths and deployment
files, then rebuild all units. Never combine 8.1 record layouts with 9.0.2 DLLs.
