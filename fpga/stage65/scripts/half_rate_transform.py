"""Generate a reviewable CE patch from the immutable 54g snapshot.

This narrow Verilog-2001 statement scanner handles this project's named-port
instances and clocked statements; it rejects ambiguous syntax instead of
silently transforming it. It never edits the baseline or vendor IP.
"""
import json
import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2] / 'v3_full_stage54g_20261016'
DEST = Path(__file__).resolve().parents[1]
TOKEN = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[A-Za-z_$][\w$]*|\d+\'[^\s,;(){}]+|\d+|<=|==|!=|&&|\|\||[^\s]')

def tokens(text):
    return [(m.group(), m.start(), m.end()) for m in TOKEN.finditer(text)
            if not m.group().startswith(('//', '/*'))]

def close(t, i):
    opening = t[i][0]
    ending = {'(': ')', '[': ']', '{': '}'}[opening]
    depth = 1
    i += 1
    while depth:
        if t[i][0] == opening: depth += 1
        if t[i][0] == ending: depth -= 1
        i += 1
    return i

def statement(t, i):
    kind = t[i][0]
    if kind == 'begin':
        i += 1
        if t[i][0] == ':': i += 2
        while t[i][0] != 'end': i = statement(t, i)
        return i + 1
    if kind == 'if':
        i = statement(t, close(t, i + 1))
        return statement(t, i + 1) if t[i][0] == 'else' else i
    if kind in ('for', 'while', 'repeat'):
        return statement(t, close(t, i + 1))
    if kind in ('case', 'casez'):
        i = close(t, i + 1)
        while t[i][0] != 'endcase':
            while t[i][0] != ':': i += 1
            i = statement(t, i + 1)
        return i + 1
    while t[i][0] != ';': i += 1
    return i + 1

def instances(text, modules):
    t = tokens(text)
    found = []
    for i, tok in enumerate(t):
        if tok[0] not in modules or (i and t[i-1][0] == 'module'): continue
        j = i + 1
        params = None
        if t[j][0] == '#':
            params = (j + 1, close(t, j + 1)); j = params[1]
        if not re.fullmatch(r'[\w$]+', t[j][0]) or t[j+1][0] != '(': continue
        port = j + 1
        end = close(t, port)
        if t[end][0] != ';': continue
        ports = {}
        k = port + 1
        while k < end - 1:
            if t[k][0] != '.': raise ValueError(('positional instance', tok, t[k]))
            z = close(t, k + 2)
            ports[t[k+1][0]] = text[t[k+2][2]:t[z-1][1]].strip()
            k = z + (t[z][0] == ',')
        found.append(dict(type=tok[0], name=t[j][0], start=i, param=params, port=port, end=end, ports=ports, tokens=t))
    return found

def apply(text, edits):
    for a,b,value in sorted(edits, reverse=True): text = text[:a]+value+text[b:]
    return text

SOURCES = {p.stem: p.read_text(encoding='utf-8-sig') for p in (BASE/'rtl').glob('*.v')}
MIXED = {'instrument_production_link','song_uploaded_player','v3_analog_input'}
CDC = {'audio_sample_cdc','status_bundle_cdc','uart_byte_cdc'}
# These are deliberately full speed: external protocol or >512-step work.
STOP = {'pt8211_tx','spectrum_analyzer','audio_pll','lcd_pll','hc05_link',
        'v3_performance_input','fsr_performance_input'}
selected = set(MIXED) | CDC
pending = ['av_top']
seen = set()
edges = {}
while pending:
    mod = pending.pop()
    if mod in seen: continue
    seen.add(mod)
    edges[mod] = []
    for inst in instances(SOURCES[mod], SOURCES):
        child = inst['type']
        if child in STOP: continue
        ports = inst['ports']
        audio = ports.get('clk') in ('clk','audio_clk') or child in MIXED
        audio = audio or ports.get('src_clk') in ('clk','audio_clk') or ports.get('dst_clk') in ('clk','audio_clk')
        if not audio: continue
        edges[mod].append(inst)
        selected.add(child)
        pending.append(child)

manifest = {}
patches = []
rewrites = {}
for mod in sorted(selected | {'av_top'}):
    text = SOURCES[mod]
    t = tokens(text)
    edits = []
    if mod == 'av_top':
        edits.append((text.index('parameter integer SONG_UPLOAD_ENABLE'),text.index('parameter integer SONG_UPLOAD_ENABLE'), 'parameter integer HALF_RATE_ENABLE = 0,\n    '))
    else:
        mi = next(i for i,x in enumerate(t) if x[0]=='module')
        pi = mi + 2
        names = ['SRC_CE_ENABLE','DST_CE_ENABLE'] if mod in CDC else ['CE_ENABLE']
        params = ', '.join('parameter integer '+x+'=0' for x in names)
        if t[pi][0] == '#':
            edits.append((t[pi+1][2],t[pi+1][2],params+',\n    '))
            pi = close(t, pi+1)
        else: edits.append((t[pi][1],t[pi][1],'#('+params+') '))
        ports = 'input wire src_clock_enable, dst_clock_enable,\n    ' if mod in CDC else 'input wire clock_enable,\n    '
        edits.append((t[pi][2],t[pi][2],'\n    '+ports))
    processes = []
    i = 0
    while i < len(t):
        if t[i][0] != 'always' or t[i+1][0] != '@' or t[i+2][0] != '(':
            i += 1; continue
        start = close(t,i+2)
        sensitivity = [x[0] for x in t[i+3:start-1]]
        if 'posedge' not in sensitivity: i += 1; continue
        clk = sensitivity[sensitivity.index('posedge')+1]
        end = statement(t,start)
        body = text[t[start][1]:t[end-1][2]]
        # Keep reset release on the physical clock; no MCP applies to it.
        is_release = mod=='instrument_production_link' or (mod=='v3_analog_input' and 'dst_reset<=' in body)
        if mod=='av_top':
            gate = clk=='audio_clk' and 'audio_reset_sync_n' not in body
            ce = 'engine_ce'
        elif mod in CDC:
            gate = True
            ce = '(!'+('SRC' if clk=='src_clk' else 'DST')+'_CE_ENABLE || '+('src' if clk=='src_clk' else 'dst')+'_clock_enable)'
        else:
            gate = clk==('audio_clk' if mod in MIXED else 'clk') and not is_release
            ce = '(!CE_ENABLE || clock_enable)'
        # FILL requires 512 consecutive physical clocks. Never relax this
        # module's paths: the whole state process has a conditional full-speed CE.
        if mod=='physical_string_voice': ce='(!CE_ENABLE || clock_enable || state==FILL)'
        processes.append(dict(clock=clk,line=text.count('\n',0,t[i][1])+1,gated=gate,enable=ce if gate else None))
        if gate:
            if 'negedge' in sensitivity:
                first = start + (t[start][0]=='begin')
                if t[first][0] != 'if': raise ValueError(('no reset if',mod))
                after_reset = statement(t,close(t,first+1))
                if t[after_reset][0] != 'else': raise ValueError(('no reset else',mod))
                edits.append((t[after_reset][2],t[after_reset][2],' if ('+ce+')'))
            else:
                edits.append((t[start][1],t[start][1],'if ('+ce+') '))
        i = end
    for inst in edges.get(mod,[]):
        it = inst['tokens']; pp = inst['ports']; child=inst['type']
        enable = 'engine_ce' if mod=='av_top' else 'clock_enable'
        param = 'HALF_RATE_ENABLE' if mod=='av_top' else 'CE_ENABLE'
        if child in CDC:
            ps=[]; cs=[]
            for side in ('src','dst'):
                active=pp[side+'_clk'] in ('clk','audio_clk')
                ps.append('.'+side.upper()+'_CE_ENABLE('+ (param if active else '0') +')')
                cs.append('.'+side+'_clock_enable('+ (enable if active else "1'b1") +')')
        else:
            ps=['.CE_ENABLE('+param+')'];cs=['.clock_enable('+enable+')']
        if inst['param']:
            pos=it[inst['param'][0]][2]
            edits.append((pos,pos,','.join(ps)+','))
        else:
            pos=it[inst['start']][2]
            edits.append((pos,pos,' #('+','.join(ps)+')'))
        pos=it[inst['port']][2]
        edits.append((pos,pos,','.join(cs)+','))
    output=apply(text,edits)
    rewrites[mod] = output
    manifest[mod]={'processes':processes,'children':[dict(type=x['type'],name=x['name'],ports=x['ports']) for x in edges.get(mod,[])]}
    if output != text:
        # Whole file patches keep this mechanical operation atomic and auditable.
        patches.append('*** Update File: '+(DEST/'rtl'/f'{mod}.v').relative_to(DEST.parents[1]).as_posix()+'\n@@\n'+''.join('-'+x+'\n' for x in text.splitlines())+''.join('+'+x+'\n' for x in output.splitlines()))
if __name__=='__main__':
    import sys
    if '--write' in sys.argv:
        for mod, output in rewrites.items():
            (DEST/'rtl'/f'{mod}.v').write_text(output, encoding='utf-8', newline='\n')
        print('Mechanically rewrote CE ports/processes in '+str(len(rewrites))+' modules')
    elif '--manifest' in sys.argv: print(json.dumps(manifest,indent=2))
    else: print('*** Begin Patch\n'+''.join(patches)+'*** End Patch')
