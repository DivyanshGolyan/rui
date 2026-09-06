"""Validate recorded phase partitions and reproduce the comparison tables."""
import hashlib
import json
from pathlib import Path
import statistics
import subprocess

P = Path(__file__).resolve().parent
for filename in ('results.json', 'socket-results.json'):
    data = json.loads((P / filename).read_text())
    rows = data['runs']
    assert len(rows) == 18 and all(r['passed'] and all(r['checks'].values()) for r in rows)
    for name, expected in data['metadata']['source_hashes'].items():
        source = (subprocess.check_output(['git', 'show', f'7439cb6:research/host-reactor-cancellation/{name}'], cwd=P)
                  if filename == 'results.json' else (P / name).read_bytes())
        assert hashlib.sha256(source).hexdigest() == expected, name
    for row in rows:
        c = row['client']['control']
        assert sum(row['client']['reactor_control']['pending_phase_ns']) == c['removed_ns'] - c['commit_ns']
    print(filename)
    print('| Streams | Mode | Request to release median / max ms | Pending network phase median ms | Peak physical median MiB | CPU median cores |')
    print('| ---: | ---: | ---: | ---: | ---: | ---: |')
    for capacity in (100, 500, 1000):
        for mode in sorted({r['reactor_mode'] for r in rows}):
            group = [r['client'] for r in rows if r['capacity'] == capacity and r['reactor_mode'] == mode]
            assert len(group) == 3
            release = [(c['control']['released_ns'] - c['control']['request_ns']) / 1e6 for c in group]
            med = lambda fn: statistics.median(fn(c) for c in group)
            print(f'| {capacity} | {mode} | {statistics.median(release):.2f} / {max(release):.2f} | '
                  f'{med(lambda c: c["reactor_control"]["pending_phase_ns"][4] / 1e6):.3f} | '
                  f'{med(lambda c: c["closed"]["lifetime_physical"] / 1048576):.2f} | '
                  f'{med(lambda c: c["cpu_one_core_fraction"]):.3f} |')
