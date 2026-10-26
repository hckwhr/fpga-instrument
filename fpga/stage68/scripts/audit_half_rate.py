"""Audit actual CE processes and derive conservative post-synthesis FF scopes.

No blanket clock exception. Hybrid string voices, full-speed interfaces, reset
release and all unmatched synthesized state remain single-cycle. RAM/DSP pins
are reported for individual review, never silently included as FF objects.
"""
import argparse
import hashlib
import importlib.util
import json
import re
import itertools
import fnmatch
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('scanner', ROOT/'scripts/half_rate_transform.py')
scanner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scanner)


def object_matches(name, pattern):
    # Gowin list entries use '?' for literal Verilog bus brackets; Python
    # fnmatch would otherwise interpret [7] as a character class.
    return fnmatch.fnmatchcase(name, pattern.replace('[','?').replace(']','?'))


def parse_instances(body):
    # Module headers use a separate ')' and ';'. Excluding the keyword keeps
    # the header from swallowing the first primitive up to its closing ');'.
    return [(x[1], x[2].lstrip('\\'), dict(re.findall(r'\.(\w+)\((.*?)\)', x[3])))
            for x in re.finditer(
                r'(?ms)^\s*(?!module\b)(\w+)\s+(\\\S+|\w+)\s+\(\s*\n(.*?)^\);', body)]


def source_processes():
    result = {}
    for path in (ROOT/'rtl').glob('*.v'):
        text = path.read_text(encoding='utf-8-sig')
        for match in re.finditer(r'(?ms)^module\s+(\w+)\b.*?^endmodule', text):
            name = match[1]
            if name not in scanner.selected | {'av_hdmi_top', 'additive_partial'}:
                continue
            body = match[0]
            t = scanner.tokens(body)
            records = []
            i = 0
            while i < len(t):
                if t[i][0] != 'always' or t[i+1][0] != '@' or t[i+2][0] != '(':
                    i += 1
                    continue
                start = scanner.close(t, i+2)
                sensitivity = [x[0] for x in t[i+3:start-1]]
                if 'posedge' not in sensitivity:
                    i += 1
                    continue
                end = scanner.statement(t, start)
                statement = body[t[start][1]:t[end-1][2]]
                clk = sensitivity[sensitivity.index('posedge')+1]
                first = start + (t[start][0] == 'begin')
                if 'negedge' in sensitivity:
                    after_reset = scanner.statement(t, scanner.close(t, first+1))
                    first = after_reset+1 if t[after_reset][0] == 'else' else after_reset
                condition = ''
                if t[first][0] == 'if':
                    z = scanner.close(t, first+1)
                    condition = ''.join(x[0] for x in t[first+2:z-1])
                # The PCM shelf has the same common CE plus a sample enable.
                # This exact conjunction cannot update on an inactive CE edge;
                # do not generalize to arbitrary expressions containing CE.
                gated = ('clock_enable' in condition or condition in
                         ('engine_ce', 'engine_ce&&engine_sample_strobe'))
                hybrid = name == 'physical_string_voice'
                assigned = sorted(set(re.findall(r'\b(\w+)\s*(?:\[[^;\n]*?\])?\s*<=', statement)))
                records.append(dict(clock=clk, gated=gated, hybrid=hybrid,
                                    condition=condition, assigned=assigned,
                                    line=text.count('\n',0,match.start()+t[i][1])+1))
                # Every actual ordinary engine process must have an outer CE.
                expected = clk == ('audio_clk' if name in scanner.MIXED | {'av_hdmi_top'} else 'clk')
                release = any(x in assigned for x in ('audio_release','sys_release','src_reset','dst_reset','audio_reset_sync_n'))
                bridge = name == 'av_hdmi_top' and any(x in assigned for x in ('half_tick','sample_pending'))
                if expected and not release and not bridge and not gated:
                    raise ValueError(f'Uncovered clocked process: {name}:{records[-1]["line"]}')
                i = end
            result[name] = records
    return result


def netlist_audit(path, processes, contest_32=False, contest_strings=False):
    text = path.read_text(encoding='utf-8-sig')
    modules, parameters, module_inputs = {}, {}, {}
    for m in re.finditer(r'(?ms)^module\s+(\w+)\b.*?^endmodule', text):
        instances = parse_instances(m[0])
        modules[m[1]] = instances
        module_inputs[m[1]]=set(re.findall(r'(?m)^input\s+(?:\[[^\]]+\]\s*)?(\w+)\s*;',m[0]))
        parameters[m[1]]={}
        for p in re.finditer(r'(?m)^defparam\s+(\\\S+|\w+)\s*\.(\w+)\s*=\s*([^;]+);',m[0]):
            parameters[m[1]].setdefault(p[1].lstrip('\\'),{})[p[2]]=p[3]
    included, excluded, memories = [], [], []
    voice_instances={'additive_partial':0,'physical_string_voice':0}
    patterns = []
    primitive_scopes=[]
    enable_proof_rejected=[]
    manual_launch=[]
    manual_proofs=[]

    def number(value):
        m=re.fullmatch(r"\d+'([bh])([0-9a-fA-F]+)",value)
        return int(m[2],2 if m[1]=='b' else 16) if m else int(value)

    driver_maps={module:{p.get('F',p.get('O')):(kind,name,p) for kind,name,p in instances
                        if kind.startswith('LUT') or kind in ('INV','MUX2')}
                 for module,instances in modules.items()}

    # Gowin moves shared enable LUTs across module boundaries. Resolve scalar
    # ports into one graph, rather than mistaking an exported CE for an unknown.
    flat_drivers, flat_aliases, flat_half = {}, {}, set()
    def flatten(module,prefix,connections):
        def node(net):
            net=net.strip().lstrip('\\')
            if net in ('GND','VCC',"1'b0","1'b1"):return net
            return connections.get(net,prefix+'/'+net)
        flat_aliases[prefix]=node
        for kind,name,p in modules[module]:
            full=prefix+'/'+name if prefix else name
            if kind in modules:
                flatten(kind,full,{port:node(net) for port,net in p.items()})
            elif kind.startswith('LUT') or kind in ('INV','MUX2'):
                flat_drivers[node(p.get('F',p.get('O')))]=(kind,
                    parameters[module].get(name,{}),{key:node(net) for key,net in p.items()})
            elif module=='av_hdmi_top' and kind.startswith('DFF') and name.startswith('half_tick_'):
                flat_half.add(node(p['Q']))
    flatten('v3_hdmi_top','',{})

    def flat_evaluator(forced=None):
        forced=forced or {}
        @lru_cache(None)
        def possible(net,depth=0):
            if net in forced:return frozenset({forced[net]})
            if net in flat_half or net in ('GND',"1'b0"):return frozenset({0})
            if net in ('VCC',"1'b1"):return frozenset({1})
            if depth>32 or net not in flat_drivers:return frozenset({0,1})
            kind,params,p=flat_drivers[net]
            if kind=='INV':return frozenset(1-x for x in possible(p['I'],depth+1))
            if kind=='MUX2':return frozenset(v for s in possible(p['S0'],depth+1)
                                           for v in possible(p['I'+str(s)],depth+1))
            init=number(params['INIT'])
            return frozenset((init>>sum(v<<i for i,v in enumerate(combo)))&1
                             for combo in itertools.product(*(possible(p['I'+str(i)],depth+1)
                                                             for i in range(int(kind[3:])))))
        return possible
    global_possible=flat_evaluator()

    def evaluator(module, half_nets, forced=None, inactive_zero=frozenset()):
        drivers=driver_maps[module]
        forced=forced or {}
        @lru_cache(None)
        def possible(net, phase=0, depth=0):
            if net in forced:return frozenset({forced[net]})
            if net in half_nets:return frozenset({phase})
            if phase==0 and net in inactive_zero:return frozenset({0})
            if net in ('GND',"1'b0"):return frozenset({0})
            if net in ('VCC',"1'b1"):return frozenset({1})
            if depth>20 or net not in drivers:return frozenset({0,1})
            kind,name,p=drivers[net]
            if kind=='INV':return frozenset(1-x for x in possible(p['I'],phase,depth+1))
            if kind=='MUX2':
                return frozenset(v for s in possible(p['S0'],phase,depth+1)
                                 for v in possible(p['I'+str(s)],phase,depth+1))
            width=int(kind[3:])
            init=number(parameters[module][name]['INIT'])
            return frozenset((init>>sum(v<<i for i,v in enumerate(combo)))&1
                             for combo in itertools.product(*(possible(p['I'+str(i)],phase,depth+1)
                                                             for i in range(width))))
        return possible

    def source_name(module):
        return next((x for x in sorted(processes,key=len,reverse=True)
                     if re.fullmatch(re.escape(x)+r'(?:_\d+)?',module)),None)

    def visit(module, prefix, half_nets=frozenset(), inactive_zero=frozenset()):
        if module=='av_hdmi_top':
            replicas=[(n,p) for k,n,p in modules[module] if k.startswith('DFF') and n.startswith('half_tick_')]
            if not replicas or len({(p['D'],p['CLK'],p['CLEAR'],p.get('CE'),parameters[module][n]['INIT']) for n,p in replicas})!=1:
                raise ValueError('Half tick replicas differ in clock/reset/data/init')
            if any(parameters[module][n]['INIT']!="1'b0" for n,p in replicas):
                raise ValueError('Half tick must reset to zero')
            half_nets=frozenset(p['Q'] for n,p in replicas)
            # Synthesis can export the feedback inverter through a child
            # output (stage66d: u_pt8211_tx). Resolve actual connected nets,
            # just as the CE proof below does; never infer toggling from names.
            if any(p.get('CE') != 'VCC' or p['CLK'] != 'audio_clk' for n,p in replicas):
                raise ValueError('Half tick must advance on every audio clock edge')
            feedback=flat_aliases[prefix](replicas[0][1]['D'])
            if any(flat_evaluator({node:phase for node in flat_half})(feedback)!={1-phase}
                   for phase in (0,1)):
                raise ValueError('Half tick does not invert every physical edge')
        possible=evaluator(module,half_nets,inactive_zero=inactive_zero)
        def half_ce(net):return global_possible(flat_aliases[prefix](net))=={0}
        replicas={}
        signatures={}
        for kind,name,ports in modules[module]:
            if kind.startswith('DFF'):
                signature=(kind,tuple(sorted((k,v) for k,v in ports.items() if k!='Q')),
                           tuple(sorted(parameters[module].get(name,{}).items())))
                signatures[name]=signature
                replicas.setdefault(signature,[]).append(ports['Q'])
        source = source_name(module)
        if source in voice_instances:
            voice_instances[source]+=1
        records = processes.get(source,[])
        hybrid = source == 'physical_string_voice'
        pure = bool(records) and all(x['gated'] for x in records) and not hybrid
        gated_names = {r for x in records if x['gated'] for r in x['assigned']}
        if source == 'av_hdmi_top':
            gated_names -= {'half_tick','sample_pending'}
            # Reviewed launch-only exception for the reported poly_enable_s46.
            # All 54 copies form a closed feedback family: reset=0; active
            # phase loads the SAME function; inactive phase copies a peer.
            # Induction therefore proves equal Q and no inactive transition.
            # Keep ALL captures into this family single-cycle: cross-replica
            # feedback must still meet the intervening physical clock edge.
            family=[(k,n,p) for k,n,p in modules[module]
                    if re.fullmatch(r'poly_enable_s\d+',n) and k.startswith('DFF')]
            qset={p['Q'] for k,n,p in family}
            active_inputs=set()
            evidence=[]
            valid=len(family)==54 and 'poly_enable' in gated_names
            for k,n,p in family:
                driver=driver_maps[module].get(p['D'])
                valid &= (k=='DFFCE' and p.get('CLK')=='audio_clk' and
                          p.get('CE')=='VCC' and p.get('CLEAR')=='n410_6' and
                          parameters[module][n].get('INIT')=="1'b0" and bool(driver))
                if not driver:continue
                dk,dn,dp=driver
                valid &= (dk=='LUT4' and parameters[module][dn].get('INIT')=="16'hBBF0" and
                          dp.get('I2') in qset and dp.get('I3') in half_nets)
                active_inputs.add((dp.get('I0'),dp.get('I1')))
                evidence.append(dict(register=prefix+'/'+n,feedback=dp.get('I2'),
                                     lut=dn,init=parameters[module][dn].get('INIT')))
            if valid and len(active_inputs)==1:
                requested=prefix+'/poly_enable_s46'
                if requested not in {prefix+'/'+n for k,n,p in family}:
                    raise ValueError('Reviewed launch register absent')
                manual_launch.append(requested)
                manual_proofs.append(dict(register=requested,kind='launch-only equal-replica induction',
                    active_function='I0 OR NOT I1',active_inputs=list(active_inputs)[0],
                    inactive_function='peer Q',initial_value=0,captures_remain_single_cycle=True,
                    replicas=evidence))
        # CDC modules share their source code but only the audio side is gated.
        if source in scanner.CDC:
            audio_src = prefix in ('u_instrument/u_status_bundle_cdc','u_instrument/u_audio_sample_cdc',
                                   'u_instrument/shared_link.endpoint/transmit_legacy')
            audio_dst = prefix in ('u_instrument/v3_analog.u_inputs/u_cdc',
                                   'u_instrument/shared_link.endpoint/receive_legacy')
            gated_names = {r for x in records if x['gated'] and
                           ((x['clock']=='src_clk' and audio_src) or
                            (x['clock']=='dst_clk' and audio_dst)) for r in x['assigned']}
            pure = False
        local_in, local_out = [], []
        for kind, name, ports in modules[module]:
            full = prefix+'/'+name if prefix else name
            if kind in modules:
                child_half=frozenset(port for port,net in ports.items() if net in half_nets)
                child_zero=frozenset(port for port,net in ports.items()
                                     if port in module_inputs[kind] and half_ce(net))
                visit(kind,full,child_half,child_zero)
            elif kind.startswith('DFF'):
                selected = (not hybrid and ports.get('CLK')=='audio_clk' and
                            (pure or any(re.search(r'(?:^|\.)'+re.escape(r)+r'(?:_|\[|$)',name) for r in gated_names)))
                if selected and not half_ce(ports.get('CE','VCC')):
                    # Synthesis may implement the outer CE as D feedback while
                    # tying primitive CE high. Prove D=Q for BOTH possible Q
                    # values on the inactive phase; unknown inputs remain free.
                    held=all(flat_evaluator(
                        {flat_aliases[prefix](q):value for q in replicas[signatures[name]]})(
                            flat_aliases[prefix](ports['D']))=={value}
                             for value in (0,1))
                    if not held:
                        ce_node=flat_aliases[prefix](ports.get('CE','VCC'))
                        ce_driver=flat_drivers.get(ce_node)
                        enable_proof_rejected.append(dict(path=full,primitive=kind,ports=ports,
                            ce_node=ce_node,ce_possible=sorted(global_possible(ce_node)),
                            ce_driver=ce_driver,
                            ce_inputs={k:sorted(global_possible(v)) for k,v in ce_driver[2].items()
                                       if k.startswith('I')} if ce_driver else {}))
                        selected=False
                (included if selected else excluded).append(full)
                (local_in if selected else local_out).append(full)
            elif kind in ('pROM','SDPB','DPB','SP') or kind.startswith('MULT'):
                params=parameters[module].get(name,{})
                entry=dict(path=full,primitive=kind,source=source,
                           uniform_half_module=pure,ports=ports,parameters=params)
                memories.append(entry)
                # Explicit sequential data pins only. Never wildcard a primitive,
                # include clock/reset pins, or relax combinational DSP bypasses.
                launch,capture=[],[]
                allowed=not hybrid and (pure or source=='song_uploaded_player')
                def bits(port):
                    expr=ports.get(port,'')
                    if not expr:return 0
                    total=0
                    for atom in expr.strip('{}').split(','):
                        ran=re.search(r'\[(\d+):(\d+)\]',atom)
                        total+=abs(int(ran[1])-int(ran[2]))+1 if ran else 1
                    return total
                def data_pins(port):
                    width=bits(port)
                    if not width:return []
                    # Only globs naming this DATA port, never a primitive-wide
                    # wildcard. Numeric anchors distinguish A[n] from ASIGN,
                    # C[n] from CLK/CE, and D[n] from DOUT[n].
                    other=[q for q in ports if q!=port]
                    pattern=port+'*'
                    if not any(fnmatch.fnmatchcase(q,pattern) for q in other):
                        return [full+'/'+pattern]
                    patterns=[port+'?'+str(i)+'*' for i in range(min(width,10))]
                    if any(fnmatch.fnmatchcase(q,p) or fnmatch.fnmatchcase(q+'[0]',p)
                           for p in patterns for q in other):
                        raise ValueError('Unsafe data pin wildcard: '+full+'/'+port)
                    return [full+'/'+p for p in patterns]
                if allowed and kind=='pROM' and params.get('READ_MODE')=="1'b0" and half_ce(ports['CE']):
                    launch+=data_pins('DO');capture+=data_pins('AD')
                elif allowed and kind=='SDPB' and params.get('READ_MODE')=="1'b0":
                    if ports['CLKB']=='audio_clk' and half_ce(ports['CEB']):
                        launch+=data_pins('DO');capture+=data_pins('ADB')
                    if ports['CLKA']=='audio_clk' and half_ce(ports['CEA']):
                        capture+=data_pins('DI')+data_pins('ADA')
                elif allowed and kind.startswith('MULT'):
                    clk=ports.get('CLK','').strip('{}').split(',')
                    ce=ports.get('CE','').strip('{}').split(',')
                    # Params select CE0/CLK0 on this tool/device. Check every
                    # active register, including internal pipeline registers.
                    active=[(key,val.strip('"')) for key,val in params.items()
                            if key.endswith('_CLK') and val!='"BYPASS"']
                    uniform=bool(active) and all(v.startswith('CLK') and
                        clk[-1-int(v[3:])]=='audio_clk' and
                        half_ce(ce[-1-int(params[key[:-4]+'_CE'].strip('"')[2:])])
                        for key,v in active)
                    if uniform:
                        output_registered=params.get('OREG_CLK','"BYPASS"')!='"BYPASS"'
                        for port in ('A','B','C','D'):
                            if output_registered or params.get(port+'REG_CLK',params.get(port+'_IREG_CLK','"BYPASS"'))!='"BYPASS"':
                                capture+=data_pins(port)
                        if output_registered:
                            launch+=data_pins('DOUT')
                if launch or capture:
                    primitive_scopes.append(dict(path=full,primitive=kind,launch=launch,capture=capture))
        # A wildcard may span hierarchies. Use it only when EVERY descendant FF
        # was independently classified half-rate. Otherwise enumerate local FFs.
        if local_in:
            descendant_out = any(x.startswith(prefix+'/') for x in excluded)
            if pure and not descendant_out:
                patterns.append(prefix+'/*')
            else:
                # Compact only names whose complete wildcard match set is safe.
                groups={}
                for full in local_in:
                    name=full.rsplit('/',1)[-1]
                    stem=re.split(r'\[\d+\]|_\d+_s\d+$|_s\d+$',name,maxsplit=1)[0]
                    groups.setdefault(prefix+'/'+stem+'*',[]).append(full)
                for pattern,members in groups.items():
                    if len(members)>1 and not any(object_matches(x,pattern) for x in local_out):
                        patterns.append(pattern)
                    else:
                        patterns.extend(x.replace('[','?').replace(']','?') for x in members)

    visit('v3_hdmi_top','')
    patterns = sorted(set(patterns))
    # Remove descendants of already-safe whole-subtree patterns.
    subtrees=[q for q in patterns if q.endswith('/*')]
    patterns = [p for p in patterns if not any(q.endswith('/*') and p.startswith(q[:-1])
                for q in subtrees if q != p)]
    for p in patterns:
        if any(object_matches(x,p) for x in excluded):
            raise ValueError('Exception includes full-speed state: '+p)
    if any(object_matches(q,p) for q in manual_launch for p in patterns):
        raise ValueError('Launch-only register was incorrectly added to capture scope')
    if set(included)&set(excluded):raise ValueError('FF scope sets overlap')
    poly=re.search(r'(?ms)^module polyphony_bank_32(?:\s|\().*?^endmodule',text)[0]
    phases={}
    envelopes={}
    for label, target in (('phase_accumulator',phases),('envelope_gain',envelopes)):
        for m in re.finditer(r'(?m)^\s*DFF\w*\s+\\'+label+r'\[(\d+)\]_(\d+)_\w+\s+\(',poly):
            target.setdefault(m[1],[]).append(int(m[2]))
    expected_units = ({'additive_partial':0,'physical_string_voice':8} if contest_strings else
        {'additive_partial':0,'physical_string_voice':0} if contest_32 else
        {'additive_partial':32,'physical_string_voice':8})
    if (len(phases)!=32 or any(len(x)!=32 for x in phases.values()) or
            len(envelopes)!=32 or any(len(x)!=12 for x in envelopes.values()) or
            voice_instances!=expected_units):
        raise ValueError('Independent synthesis-unit count does not match selected configuration')
    return dict(netlist_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                half_rate_ff_count=len(included),single_cycle_ff_count=len(excluded),
                patterns=patterns,half_rate_ffs=included,single_cycle_ffs=excluded,
                enable_proof_rejected=enable_proof_rejected,half_tick_nodes=sorted(flat_half),
                manual_launch_patterns=manual_launch,manual_launch_proofs=manual_proofs,
                primitive_scopes=primitive_scopes,
                ram_dsp_review=memories,independent_phases=phases,
                independent_envelopes=envelopes,independent_voice_instances=voice_instances)


def write_sdc(result, destination):
    """Generate paired exceptions from actual proven sequential endpoints."""
    baseline=ROOT/'constraints/base_hardware.sdc'
    launch=[p for scope in result['primitive_scopes'] for p in scope['launch']]
    capture=[p for scope in result['primitive_scopes'] for p in scope['capture']]
    def collection(kind,items):
        # Brackets inside a braced Tcl list are literal. Replace bus brackets
        # with single-character patterns for Gowin's object glob matcher.
        return '['+kind+' {\n'+'\n'.join('  '+x.replace('[','?').replace(']','?') for x in items)+'\n}]'
    ff=collection('get_regs',result['patterns'])
    ff_launch=collection('get_regs',result['patterns']+result.get('manual_launch_patterns',[]))
    sources=[ff_launch]+([collection('get_pins',launch)] if launch else [])
    sinks=[ff]+([collection('get_pins',capture)] if capture else [])
    lines=[baseline.read_text(encoding='utf-8-sig').rstrip(),
           '\n# Generated by audit_half_rate.py from netlist SHA256 '+result['netlist_sha256'],
           '# Only proven common-CE state pairs. Full-speed boundaries remain single-cycle.',
           '# Setup capture edge +1 period; paired hold restores original hold relation.']
    lines += [
        '# Reviewed poly_index[5:0]: concurrent_test_source.v has an outer common CE',
        '# around BOTH disable/reset-to-zero and event_valid && event_ready advance.',
        '# event_ready includes !sample_strobe && allocator_state==IDLE; this is',
        '# backpressure, NOT a proof of a minimum transaction spacing. The proof',
        '# is the common alternating CE: LUT4 poly_index_4_s2 INIT=16h4F00 has',
        '# all lower eight bits zero, hence CE=0 whenever half_tick_12=0.',
        '# The parser now retains this first LUT. Capture also requires proven CE.',
        '# Thus an active launch cannot change state at the intervening inactive',
        '# capture edge; next eligible capture is +2 periods. Reset is unchanged.',
    ]
    for proof in result.get('manual_launch_proofs',[]):
        lines += ['# Reviewed LAUNCH ONLY: '+proof['register'],
                  '# 54 DFFCE replicas reset to 0; each LUT4 INIT=16hBBF0 loads',
                  '# common (I0 OR NOT I1) at half_tick=1, peer Q at half_tick=0.',
                  '# Closed peer set + identical init/reset proves all Q equal by',
                  '# induction, and no Q transition on inactive edges. This source',
                  '# is paired ONLY with already proven half-rate capture objects.',
                  '# All captures INTO poly_enable replicas remain SINGLE CYCLE',
                  '# to enforce physical feedback timing on the intervening edge.']
    for source in sources:
        for sink in sinks:
            lines += ['set_multicycle_path -from '+source+' -to '+sink+' -setup -end 2',
                      'set_multicycle_path -from '+source+' -to '+sink+' -hold -start 1']
    lines += ['report_exceptions -setup -from_clock [get_clocks {audio_clk}] -to_clock [get_clocks {audio_clk}] -max_paths 10',
              'report_exceptions -hold -from_clock [get_clocks {audio_clk}] -to_clock [get_clocks {audio_clk}] -max_paths 10',
              'report_timing -setup -max_paths 500',
              'report_timing -hold -max_paths 100']
    destination.write_text('\n'.join(lines)+'\n',encoding='utf-8')
    print('SDC:',len(result['patterns']),'FF patterns,',len(launch),'primitive launch pins,',len(capture),'capture pins')


if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--netlist',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--sdc',type=Path)
    parser.add_argument('--omit-patterns',type=Path)
    parser.add_argument('--contest-32',action='store_true')
    parser.add_argument('--contest-strings',action='store_true')
    args=parser.parse_args()
    result={'source_processes':source_processes()}
    if args.netlist:
        result.update(netlist_audit(args.netlist,result['source_processes'],args.contest_32,args.contest_strings))
        result['netlist_path']=str(args.netlist.resolve())
    if args.omit_patterns:
        omitted=json.loads(args.omit_patterns.read_text(encoding='utf-8-sig'))
        if any(p not in result['patterns'] for p in omitted['patterns']):
            raise ValueError('Omission is not an exact generated FF pattern')
        result['constraint_omissions']=omitted
        result['patterns']=[p for p in result['patterns'] if p not in omitted['patterns']]
    if args.sdc:
        if not args.netlist:parser.error('--sdc requires --netlist')
        write_sdc(result,args.sdc)
        result['sdc_sha256']=hashlib.sha256(args.sdc.read_bytes()).hexdigest()
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2),encoding='utf-8')
    print('Audited',len(result['source_processes']),'modules;',
          result.get('half_rate_ff_count','not synthesized'),'half-rate FFs')
