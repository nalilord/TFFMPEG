#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_REL="${1:-Examples/DecodeAudio.dpr}"
PLATFORM="${2:-${DELPHI_PLATFORM:-Win64}}"
BDS_VERSION="${BDS_VERSION:-23.0}"
# BDS_DIR is a WSL path; the default is the standard Windows installation.
BDS_DIR="${BDS_DIR:-$(wslpath -u 'C:\Program Files (x86)\Embarcadero\Studio')/$BDS_VERSION}"
case "$PLATFORM" in
  Win64|win64)
    PLATFORM=Win64
    PLATFORM_DIR=win64
    DCC="${DCC64:-${BDS_DIR}/bin/dcc64.exe}"
    DELPHI_LIB="${DELPHI_LIB_WIN64:-$(wslpath -w "$BDS_DIR/lib/win64/release")}"
    ;;
  Win32|win32)
    PLATFORM=Win32
    PLATFORM_DIR=win32
    DCC="${DCC32:-${BDS_DIR}/bin/dcc32.exe}"
    DELPHI_LIB="${DELPHI_LIB_WIN32:-$(wslpath -w "$BDS_DIR/lib/win32/release")}"
    ;;
  *) printf 'Use Win32 or Win64.\n' >&2; exit 1 ;;
esac

PROJECT_PATH="$ROOT/${PROJECT_REL#./}"
if [[ ! -f "$PROJECT_PATH" || ! -x "$DCC" ]]; then
  printf 'Project or compiler not found: %s / %s\n' "$PROJECT_PATH" "$DCC" >&2
  exit 1
fi
OUT_DIR="$ROOT/Bin/$PLATFORM_DIR"
mkdir -p "$OUT_DIR/Units"
PROJECT_DIR="$(dirname "$PROJECT_PATH")"
SOURCE_WIN="$(wslpath -w "$ROOT/Source")"
HEADERS_WIN="$(wslpath -w "$ROOT/Headers")"
PROJECT_WIN="$(wslpath -w "$PROJECT_DIR")"
OUT_WIN="$(wslpath -w "$OUT_DIR")"
UNITS_WIN="$(wslpath -w "$OUT_DIR/Units")"
cd "$PROJECT_DIR"
"$DCC" -B \
  -U"$PROJECT_WIN;$SOURCE_WIN;$HEADERS_WIN;$DELPHI_LIB" \
  -I"$HEADERS_WIN" \
  '-NSSystem;Winapi' \
  -N0"$UNITS_WIN" -NU"$UNITS_WIN" -E"$OUT_WIN" \
  "$(basename "$PROJECT_PATH")"

# Stage all libraries so raw API tests and examples can use the complete binding.
for dll in avcodec-63 avformat-63 avutil-61 swresample-7 avfilter-12 avdevice-63 swscale-10; do
  if [[ ! -f "$ROOT/Runtime/$PLATFORM/$dll.dll" ]]; then
    printf 'Missing runtime: %s\n' "$ROOT/Runtime/$PLATFORM/$dll.dll" >&2
    exit 1
  fi
  cp -p "$ROOT/Runtime/$PLATFORM/$dll.dll" "$OUT_DIR/$dll.dll"
done
printf 'Built %s for %s in %s\n' "$PROJECT_REL" "$PLATFORM" "$OUT_DIR"
