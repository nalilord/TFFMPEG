#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-Win64}"
cd "$ROOT"
case "$TARGET" in
  Win64) OUTPUT=win64 ;;
  Win32) OUTPUT=win32 ;;
  fpc) OUTPUT=linux ;;
  *) printf 'Use Win64, Win32 or fpc (no-link).\n' >&2; exit 1 ;;
esac
# Targets share generated fixtures. Hold one workspace lock through generation
# and runtime reads, so another validation cannot truncate an active fixture.
mkdir -p "$ROOT/Bin"
exec 9>"$ROOT/Bin/.media-validation.lock"
flock 9
python3 Tools/test_media_tools.py
./Tools/check-code-style.sh
python3 Tools/check-media-boundary.py Tests/MediaContractCompile.dpr
python3 Tests/Fixtures/generate-media.py
python3 Tests/Fixtures/generate-reader.py
FAILED=0
for project in Tests/Media*Smoke.dpr Tests/MediaContractCompile.dpr; do
  if [[ "$TARGET" == fpc ]]; then
    ./build-fpc.sh "$project" --no-link || FAILED=1
  else
    if ./build.sh "$project" "$TARGET"; then
      executable="./Bin/$OUTPUT/$(basename "${project%.dpr}").exe"
      if [[ "$(basename "$project")" == MediaURLSmoke.dpr ]]; then
        python3 Tools/run-media-url-tests.py "$executable" || FAILED=1
      else
        "$executable" || FAILED=1
      fi
    else
      FAILED=1
    fi
  fi
done
for project in Examples/*.dpr; do
  [[ "$(basename "$project")" == DecodeAudio.dpr ]] && continue
  if [[ "$TARGET" == fpc ]]; then
    ./build-fpc.sh "$project" --no-link || FAILED=1
  else
    ./build.sh "$project" "$TARGET" || FAILED=1
  fi
done
exit "$FAILED"
