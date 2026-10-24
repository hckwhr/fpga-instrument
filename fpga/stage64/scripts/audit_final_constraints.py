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
    r'(?ms)^set_multicycle_path .*?\}\] -(?:setup -end 2|hold -start 1)$', sdc)]
expected = [normalize(command.splitlines()[0]) for command in expected_full]
actual = [normalize(r['command']) for r in rows if r['kind'] == 'TC_MULTICYCLE']
assert len(expected) == 8 and Counter(actual) == Counter(expected), 'Multicycle commands differ'
assert all(r['state'] == 'Actived' for r in rows if r['kind'] in
           ('TC_MULTICYCLE', 'TC_CLOCK', 'TC_GENERATED_CLOCK')), 'Clock/CE exception inactive'
assert len([r for r in rows if r['kind'] in ('TC_CLOCK','TC_GENERATED_CLOCK')]) == 3
result = dict(report_sha256=hashlib.sha256(args.report.read_bytes()).hexdigest(),
              sdc_sha256=hashlib.sha256(args.sdc.read_bytes()).hexdigest(),
              multicycle_rows_active=8, applied_sdc_setup_hold_pairs=4,
              report_limitation='HTML records only first line of multiline commands; full endpoints and edge choices preserved from hashed applied SDC',
              applied_multicycle_commands=expected_full,
              clocks_active=3, constraints=rows)
args.output.write_text(json.dumps(result, indent=2), encoding='utf-8')
print(json.dumps({k:v for k,v in result.items()
                  if k not in ('constraints','applied_multicycle_commands')}, indent=2))
