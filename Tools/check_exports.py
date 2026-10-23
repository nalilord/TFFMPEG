#!/usr/bin/env python3
"""Audit declared native imports against a runtime's export tables.

Checks public imports after resolving FF_API_* guards from libversion.inc.
Other platform/compiler branches are both inspected. Historical internal-only
units are excluded because standard shared FFmpeg builds do not export them.
"""
from pathlib import Path
import re
import subprocess
import sys
root = Path(__file__).resolve().parent.parent
arch = sys.argv[1] if len(sys.argv)>1 else 'Win64'
names = {'AVCODEC':'avcodec-63','AVFORMAT':'avformat-63','AVUTIL':'avutil-61',
         'AVDEVICE':'avdevice-63','AVFILTER':'avfilter-12','SWRESAMPLE':'swresample-7','SWSCALE':'swscale-10'}
exports = {}
for lib, name in names.items():
    text = subprocess.check_output(['objdump','-p',str(root/'Runtime'/arch/(name+'.dll'))], text=True)
    exports[lib] = set(re.findall(r'^\s*\[\s*\d+\].*\s([A-Za-z_]\w*)\s*$',text,re.M))
    if not exports[lib]:
        raise RuntimeError(f'No exports parsed from {name}')
api_flags = set(re.findall(r'\{\$DEFINE\s+(FF_API_\w+)\}',
                          (root/'Headers/libversion.inc').read_text(), re.I))
def public_source(source):
    stack = []
    enabled = True
    result = []
    for part in re.split(r'(\{\$(?:IFDEF|IFNDEF|IF|ELSE|ENDIF|IFEND)\b[^}]*\})', source, flags=re.I):
        directive = re.match(r'\{\$(IFDEF|IFNDEF|IF|ELSE|ENDIF|IFEND)\b\s*(.*?)\}', part, re.I)
        if not directive:
            if enabled:
                result.append(part)
            continue
        kind, condition = directive.groups()
        kind = kind.upper()
        if kind in ('IFDEF', 'IFNDEF', 'IF'):
            known = condition.startswith('FF_API_') and kind != 'IF'
            value = (condition in api_flags) if kind == 'IFDEF' else (condition not in api_flags)
            stack.append((enabled, known, value))
            enabled = enabled and (value if known else True)
        elif kind == 'ELSE':
            parent, known, value = stack[-1]
            enabled = parent and (not value if known else True)
        else:
            enabled = stack.pop()[0]
    return ''.join(result)

count = 0
missing = []
for path in sorted((root/'Headers').glob('*.pas')):
    if path.stem in ('libavfilter_formats', 'libavformat_url'):
        continue
    for m in re.finditer(r"external (\w+)_LIBNAME name _PU \+ '([^']+)'",public_source(path.read_text())):
        lib, symbol = m.groups()
        if lib in exports:
            count += 1
            if symbol not in exports[lib]:
                missing.append(f'{path.name}: {symbol}')
if missing:
    raise SystemExit('\n'.join(missing))
print(f'PASS {arch}: {count} public native imports exported (FF_API guards resolved).')
