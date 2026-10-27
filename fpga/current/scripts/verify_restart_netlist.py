"""Compare regenerated synthesis logic exactly, ignoring comments only."""
import hashlib
import json
from pathlib import Path
import re

old = Path('E:/Gowin/workspace/v3_keyboard_stage59b_20261018')
new = Path('E:/Gowin/workspace/v3_keyboard_stage59b_rerun_20261019')
receipt = json.loads((new/'.gowin-mcp/566a853196cf4456acc2a7804bc4e063/receipt.json').read_text())
relative = 'impl/gwsynthesis/v3_hardware_top.vg'
assert (new/relative).stat().st_mtime >= receipt['started_epoch'], 'New synthesis has not written its netlist'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def logic(path):
    # Gowin comments contain the timestamp and source path table. Neither is
    # a cell, connection, parameter, or timing attribute in this emitted file.
    return re.sub(r'//[^\n]*|/\*.*?\*/', '', path.read_text(encoding='utf-8-sig'), flags=re.S)

def canonical(text):
    # Fresh synthesis renamed five single-bit accepting wires. Canonicalize
    # ONLY these declared nets, within their module, preserving bit indices.
    def module(match):
        body = match[0]
        declarations = re.findall(r'wire \[(\d+):\1\] (accepting(?:_Z_\d+)?);', body)
        assert len({bit for bit, name in declarations}) == len(declarations)
        for bit, name in declarations:
            body = re.sub(r'\bwire \['+bit+':'+bit+r'\] '+name+r';',
                          'wire ['+bit+':'+bit+'] restart_accepting_bit_'+bit+';', body)
            body = re.sub(r'\b'+name+r'\['+bit+r'\]', 'restart_accepting_bit_'+bit+'['+bit+']', body)
        return body
    return re.sub(r'(?ms)^module\b.*?^endmodule', module, text)

assert canonical(logic(old/relative)) == canonical(logic(new/relative)), 'Regenerated logic differs; re-audit constraints before accepting P&R'
for name in ('v3_hardware.sdc', 'v3_hardware.cst'):
    assert digest(old/'constraints'/name) == digest(new/'constraints'/name), name+' changed'
report = dict(
    old_netlist_sha256=digest(old/relative),
    new_netlist_sha256=digest(new/relative),
    exact_logic_equal_after_scoped_wire_rename=True,
    normalization='Ignore comments and canonicalize declared single-bit accepting nets by bit within each module; cells, ports, parameters and connectivity unchanged',
    applied_sdc_sha256=digest(new/'constraints/v3_hardware.sdc'),
    cst_sha256=digest(new/'constraints/v3_hardware.cst'),
    build_id=receipt['build_id'])
out = Path(__file__).resolve().parents[3]/'artifacts/v3_keyboard_stage59b_20261018/restart_equivalence.json'
out.write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps(report, indent=2))
