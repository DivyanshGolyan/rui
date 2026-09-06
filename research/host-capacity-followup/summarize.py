"""Recompute measured timing and memory summaries without running load."""
import json,pathlib,statistics
p=pathlib.Path(__file__).parent
rows=[]
for file in ('results.json','refined-results.json'):
    data=json.loads((p/file).read_text())
    assert all(r['passed'] and all(r['checks'].values()) for r in data['runs'])
    rows+=data['runs']
print('| Capacity | Mode | Stop commit ms | Transfer removed ms | Full release ms | Max full release ms | Removal to release ms |')
print('| ---: | --- | ---: | ---: | ---: | ---: | ---: |')
for n in (100,500,1000):
    for m in (1,2,3):
        controls=[r['client']['control'] for r in rows if r['capacity']==n and r['control_mode']==m]
        assert len(controls)==3
        delays=[[ (c[k]-c['request_ns'])/1e6 for c in controls] for k in ('commit_ns','removed_ns','released_ns')]
        vals=[statistics.median(d) for d in delays]
        gap=statistics.median((c['released_ns']-c['removed_ns'])/1e6 for c in controls)
        print(f'| {n:,} | {m} | {vals[0]:.2f} | {vals[1]:.2f} | {vals[2]:.2f} | {max(delays[2]):.2f} | {gap:.2f} |')
print('Cases:',len(rows),'operations:',sum(r['client']['settled'] for r in rows),
      'cancelled:',sum(r['client']['control']['cancelled_rows'] for r in rows))
for r in rows:
    if r['control_mode']: continue
    print('| Phase | Live malloc MiB | Allocator reservation MiB | Physical footprint MiB |')
    print('| --- | ---: | ---: | ---: |')
    for line in r['client_stderr'].splitlines():
        d=json.loads(line)
        if 'memory_phase' in d:
            print(f"| {d['memory_phase']} {d['cycle']} | {d['live_malloc_bytes']/2**20:.2f} | {d['allocator_reserved_bytes']/2**20:.2f} | {d['physical_bytes']/2**20:.2f} |")
