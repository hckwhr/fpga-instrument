"""Check both members of each differential pair against the final report."""
import argparse
import importlib.util
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
repository = root.parents[1]
build = Path('E:/Gowin/workspace') / root.name
archive = repository / 'artifacts' / root.name
parser = argparse.ArgumentParser()
parser.add_argument('--archive', type=Path, default=archive)
args = parser.parse_args()
archive = args.archive
spec = importlib.util.spec_from_file_location('gowin_server', repository / 'gowin-mcp/server.py')
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
raw = server.gowin_pin_audit(str(build / 'v3_hdmi_top.gprj'))
archive.mkdir(parents=True, exist_ok=True)
(archive / 'pin_audit_raw.json').write_text(json.dumps(raw, indent=2))
assert raw['final_report'] and not raw['final_report_stale']
assert raw['project_part_number'] == raw['final_report_part_number'] == 'GW5AST-LV138PG484AC1/I0'
for key in ('duplicate_location_ports', 'duplicate_io_ports', 'duplicate_pins',
            'expected_ports_without_location', 'ports_without_io_attributes',
            'cst_ports_missing_from_final'):
    assert not raw[key], (key, raw[key])
ports = {entry['port']: entry for entry in raw['final_ports']}
assert len(ports) == len(raw['final_ports']) == 31
checks = []
covered = set()
for location in raw['constraint_assignments']:
    name = location['port']
    entries = [ports[name]]
    if len(location['pins']) == 2:
        partner = ports[name]['diff_pair']
        assert partner in ports and ports[partner]['diff_pair'] == name
        entries.append(ports[partner])
    actual = [pin for entry in entries for pin in entry['pins']]
    assert actual == location['pins'], (name, actual, location['pins'])
    for entry in entries:
        assert entry['constrained'] and entry['port'] not in covered
        covered.add(entry['port'])
        for key, value in location['attributes'].items():
            assert entry[key.lower()] == value, (entry['port'], key, entry[key.lower()], value)
    checks.append(dict(port=name, expected=location['pins'], actual=actual,
                       attributes_checked=location['attributes'], valid=True))
assert covered == set(ports), 'Unconstrained/unexpected final port'
assert len({entry['pin'] for entry in ports.values()}) == 31
result = dict(raw_mcp_clean=raw['clean'],
              raw_mcp_limit='Paired CST assignments require expanding both final P/N rows.',
              final_report=raw['final_report'], final_report_stale=False,
              port_count=31, checks=checks, clean=True)
(archive / 'pin_pair_audit.json').write_text(json.dumps(result, indent=2))
print('PASS: 31 final ports, differential partners, I/O properties and device match; fresh pin report')
