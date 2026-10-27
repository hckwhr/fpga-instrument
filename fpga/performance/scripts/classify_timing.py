"""Classify reported paths without claiming unreported endpoints were inspected."""
import argparse
import fnmatch
import hashlib
import html
import json
import re
from collections import Counter
from pathlib import Path


def classify(report, audit):
    text = report.read_text(encoding='utf-8-sig')
    scopes = json.loads(audit.read_text(encoding='utf-8-sig'))
    ff = scopes['patterns']
    ff_launch = ff + scopes.get('manual_launch_patterns', [])
    launch = [p for s in scopes['primitive_scopes'] for p in s['launch']]
    capture = [p for s in scopes['primitive_scopes'] for p in s['capture']]
    def matched(node, pins, regs):
        reg = node.rsplit('/', 1)[0]
        def match(value,pattern):
            return fnmatch.fnmatchcase(value,pattern.replace('[','?').replace(']','?'))
        return any(match(reg, p) for p in regs) or any(match(node, p) for p in pins)
    table = re.search(r'<a name="Setup_Slack_Table".*?<table.*?</table>', text, re.S)[0]
    paths = []
    for row in re.findall(r'<tr\b.*?</tr>', table, re.S):
        cells = [html.unescape(re.sub('<[^>]*>', '', c)).strip()
                 for c in re.findall(r'<td\b[^>]*>(.*?)</td>', row, re.S)]
        if not cells or float(cells[1]) >= 0:
            continue
        paths.append(dict(number=int(cells[0]), slack_ns=float(cells[1]),
                          source=cells[2], sink=cells[3], relation_ns=float(cells[6]),
                          source_in_sdc=matched(cells[2], launch, ff_launch),
                          sink_in_sdc=matched(cells[3], capture, ff)))
    total = int(re.search(r'Numbers of Setup Violated Endpoints</td>\s*<td>(\d+)', text)[1])
    endpoints = {p['sink'] for p in paths}
    groups = Counter((p['source_in_sdc'], p['sink_in_sdc']) for p in paths)
    clusters = Counter((p['source'].rsplit('/', 2)[0], p['sink'].rsplit('/', 2)[0]) for p in paths)
    return dict(report=str(report), report_sha256=hashlib.sha256(report.read_bytes()).hexdigest(),
                violated_endpoints=total, reported_negative_paths=len(paths),
                reported_unique_endpoints=len(endpoints), unreported_endpoints=total-len(endpoints),
                groups=[dict(source_in_sdc=s, sink_in_sdc=t, paths=n) for (s,t),n in groups.items()],
                clusters=[dict(source=s,sink=t,paths=n) for (s,t),n in clusters.items()], paths=paths)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--audit', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = classify(args.report, args.audit)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps({k:v for k,v in result.items() if k!='paths'}, indent=2))
