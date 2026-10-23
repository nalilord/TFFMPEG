#!/usr/bin/env python3
"""Compare Delphi layouts/enums to the matching installed C headers on Windows.

Requires LLVM-MinGW, Delphi/WSL, and the FFmpeg development headers. Generated
probes go in Bin/abi-<arch>; neither probe depends on FFmpeg DLLs.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--toolchain', type=Path, required=True)
p.add_argument('--include', type=Path, required=True)
p.add_argument('--arch', choices=['Win64','Win32'], default='Win64')
p.add_argument('--bds-dir', type=Path, default=os.environ.get('BDS_DIR'),
               help='RAD Studio installation directory in WSL (or set BDS_DIR)')
a = p.parse_args()
if a.bds_dir is None:
    p.error('Set --bds-dir or BDS_DIR to the RAD Studio installation directory')
root = Path(__file__).resolve().parent.parent
out = root/'Bin'/('abi-'+a.arch.lower())
out.mkdir(parents=True, exist_ok=True)
units = ['libavcodec','libavcodec_codec','libavcodec_codec_par','libavcodec_codec_id',
         'libavcodec_codec_defs','libavcodec_packet','libavformat','libavformat_avio',
         'libavutil','libavutil_frame','libavutil_buffer','libavutil_channel_layout',
         'libavutil_dict','libavutil_rational','libavutil_log','libavutil_opt',
         'libavutil_hwcontext','libavutil_pixfmt','libavutil_samplefmt',
         'libavfilter','libavfilter_buffersrc','libavfilter_buffersink','libswscale']
headers = ['libavcodec/avcodec.h','libavformat/avformat.h','libavutil/frame.h',
           'libavutil/opt.h','libavutil/hwcontext.h','libavfilter/avfilter.h',
           'libavfilter/buffersrc.h','libavfilter/buffersink.h','libswscale/swscale.h']
types = ['AVRational','AVPacket','AVPacketSideData','AVFrame','AVFrameSideData',
         'AVCodec','AVCodecParameters','AVCodecContext','AVCodecParser','AVCodecParserContext',
         'AVBufferRef','AVChannelLayout','AVChannelCustom','AVDictionaryEntry',
         'AVClass','AVOption','AVIOContext','AVIOInterruptCB','AVFormatContext',
         'AVInputFormat','AVOutputFormat','AVStream','AVProgram','AVChapter',
         'AVStreamGroup','AVStreamGroupTileGrid','AVStreamGroupLayeredVideo','AVStreamGroupTREF',
         'AVFilter','AVFilterContext','AVFilterLink','AVFilterGraph','AVFilterInOut',
         'AVBufferSrcParameters','SwsContext','SwsVector','SwsFilter']
includes = '\n'.join('#include <'+h+'>' for h in headers)
source = out/'probe.c'
source.write_text(includes+'\n')
triplet = 'x86_64' if a.arch == 'Win64' else 'i686'
cc = str(a.toolchain/'bin'/(triplet+'-w64-mingw32-clang'))
ast = json.loads(subprocess.check_output([cc,'-I'+str(a.include),'-Xclang','-ast-dump=json',
                                        '-fsyntax-only',str(source)]))
decls = ast['inner']
pastext = '\n'.join((root/'Headers'/(u+'.pas')).read_text() for u in units)
c = [includes,'#include <stddef.h>','#include <stdio.h>','int main(void) {']
pas = ['program ABIProbe;', '{$APPTYPE CONSOLE}', 'uses '+', '.join(units)+';', 'type']
records = {}
for decl in decls:
    if decl.get('kind') == 'RecordDecl' and decl.get('completeDefinition') and decl.get('name') in types:
        records[decl['name']] = decl
for name in types:
    if name not in records:
        raise RuntimeError('Missing C record '+name)
    pas.append('  TP_'+name+' = ^T'+name+';')
pas.append('begin')
count = 0
def emit(key, ce, pe):
    global count
    c.append('printf("'+key+'=%lld\\n", (long long)('+ce+'));')
    pas.append("  WriteLn('"+key+"=', "+pe+');')
    count += 1
for name in types:
    emit(name+'.sizeof','sizeof('+name+')','SizeOf(T'+name+')')
    for field in records[name].get('inner',[]):
        if field['kind'] != 'FieldDecl' or not field.get('name') or field.get('isBitfield'):
            continue
        f = field['name']
        pf = {'type':'type_', 'unit':'uunit', 'end':'eend', 'mod':'mod_'}.get(f, f)
        ctype = field['type'].get('desugaredQualType', field['type']['qualType'])
        # Delphi @procvar reads its target; @@procvar addresses the field itself.
        addr = '@@' if re.search(r'\(\*', ctype) or (name, f) == ('AVFilterGraph','execute') else '@'
        emit(name+'.'+f, 'offsetof('+name+', '+f+')', 'NativeUInt('+addr+'TP_'+name+'(nil)^.'+pf+')')
enumcount = 0
missing = []
for decl in decls:
    if decl['kind'] != 'EnumDecl' or not decl.get('name'):
        continue
    if not re.search(r'\bT'+decl['name']+r'\s*=', pastext):
        continue
    for item in decl.get('inner',[]):
        if item['kind'] == 'EnumConstantDecl':
            name = item['name']
            if not re.search(r'\b'+name+r'\b', pastext):
                missing.append(decl['name']+'.'+name)
                continue
            emit('enum.'+name, name, 'Int64('+name+')')
            enumcount += 1
if missing:
    raise SystemExit('Missing Pascal enum values:\n'+'\n'.join(missing))
c.append('return 0; }')
pas.append('end.')
source.write_text('\n'.join(c)+'\n')
paspath = out/'ABIProbe.dpr'
paspath.write_text('\n'.join(pas)+'\n')
subprocess.run([cc,'-I'+str(a.include),str(source),'-o',str(out/'CProbe.exe')],check=True)
def win(path):
    return subprocess.check_output(['wslpath','-w',str(path)],text=True).strip()
bds = a.bds_dir
dcc = bds/'bin'/('dcc64.exe' if a.arch == 'Win64' else 'dcc32.exe')
subprocess.run([str(dcc),'-B','-U'+win(root/'Headers')+';'+win(bds/'lib'/a.arch.lower()/'release'),
               '-I'+win(root/'Headers'),'-NSSystem;Winapi','-N0'+win(out),'-NU'+win(out),
               '-E'+win(out),win(paspath)],check=True)
expected = subprocess.check_output([str(out/'CProbe.exe')],text=True)
actual = subprocess.check_output([str(out/'ABIProbe.exe')],text=True)
(out/'c-layout.txt').write_text(expected)
(out/'pascal-layout.txt').write_text(actual)
e = dict(line.split('=',1) for line in expected.splitlines())
d = dict(line.split('=',1) for line in actual.splitlines())
errors = [f'{key}: C={value}, Pascal={d.get(key)}' for key,value in e.items() if d.get(key) != value]
if errors:
    raise SystemExit('\n'.join(errors))
print(f'PASS {a.arch}: {len(types)} record sizes, {count-len(types)-enumcount} offsets, {enumcount} enum values')
