"""Prove the 47 actual CE pins stay zero under the reviewed menu mask.

LUT truth tables are evaluated with ALL other leaves unconstrained. This is a
combinational proof under explicit protocol assumptions, not a complete temporal
formal verification. The protocol assumptions are checked separately in RTL/test.
"""
import argparse
import hashlib
import itertools
import json
import re
from functools import lru_cache
from pathlib import Path
from audit_half_rate import parse_instances

def prove(path,inventory,remove_guards=False):
    text=path.read_text(encoding='utf-8-sig')
    modules={m[1]:m[0] for m in re.finditer(r'(?ms)^module\s+(\w+)\b.*?^endmodule',text)}
    graph={};regs={}
    def bits(expr):
        expr=expr.strip().lstrip('\\')
        if expr.startswith('{'):
            return [v for atom in expr[1:-1].split(',') for v in bits(atom)]
        m=re.fullmatch(r'(.*)\[(\d+):(\d+)\]',expr)
        if m:
            a,b=int(m[2]),int(m[3]);step=1 if b>=a else -1
            return [m[1]+'['+str(i)+']' for i in range(a,b+step,step)]
        return [expr]
    def visit(module,prefix,connections):
        body=modules[module]
        def node(net):
            net=net.strip().lstrip('\\')
            if net in ('VCC','GND',"1'b0","1'b1"):return net
            return connections.get(net,prefix+'/'+net)
        params={}
        for p in re.finditer(r'(?m)^defparam\s+(\\\S+|\w+)\s*\.(\w+)\s*=\s*([^;]+);',body):
            params.setdefault(p[1].lstrip('\\'),{})[p[2]]=p[3]
        for kind,name,ports in parse_instances(body):
            full=prefix+'/'+name if prefix else name
            if kind in modules:
                con={}
                decls={m[3]:(m[1],m[2]) for m in re.finditer(
                    r'(?m)^(?:input|output|inout)\s+(?:\[(\d+):(\d+)\]\s*)?(\w+)\s*;',modules[kind])}
                for port,expr in ports.items():
                    ran=decls.get(port)
                    lhs=bits(port+'['+ran[0]+':'+ran[1]+']') if ran and ran[0] else [port]
                    rhs=bits(expr)
                    if len(lhs)==len(rhs):con.update({l:node(r) for l,r in zip(lhs,rhs)})
                    else:con[port]=node(expr) # unresolved vector remains unknown
                visit(kind,full,con)
            elif kind.startswith('LUT') or kind in ('INV','MUX2'):
                graph[node(ports.get('F',ports.get('O')))]=(kind,params.get(name,{}),{k:node(v) for k,v in ports.items()})
            elif kind.startswith('DFF'):
                regs[full]={k:node(v) for k,v in ports.items()}
    visit('v3_hardware_top','',{})
    guards={}
    control='u_instrument/u_instrument_control/'
    for name,value in [('self_test_active_s0',0),('setting_mode_s5',1)]:
        guards[regs[control+name]['Q']]=value
    if remove_guards:guards={}
    @lru_cache(None)
    def possible(net,depth=0):
        if net in guards:return frozenset({guards[net]})
        if net in ('GND',"1'b0"):return frozenset({0})
        if net in ('VCC',"1'b1"):return frozenset({1})
        if depth>80 or net not in graph:return frozenset({0,1})
        kind,params,p=graph[net]
        if kind=='INV':return frozenset(1-v for v in possible(p['I'],depth+1))
        if kind=='MUX2':return frozenset(v for s in possible(p['S0'],depth+1) for v in possible(p['I'+str(s)],depth+1))
        init=params['INIT'];radix=16 if "'h" in init else 2
        val=int(init.split("'")[1][1:],radix)
        return frozenset((val>>sum(v<<i for i,v in enumerate(combo)))&1
            for combo in itertools.product(*(possible(p['I'+str(i)],depth+1) for i in range(int(kind[3:])))))
    results=[]
    for item in inventory['paths']:
        reg,pin=item['sink'].rsplit('/',1)
        assert pin=='CE'
        values=sorted(possible(regs[reg][pin]))
        results.append(dict(endpoint=item['sink'],ce_values_in_menu=values,masked=(values==[0])))
    return dict(netlist_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),guards=guards,
                source_left_unconstrained=inventory['source'],endpoints=results,
                all_47_masked=len(results)==47 and all(r['masked'] for r in results))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--netlist',type=Path,required=True)
    p.add_argument('--inventory',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--negative-control',action='store_true')
    args=p.parse_args()
    result=prove(args.netlist,json.loads(args.inventory.read_text()),args.negative_control)
    args.output.write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps({k:v for k,v in result.items() if k!='endpoints'},indent=2))
    if args.negative_control:
        if result['all_47_masked']:raise SystemExit('Negative control failed to expose missing mask')
        print('EXPECTED: removing protocol guards prevents CE-mask proof')
    elif not result['all_47_masked']:raise SystemExit('CE mask not proven: do not build with exception')
