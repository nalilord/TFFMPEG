#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${LLVM_MINGW_DIR:?Set LLVM_MINGW_DIR to an extracted LLVM-MinGW toolchain}"
printf '%s  %s\n' \
  '6e374ed621e48faa40639307dff48ba6fe574a509977956d2cce9669b7cc27e9' \
  "$ROOT/Downloads/ffmpeg-n9.0.2.tar.gz" | sha256sum -c -
BUILD_ROOT="${FFMPEG_BUILD_ROOT:-$(mktemp -d -t tffmpeg-win32-XXXXXX)}"
mkdir -p "$BUILD_ROOT/source" "$BUILD_ROOT/build" "$BUILD_ROOT/install"
tar -xzf "$ROOT/Downloads/ffmpeg-n9.0.2.tar.gz" -C "$BUILD_ROOT/source" --strip-components=1
export PATH="$LLVM_MINGW_DIR/bin:$PATH"
EXTRA_CONFIGURE=()
EXTRA_CFLAGS=()
EXTRA_LDFLAGS=()
if [[ -n "${ZLIB_ROOT:-}" ]]; then
  if [[ ! -f "$ZLIB_ROOT/lib/libz.a" || ! -f "$ZLIB_ROOT/include/zlib.h" ]]; then
    printf 'ZLIB_ROOT must contain static lib/libz.a and include/zlib.h.\n' >&2
    exit 1
  fi
  EXTRA_CONFIGURE+=(--enable-zlib)
  EXTRA_CFLAGS+=("-I$ZLIB_ROOT/include")
  EXTRA_LDFLAGS+=("-L$ZLIB_ROOT/lib")
fi
if [[ -n "${CODECS_ROOT:-}" ]]; then
  if [[ ! -f "$CODECS_ROOT/lib/libx264.a" || ! -f "$CODECS_ROOT/lib/libopus.a" ]]; then
    printf 'CODECS_ROOT must contain static libx264.a and libopus.a.\n' >&2
    exit 1
  fi
  # x264 is optional and changes this FFmpeg build to GPL. Default stays LGPL.
  export PKG_CONFIG_LIBDIR="$CODECS_ROOT/lib/pkgconfig"
  EXTRA_CONFIGURE+=(--enable-gpl --enable-libx264 --enable-libopus --pkg-config=pkg-config --pkg-config-flags=--static)
  EXTRA_CFLAGS+=("-I$CODECS_ROOT/include")
  EXTRA_LDFLAGS+=("-L$CODECS_ROOT/lib")
fi
EXTRA_CONFIGURE+=("--extra-cflags=${EXTRA_CFLAGS[*]}" "--extra-ldflags=${EXTRA_LDFLAGS[*]}")
cd "$BUILD_ROOT/build"
"$BUILD_ROOT/source/configure" \
  --prefix="$BUILD_ROOT/install" --target-os=mingw32 --arch=x86 \
  --enable-cross-compile --cross-prefix=i686-w64-mingw32- \
  --cc=i686-w64-mingw32-clang --cxx=i686-w64-mingw32-clang++ \
  --ar=llvm-ar --nm=llvm-nm --ranlib=llvm-ranlib --strip=llvm-strip \
  --enable-shared --disable-static --disable-programs --disable-doc \
  --disable-debug --disable-autodetect --enable-schannel "${EXTRA_CONFIGURE[@]}"
make -j"${JOBS:-8}"
make install
printf 'Runtime and matching development files: %s/install\n' "$BUILD_ROOT"
