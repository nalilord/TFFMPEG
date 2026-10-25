#!/usr/bin/env bash
set -euo pipefail
: "${LLVM_MINGW_DIR:?Set LLVM_MINGW_DIR to an extracted LLVM-MinGW toolchain}"
: "${X264_ARCHIVE:?Set X264_ARCHIVE to x264-0.0.20240513.tar.bz2}"
: "${OPUS_ARCHIVE:?Set OPUS_ARCHIVE to opus-1.5.2.tar.gz}"
printf '%s  %s\n' \
  '2a1b197fd1fbc85045794f18c9353648a9ae3cbe194b7b92d523d096f9445464' "$X264_ARCHIVE" \
  '65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1' "$OPUS_ARCHIVE" | sha256sum -c -
BUILD_ROOT="${CODECS_BUILD_ROOT:-$(mktemp -d -t tffmpeg-codecs-win32-XXXXXX)}"
mkdir -p "$BUILD_ROOT/x264" "$BUILD_ROOT/opus" "$BUILD_ROOT/install"
tar -xjf "$X264_ARCHIVE" -C "$BUILD_ROOT/x264" --strip-components=1
tar -xzf "$OPUS_ARCHIVE" -C "$BUILD_ROOT/opus" --strip-components=1
export PATH="$LLVM_MINGW_DIR/bin:$PATH"
export CC=i686-w64-mingw32-clang AR=llvm-ar RANLIB=llvm-ranlib STRIP=llvm-strip
cd "$BUILD_ROOT/x264"
./configure --host=i686-w64-mingw32 --cross-prefix=i686-w64-mingw32- \
  --prefix="$BUILD_ROOT/install" --enable-static --disable-cli --disable-opencl \
  --disable-asm --bit-depth=8 --chroma-format=420
make -j"${JOBS:-8}"
make install
cd "$BUILD_ROOT/opus"
./configure --host=i686-w64-mingw32 --prefix="$BUILD_ROOT/install" \
  --disable-shared --enable-static --disable-extra-programs --disable-doc
make -j"${JOBS:-8}"
make install
printf 'Static x264 (GPL) and Opus: %s/install\n' "$BUILD_ROOT"
