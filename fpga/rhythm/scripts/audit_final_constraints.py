"""Check actual STA activation and preserve full applied commands separately.

Gowin's HTML truncates multiline commands to their first line. Do not claim
that this table can independently prove the missing endpoint/edge text.
"""
import argparse
from collections import Counter
import hashlib
import html
import json
from pathlib import Path
import re

parser = argparse.ArgumentParser()
parser.add_argument('--report', type=Path, required=True)
parser.add_argument('--sdc', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--expected-clocks', type=int, default=6)
args = parser.parse_args()
report = args.report.read_text(encoding='utf-8-sig')
sdc = args.sdc.read_text(encoding='utf-8-sig')
table = re.search(r'<a name="SDC_Report".*?<table.*?</table>', report, re.S)[0]
rows = []
for row in re.findall(r'<tr\b.*?</tr>', table, re.S):
    cells = [html.unescape(re.sub('<[^>]*>', '', c)).strip()
             for c in re.findall(r'<td\b[^>]*>(.*?)</td>', row, re.S)]
    if cells:
        assert len(cells) == 3, cells
        rows.append(dict(kind=cells[0], state=cells[1], command=cells[2]))
normalize = lambda text: ' '.join(text.split())
expected_full = [m[0] for m in re.finditer(
    r'(?ms)^set_multicycle_path .*? -(?:setup|hold) -(?:start|end) [0-9]+$', sdc)]
expected = [normalize(command.splitlines()[0]) for command in expected_full]
actual = [normalize(r['command']) for r in rows if r['kind'] == 'TC_MULTICYCLE']
assert len(expected) == 10 and Counter(actual) == Counter(expected), 'Multicycle commands differ'
assert sum(command.endswith('-setup -end 2') for command in expected_full) == 4
assert sum(command.endswith('-hold -start 1') for command in expected_full) == 4
startup = [c for c in expected_full if 'serializer_release_n' in c]
assert len(startup) == 2 and startup[0].endswith('-setup -end 4') and startup[1].endswith('-hold -end 3')
assert all('-through [get_pins {u_instrument/u_hdmi_tx/lanes*.u_serializer/RESET}]' in c and
           '-to [get_clocks {hdmi_serial_clk}]' in c for c in startup)
assert all(r['state'] == 'Actived' for r in rows if r['kind'] in
           ('TC_MULTICYCLE', 'TC_CLOCK', 'TC_GENERATED_CLOCK')), 'Clock/CE exception inactive'
assert len([r for r in rows if r['kind'] in ('TC_CLOCK','TC_GENERATED_CLOCK')]) == args.expected_clocks
result = dict(report_sha256=hashlib.sha256(args.report.read_bytes()).hexdigest(),
              sdc_sha256=hashlib.sha256(args.sdc.read_bytes()).hexdigest(),
              multicycle_rows_active=10, common_ce_setup_hold_pairs=4, quiet_startup_setup_hold_pairs=1,
              report_limitation='HTML records only first line of multiline commands; full endpoints and edge choices preserved from hashed applied SDC',
              applied_multicycle_commands=expected_full,
              clocks_active=args.expected_clocks, constraints=rows)
args.output.write_text(json.dumps(result, indent=2), encoding='utf-8')
print(json.dumps({k:v for k,v in result.items()
                  if k not in ('constraints','applied_multicycle_commands')}, indent=2))
