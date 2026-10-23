#!/usr/bin/env python3
"""Show non-comment upstream changes for the C headers represented by this binding."""
import difflib
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parent.parent
old, new = map(Path, sys.argv[1:3])
def clean(path):
    data = re.sub(r'/\*.*?\*/', '', path.read_text(), flags=re.S)
    data = re.sub(r'//[^\n]*', '', data)
    return [line.strip() for line in data.splitlines() if line.strip()]

for pas in sorted((root / 'Headers').glob('lib*.pas')):
    lib, _, stem = pas.stem.partition('_')
    name = stem or lib.removeprefix('lib')
    if pas.stem == 'libavcodec_codec_defs':
        name = 'defs'
    rel = Path(lib) / (name + '.h')
    if (old / rel).exists() and (new / rel).exists():
        delta = list(difflib.unified_diff(clean(old / rel), clean(new / rel),
                     fromfile=str(rel), tofile=str(rel), n=2))
        if delta:
            print('\n'.join(delta))
