#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${LLVM_MINGW_DIR:?Set LLVM_MINGW_DIR to the extracted LLVM-MinGW toolchain}"
ARCHIVE="${ZLIB_ARCHIVE:-$ROOT/Downloads/zlib-1.3.2.tar.xz}"
printf '%s  %s\n' \
  'd7a0654783a4da529d1bb793b7ad9c3318020af77667bcae35f95d0e42a792f3' "$ARCHIVE" | sha256sum -c -
BUILD_ROOT="${ZLIB_BUILD_ROOT:-$(mktemp -d -t tffmpeg-zlib-win32-XXXXXX)}"
mkdir -p "$BUILD_ROOT/source" "$BUILD_ROOT/install"
tar -xJf "$ARCHIVE" -C "$BUILD_ROOT/source" --strip-components=1
export PATH="$LLVM_MINGW_DIR/bin:$PATH"
cd "$BUILD_ROOT/source"
CHOST=i686-w64-mingw32 CC=i686-w64-mingw32-clang AR=llvm-ar RANLIB=llvm-ranlib \
  ./configure --static --prefix="$BUILD_ROOT/install"
make -j"${JOBS:-8}" libz.a
make install
printf 'Static zlib and headers: %s/install\n' "$BUILD_ROOT"
