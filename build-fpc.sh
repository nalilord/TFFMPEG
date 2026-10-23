#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${1:-Examples/DecodeAudio.dpr}"
shift || true
EXTRA_FLAGS=()
for arg in "$@"; do
  case "$arg" in
    --no-link) EXTRA_FLAGS+=(-Cn) ;;
    *) EXTRA_FLAGS+=("$arg") ;;
  esac
done
mkdir -p "$ROOT/Bin/linux" "$ROOT/Bin/linux/Units"
fpc -B -Mdelphi -Fu"$ROOT/Source" -Fu"$ROOT/Headers" -Fi"$ROOT/Headers" \
  -FE"$ROOT/Bin/linux" -FU"$ROOT/Bin/linux/Units" \
  "${EXTRA_FLAGS[@]}" "$ROOT/$PROJECT"
