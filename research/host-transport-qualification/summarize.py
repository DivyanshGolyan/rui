from pathlib import Path
import hashlib,json,statistics
p=Path(__file__).resolve().parent
rows=[]
for name in ('tls-results.json','tls-repeat-2.json','tls-repeat-3.json'):
 d=json.loads((p/name).read_text())
 for source, expected in d['metadata']['source_hashes'].items():
  assert hashlib.sha256((p/source).read_bytes()).hexdigest()==expected
 for r in d['runs']:
  assert r['passed'] and all(r['checks'].values())
  c=r['client'];t=c['control']; assert sum(c['reactor_control']['pending_phase_ns'])==t['removed_ns']-t['commit_ns']
  row=dict(source=name,capacity=r['capacity'],release_ms=(t['released_ns']-t['request_ns'])/1e6,peak_mib=c['closed']['lifetime_physical']/1048576,cpu_cores=c['cpu_one_core_fraction'])
  rows.append(row); print(json.dumps(row))
large=[r for r in rows if r['capacity']==1000]
print('1000-stream medians:',{k:statistics.median(r[k] for r in large) for k in ('release_ms','peak_mib','cpu_cores')})
