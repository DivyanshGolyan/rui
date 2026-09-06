from pathlib import Path
import hashlib,json,statistics
p=Path(__file__).resolve().parent;d=json.loads((p/'tls-results.json').read_text())
for f,expected in d['metadata']['source_hashes'].items(): assert hashlib.sha256((p/f).read_bytes()).hexdigest()==expected
assert len(d['runs'])==6
for r in d['runs']:
 assert r['passed'] and all(r['checks'].values())
 c=r['client']; t=c['control'];assert sum(c['reactor_control']['pending_phase_ns'])==t['removed_ns']-t['commit_ns']
for size in (65536,16384):
 cs=[r['client'] for r in d['runs'] if r['upload_buffer']==size];assert len(cs)==3
 med=lambda f:statistics.median(f(c) for c in cs)
 print(json.dumps(dict(upload_bytes=size,peak_mib=med(lambda c:c['closed']['lifetime_physical']/1048576),cpu_cores=med(lambda c:c['cpu_one_core_fraction']),release_ms=med(lambda c:(c['control']['released_ns']-c['control']['request_ns'])/1e6),wall_seconds=med(lambda c:c['wall_seconds']))))
