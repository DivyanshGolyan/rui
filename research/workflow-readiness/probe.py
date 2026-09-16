"""Throwaway readiness-cost probe, not a production schema or Host benchmark."""
import json, sqlite3, statistics, tempfile, time, platform, os
from pathlib import Path

N = int(os.environ.get('PROBE_WAITERS', '100000'))
FANOUTS = tuple(map(int, os.environ.get('PROBE_FANOUTS', '0,1,1000,100000').split(',')))
REPEATS = 7
output = {'sqlite': sqlite3.sqlite_version, 'platform': platform.platform(),
          'unrelated_waiters': N, 'repeats': REPEATS, 'cases': []}
with tempfile.TemporaryDirectory(prefix='rui-readiness-') as root:
    for fanout in FANOUTS:
        db = sqlite3.connect(str(Path(root) / f'{fanout}.db'))
        db.executescript('''
          PRAGMA journal_mode=DELETE;
          PRAGMA synchronous=EXTRA;
          PRAGMA mmap_size=0;
          PRAGMA cache_size=-256;
          CREATE TABLE work(id INTEGER PRIMARY KEY, result INTEGER);
          CREATE INDEX completed_work ON work(id) WHERE result IS NOT NULL;
          CREATE TABLE dependency(run_id INTEGER PRIMARY KEY, work_id INTEGER NOT NULL);
          CREATE INDEX by_work ON dependency(work_id,run_id);
          CREATE TABLE ready(run_id INTEGER PRIMARY KEY);
          INSERT INTO work VALUES(1,NULL),(2,NULL);
        ''')
        db.executemany('INSERT INTO dependency VALUES(?,2)', ((i+1,) for i in range(N)))
        db.executemany('INSERT INTO dependency VALUES(?,1)', ((N+i+1,) for i in range(fanout)))
        # Saved results that have no current dependent are a separate history cost.
        db.executemany('INSERT INTO work VALUES(?,7)', ((i+3,) for i in range(N)))
        db.commit()
        db.execute('ANALYZE')
        db.commit()
        result = {'dependents': fanout, 'samples_ms': {}}
        for mode in ('result_only', 'result_and_ready'):
            samples = []
            for _ in range(REPEATS):
                db.execute('UPDATE work SET result=NULL WHERE id=1')
                db.execute('DELETE FROM ready')
                db.commit()
                start = time.perf_counter_ns()
                db.execute('BEGIN')
                db.execute('UPDATE work SET result=7 WHERE id=1')
                if mode == 'result_and_ready':
                    db.execute('INSERT OR IGNORE INTO ready SELECT run_id FROM dependency WHERE work_id=1')
                db.commit()
                samples.append((time.perf_counter_ns()-start)/1e6)
                expected = fanout if mode == 'result_and_ready' else 0
                assert db.execute('SELECT count(*) FROM ready').fetchone()[0] == expected
            result['samples_ms'][mode] = samples
        queries = {
          'targeted_first': 'SELECT run_id FROM dependency WHERE work_id=1 LIMIT 1',
          'derived_first': '''SELECT d.run_id FROM dependency d JOIN work w ON w.id=d.work_id
                              WHERE w.result IS NOT NULL LIMIT 1''',
          'ready_first': 'SELECT run_id FROM ready LIMIT 1',
        }
        result['plans'] = {}
        result['query_cpu_ms'] = {}
        for name, query in queries.items():
            result['plans'][name] = [row[3] for row in db.execute('EXPLAIN QUERY PLAN '+query)]
            samples = []
            cpu_samples = []
            for _ in range(REPEATS):
                cpu_start = time.process_time_ns()
                start = time.perf_counter_ns()
                rows = db.execute(query).fetchall()
                cpu_samples.append((time.process_time_ns()-cpu_start)/1e6)
                samples.append((time.perf_counter_ns()-start)/1e6)
                assert bool(rows) == bool(fanout)
            result['samples_ms'][name] = samples
            result['query_cpu_ms'][name] = cpu_samples
        result['median_ms'] = {k: round(statistics.median(v), 4) for k,v in result['samples_ms'].items()}
        output['cases'].append(result)
        db.close()
print(json.dumps(output, indent=2))
