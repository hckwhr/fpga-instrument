"""Compress pin query instance prefixes only when exact netlist matches agree.

FF queries, port globs, constraints and setup/hold edge choices stay unchanged.
This is an offline generator; Gowin SDC does not support Tcl set variables.
"""
from collections import defaultdict
from functools import lru_cache
import argparse
import fnmatch
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT
sys.path.insert(0, str(BASE/'scripts'))
from audit_half_rate import parse_instances

def module_ports(body):
    body = re.sub(r'//[^\n]*|/\*.*?\*/','',body,flags=re.S)
    pins = set()
    for m in re.finditer(r'\b(?:input|output|inout)\s+(?:(?:wire|reg)\s+)?(?:\[(\d+):(\d+)\]\s*)?([\w,\s]+);', body):
        names = [n.strip() for n in m[3].split(',')]
        for name in names:
            if not re.fullmatch(r'\w+', name): raise ValueError('Unparsed port: '+name)
            if m[1] is None:
                pins.add(name)
            else:
                pins.update(f'{name}[{b}]' for b in range(min(int(m[1]),int(m[2])),max(int(m[1]),int(m[2]))+1))
    return pins

def universe(netlist):
    text = netlist.read_text()
    bodies = {m[1]:m[0] for m in re.finditer(r'(?ms)^module\s+(\w+)\b.*?^endmodule', text)}
    library = Path('E:/Gowin/Gowin_V1.9.12.03_x64/IDE/simlib/gw5a/prim_sim.v').read_text(errors='replace')
    lib = {m[1]:m[0] for m in re.finditer(r'(?ms)^module\s+(\w+)\b.*?^endmodule',library)}
    definitions = {**lib,**bodies}
    ports = {}
    instances = {k:parse_instances(v) for k,v in bodies.items()}
    nodes = {}
    def visit(module, prefix):
        for kind,name,p in instances[module]:
            full = prefix+'/'+name if prefix else name
            if kind not in definitions: raise ValueError('Missing primitive declaration '+kind)
            if kind not in ports: ports[kind] = module_ports(definitions[kind])
            # Never silently omit a pin whose port declaration failed to parse.
            parsed = {x.split('[')[0] for x in ports[kind]}
            if not set(p) <= parsed: raise ValueError(f'Unparsed ports {kind}: {set(p)-parsed}')
            nodes[full] = kind
            if kind in instances: visit(kind,full)
    visit('v3_hdmi_top','')
    return nodes,ports

def compact_instance_paths(original, relevant):
    """Return patterns with exactly the same matched instance set."""
    allowed = {n for pattern in original for n in relevant if fnmatch.fnmatchcase(n,pattern)}
    if not allowed: raise ValueError('Empty original pin query')
    candidates = set()
    for name in allowed:
        parts = name.split('/')
        for depth in range(1,len(parts)):
            candidates.add('/'.join(parts[:depth])+'/*')
    accepted = []
    covered = set()
    for pattern in sorted(candidates, key=lambda x:(x.count('/'),x)):
        matches = {n for n in relevant if fnmatch.fnmatchcase(n,pattern)}
        if len(matches)>1 and matches<=allowed and not matches<=covered:
            accepted.append(pattern)
            covered.update(matches)
    accepted.extend(n.replace('[','?').replace(']','?') for n in sorted(allowed-covered))
    actual = {n for pattern in accepted for n in relevant if fnmatch.fnmatchcase(n,pattern)}
    if actual != allowed: raise ValueError('Compression changed endpoints')
    # Avoid expanding an already-compact collection.
    return accepted if len(accepted)<len(original) else original, allowed

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--verify-netlist',type=Path)
    args = parser.parse_args()
    netlist = args.verify_netlist or ROOT/'impl/gwsynthesis/v3_hdmi_top.vg'
    if not netlist.exists() and not args.verify_netlist:
        netlist = ROOT/'impl/gwsynthesis/project.vg'
    nodes, ports = universe(netlist)
    source = (BASE/'constraints/half_rate_enumerated.sdc').read_text(encoding='utf-8-sig')
    @lru_cache(None)
    def relevant(suffix):
        types = {k for k,v in ports.items() if any(fnmatch.fnmatchcase(p,suffix) for p in v)}
        return {n for n,k in nodes.items() if k in types}
    if args.verify_netlist:
        candidate_path = ROOT/'constraints/v3_hdmi.sdc'
        candidate = candidate_path.read_text()
        @lru_cache(None)
        def resolve(body):
            found = set()
            for pattern in body.split():
                path,suffix = pattern.rsplit('/',1)
                for name in relevant(suffix):
                    if fnmatch.fnmatchcase(name,path):
                        found.update(name+'/'+pin for pin in ports[nodes[name]] if fnmatch.fnmatchcase(pin,suffix))
            return found
        old = re.findall(r'\[get_pins\s+\{([^}]*)\}\]',source)
        new = re.findall(r'\[get_pins\s+\{([^}]*)\}\]',candidate)
        assert len(old)==len(new)
        for left,right in zip(old,new):
            assert resolve(left)==resolve(right), 'Fresh netlist changed compressed pin coverage'
        report = dict(netlist_sha256=hashlib.sha256(netlist.read_bytes()).hexdigest(),
            all_pin_collections_equal=True,collection_count=len(old),
            candidate_sha256=hashlib.sha256(candidate_path.read_bytes()).hexdigest())
        destination = ROOT/'audit/fresh_compact_equivalence.json'
        destination.parent.mkdir(parents=True,exist_ok=True)
        destination.write_text(json.dumps(report,indent=2))
        print(json.dumps(report,indent=2))
        return
    proofs = []
    @lru_cache(None)
    def transform(body):
        patterns = body.split()
        if len(patterns)<100: return body
        groups = defaultdict(list)
        for pattern in patterns:
            path,suffix = pattern.rsplit('/',1)
            groups[suffix].append(path)
        output = []
        inventory = []
        original_pins = set()
        for suffix, paths in groups.items():
            for name in relevant(suffix):
                if any(fnmatch.fnmatchcase(name,p) for p in paths):
                    original_pins.update(name+'/'+pin for pin in ports[nodes[name]] if fnmatch.fnmatchcase(pin,suffix))
        for suffix,paths in sorted(groups.items()):
            after, matched = compact_instance_paths(paths,relevant(suffix))
            output.extend(p+'/'+suffix for p in after)
            inventory.extend(n+'/'+pin for n in matched for pin in ports[nodes[n]]
                             if fnmatch.fnmatchcase(pin,suffix))
        inventory = sorted(set(inventory))
        assert set(inventory)==original_pins, 'Complete pin collection changed'
        proofs.append(dict(before=len(patterns),after=len(output),matched_pins=len(inventory),
            endpoint_sha256=hashlib.sha256('\n'.join(inventory).encode()).hexdigest(),
            new_patterns=output))
        return '\n'+'\n'.join('  '+p for p in output)+'\n'
    result = re.sub(r'\[get_pins\s+\{([^}]*)\}\]',lambda m:'[get_pins {'+transform(m[1])+'}]',source)
    assert re.findall(r'^set_multicycle_path.*$',source,re.M) == re.findall(r'^set_multicycle_path.*$',result,re.M)
    assert re.findall(r'^\}\] -.*$',source,re.M) == re.findall(r'^\}\] -.*$',result,re.M)
    before_regs = re.findall(r'\[get_regs\s+\{[^}]*\}\]', source)
    assert before_regs == re.findall(r'\[get_regs\s+\{[^}]*\}\]', result)
    # All non-query text must remain identical, including exception edge choices.
    query = r'\[get_pins\s+\{[^}]*\}\]'
    assert re.sub(query, '<PIN_COLLECTION>', source) == re.sub(query, '<PIN_COLLECTION>', result)
    # Negative control: a broad pattern must be rejected when it includes an
    # additional, non-approved DSP instance with the same data pin suffix.
    paths, _ = compact_instance_paths(['top/bank/good0','top/bank/good1'],
        {'top/bank/good0','top/bank/good1','top/bank/full_speed'})
    assert 'top/bank/*' not in paths and 'top/*' not in paths
    destination = ROOT/'constraints/v3_hdmi.sdc'
    destination.write_text(result,encoding='utf-8')
    artifact = ROOT/'audit'
    artifact.mkdir(parents=True,exist_ok=True)
    report = dict(netlist_sha256=hashlib.sha256(netlist.read_bytes()).hexdigest(),
                  original_lines=len(source.splitlines()),new_lines=len(result.splitlines()),
                  setup_hold_pairs_unchanged=True,ff_collections_unchanged=True,
                  non_query_text_unchanged=True,negative_control_passed=True,collections=proofs)
    (artifact/'compact_equivalence.json').write_text(json.dumps(report,indent=2))
    print(json.dumps({k:v for k,v in report.items() if k!='collections'},indent=2))
    print([(p['before'],p['after'],p['matched_pins']) for p in proofs])

if __name__ == '__main__': main()
