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
cd "$BUILD_ROOT/build"
"$BUILD_ROOT/source/configure" \
  --prefix="$BUILD_ROOT/install" --target-os=mingw32 --arch=x86 \
  --enable-cross-compile --cross-prefix=i686-w64-mingw32- \
  --cc=i686-w64-mingw32-clang --cxx=i686-w64-mingw32-clang++ \
  --ar=llvm-ar --nm=llvm-nm --ranlib=llvm-ranlib --strip=llvm-strip \
  --enable-shared --disable-static --disable-programs --disable-doc \
  --disable-debug --disable-autodetect --enable-schannel
make -j"${JOBS:-8}"
make install
printf 'Runtime and matching development files: %s/install\n' "$BUILD_ROOT"
