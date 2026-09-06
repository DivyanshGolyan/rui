from pathlib import Path
import hashlib,json
p=Path(__file__).resolve().parent;d=json.loads((p/'tls-results.json').read_text())
for f,h in d['metadata']['source_hashes'].items():assert hashlib.sha256((p/f).read_bytes()).hexdigest()==h
assert len(d['runs'])==6
print('| Request KiB | Upload buffer KiB | Peak physical MiB | Work seconds | CPU cores | Request-to-release ms |')
print('| ---: | ---: | ---: | ---: | ---: | ---: |')
for r in d['runs']:
 assert r['passed'] and all(r['checks'].values())
 c=r['client'];t=c['control'];assert sum(c['reactor_control']['pending_phase_ns'])==t['removed_ns']-t['commit_ns']
 print(f'| {r["request_bytes"]//1024} | {r["upload_buffer"]//1024} | {c["closed"]["lifetime_physical"]/1048576:.2f} | {c["wall_seconds"]:.3f} | {c["cpu_one_core_fraction"]:.3f} | {(t["released_ns"]-t["request_ns"])/1e6:.3f} |')
u=json.loads((p/'transcript-usage.json').read_text());assert hashlib.sha256((p/'analyze_transcripts.py').read_bytes()).hexdigest()==u['analysis_source_sha256']
