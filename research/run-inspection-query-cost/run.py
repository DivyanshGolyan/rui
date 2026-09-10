#!/usr/bin/env python3
"""Native pinned-SQLite scratch query experiment; not the production Host."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import re
import statistics
import subprocess
import tarfile
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = HERE / 'generated'
OUT.mkdir(exist_ok=True)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output-dir', type=Path, default=OUT / 'reproduction')
args = parser.parse_args()
report_dir = args.output_dir.resolve()
report_dir.mkdir(parents=True, exist_ok=True)
env = subprocess.check_output(['zig', 'env'], text=True)
cache = Path(re.search(r'\.global_cache_dir = "([^"]+)"', env)[1])
package = re.search(r'\.sqlite = .*?\.hash = "([^"]+)"', (ROOT / 'build.zig.zon').read_text(), re.S)[1]
archive = cache / 'p' / (package + '.tar.gz')
if not archive.exists():
    subprocess.run(['zig', 'build', '--fetch=all'], cwd=ROOT, check=True)
if not (OUT / 'sqlite').exists():
    with tarfile.open(archive) as f:
        f.extractall(OUT / 'sqlite', filter='data')
source = next((OUT / 'sqlite').rglob('sqlite3.c'))
config = (ROOT / 'build.zig').read_text().split('fn configureSqlite(', 1)[1].split('\nfn ', 1)[0]
macros = ['-D' + k + '=' + v for k, v in re.findall(r'addCMacro\("([^"]+)", "([^"]+)"\)', config)]
subprocess.run(['cc', '-O2', '-c', str(source), *macros, '-o', str(OUT / 'sqlite.o')], check=True)
binary = OUT / 'probe'
subprocess.run(['cc', '-O2', '-Wall', '-Wextra', '-Werror', '-I' + str(source.parent),
                str(HERE / 'probe.c'), str(OUT / 'sqlite.o'), '-o', str(binary)], check=True)

# name, unique returned Turns, resolved Operations per returned Turn,
# unrelated Turns, unadmitted fanout (admitted/retry cases stay at one), content bytes, partial index
cases = [
    ('baseline', 18, 0, 0, 1, 32, 1),
    ('history-1000', 18, 1000, 0, 1, 32, 1),
    ('history-50000', 18, 50000, 0, 1, 32, 1),
    ('history-50000-full-index-control', 18, 50000, 0, 1, 32, 0),
    ('unrelated-100000', 18, 0, 100000, 1, 32, 1),
    ('payload-4096', 18, 1000, 0, 1, 4096, 1),
    ('members-1000', 1000, 10, 0, 1, 32, 1),
    ('members-10000', 10000, 10, 0, 1, 32, 1),
    ('members-100000', 100000, 10, 0, 1, 32, 1),
    ('fanout-1000', 18, 0, 0, 1000, 32, 1),
    ('fanout-10000', 18, 0, 0, 10000, 32, 1),
    ('ready-only-1', 1, 0, 0, 1, 32, 1),
    ('ready-only-100000', 1, 0, 0, 100000, 32, 1),
]
random.Random(907).shuffle(cases)
results = []
plans = []
with tempfile.TemporaryDirectory(prefix='onepage-query-cost-') as td:
    td = Path(td)
    for name, members, history, unrelated, fanout, payload, index in cases:
        db = td / 'scratch.sqlite'
        args = list(map(str, (members, history, unrelated, fanout, payload, index)))
        subprocess.run([binary, db, 'seed', *args, '0'], check=True, capture_output=True, timeout=180)
        size = db.stat().st_size
        plan = subprocess.check_output([binary, db, 'explain', *args, '0'], text=True)
        plans.append(f'## {name}\n\n{plan}')
        observations = []
        for repeat in range(3):
            modes = [0, 1] if repeat % 2 == 0 else [1, 0]
            for encode in modes:
                child_env = dict(os.environ)
                report = td / 'report.jsonl'
                if name == 'baseline' and repeat == 0 and encode:
                    child_env['ONEPAGE_QUERY_REPORT'] = str(report)
                completed = subprocess.run([binary, db, 'run', *args, str(encode)],
                    text=True, capture_output=True, check=True, env=child_env, timeout=180)
                samples = [json.loads(line) for line in completed.stdout.splitlines()]
                for sample in samples:
                    sample['repeat'] = repeat
                    assert sample['members'] == members and sample['sorts'] == 0
                    sample['sqlite_cache_start'] = 'fresh-connection' if sample['pass'] == 0 else 'reused-connection'
                observations.extend(samples)
                if report.exists():
                    rows = [json.loads(line) for line in report.read_text().splitlines()]
                    assert rows[-1]['end'] is True and rows[-1]['members'] == members
                    assert len([r for r in rows if 'condition' in r]) == members
                    assert len([r for r in rows if 'permission' in r]) == rows[-1]['permissions'] == 4
                    assert [r['member'] for r in rows if 'condition' in r] == list(range(1, members + 1))
                    assert not rows[-2].get('end', False)
                    report.unlink()
        results.append(dict(name=name, members=members, history_per_turn=history, unrelated_turns=unrelated,
            fanout=fanout, payload_bytes=payload, partial_index=bool(index), database_bytes=size, samples=observations))
        encoded = [s for s in observations if s['encoded']]
        print(name, 'capture_ms=', round(statistics.median(s['capture_ms'] for s in encoded), 3),
              'VM=', encoded[0]['vm_steps'], 'bytes=', encoded[0]['bytes'], flush=True)
        db.unlink()

provenance = dict(platform=platform.platform(), machine=platform.machine(),
    sqlite_package=package, sqlite_macros=macros,
    compiler=subprocess.check_output(['cc', '--version'], text=True),
    source_commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
    hashes={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in
        [HERE / 'probe.c', HERE / 'run.py', ROOT / 'ARCHITECTURE.md', ROOT / 'build.zig']},
    cases=results)
(report_dir / 'results.json').write_text(json.dumps(provenance, indent=2) + '\n')
(report_dir / 'query-plans.txt').write_text('\n'.join(plans))
