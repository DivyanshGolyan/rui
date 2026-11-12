#!/usr/bin/env python3
"""Summarize sampled live phase costs separately from cumulative peaks."""
import argparse
import csv
import json
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--groups', type=Path, nargs='+', required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
rows = []
for group in a.groups:
    for line in (group / 'summary.jsonl').read_text().splitlines():
        case = json.loads(line)
        if case['returncode'] or not case['measurements'][-1].get('success'):
            continue
        phases = {}
        burst = -1
        for sample in case['measurements']:
            if 'phase' not in sample:
                continue
            if sample['phase'] == 'burst_start':
                burst += 1
            phases.setdefault((burst, sample['phase']), []).append(sample)
        for (burst, phase), samples in phases.items():
            row = dict(group=str(group), case=case['case'][0], burst=burst,
                       phase=phase, samples=len(samples))
            for field in ['curl_live', 'tls_live', 'app_bytes', 'scratch_bytes',
                          'physical', 'rss', 'fds']:
                row[field + '_sample_max'] = max(s[field] for s in samples)
            for field in ['curl_peak', 'tls_peak', 'max_physical', 'max_rss']:
                row[field + '_cumulative'] = max(s[field] for s in samples)
            rows.append(row)
with a.output.open('w') as output:
    writer = csv.DictWriter(output, fieldnames=list(rows[0]), lineterminator='\n')
    writer.writeheader()
    writer.writerows(rows)
