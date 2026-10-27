"""Read-only implementation audits; archive JSON without promoting hardware evidence."""
import importlib.util
import json
from pathlib import Path

candidate = Path(__file__).resolve().parents[1]
root = candidate.parents[1]
archive = root / 'artifacts' / candidate.name
build = Path('E:/Gowin/workspace') / candidate.name
project = str(build / 'v3_hdmi_top.gprj')
spec = importlib.util.spec_from_file_location('gowin_local', root / 'gowin-mcp/server.py')
gowin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gowin)
results = {}
for name, call in [('timing', lambda: gowin.gowin_timing_summary(project, 30)),
                   ('pins', lambda: gowin.gowin_pin_audit(project))]:
    try:
        results[name] = call()
    except FileNotFoundError as error:
        results[name] = {'missing_evidence': str(error)}
    (archive / f'{name}_audit.json').write_text(
        json.dumps(results[name], indent=2, ensure_ascii=False), encoding='utf-8')

reports = list((build / 'impl/pnr').glob('*_tr_content.html'))
extra = {}
if len(reports) == 1:
    tables = gowin._parse_tables(reports[0])
    summary = gowin._summary_values(gowin._find_table(tables, 'STA Tool Run Summary'))
    # Preserve exact names and unknowns: do not convert absent fields to zero.
    extra['sta_summary'] = summary
    for kind in ('recovery', 'removal'):
        paths = gowin._timing_paths(gowin._timing_path_table(tables, kind), 30)
        extra[kind] = {'paths': paths, 'worst_slack_ns': paths[0]['slack_ns'] if paths else None}
(archive / 'recovery_removal_audit.json').write_text(json.dumps(extra, indent=2), encoding='utf-8')
timing = results['timing']
print(json.dumps({
    'timing_status': timing.get('status', 'missing'),
    'setup': timing.get('worst_setup_slack_ns'),
    'hold': timing.get('worst_hold_slack_ns'),
    'sta': timing.get('sta'),
    'clocks': [c['name'] for c in timing.get('clocks', [])],
    'pin_clean': results['pins'].get('clean'),
    'pin_issues': results['pins'].get('issues'),
    'recovery_removal': extra,
}, indent=2))
