"""Recompute headline values from preserved raw observations."""
import json, pathlib, statistics
rs=json.loads((pathlib.Path(__file__).parent/'results.json').read_text())['runs']
assert len(rs)==12 and all(r['passed'] and all(r['checks'].values()) for r in rs)
print('| Streams | Peak process MiB | CPU fraction of one core | Max descriptors | Longest owner work interval ms |')
print('| ---: | ---: | ---: | ---: | ---: |')
for n in (100,500,1000):
    rows=[r['client'] for r in rs if r['capacity']==n and r['cycles']==1 and r['seconds']==4]
    peak=statistics.median(c['closed']['lifetime_physical'] for c in rows)/2**20
    cpu=statistics.median(c['cpu_one_core_fraction'] for c in rows)
    print(f"| {n:,} | {peak:.2f} | {cpu:.3f} | {max(c['active']['fds'] for c in rows):,} | {max(c['max_owner_scan_ns'] for c in rows)/1e6:.2f} |")
print('Settled:',sum(r['client']['settled'] for r in rs),'exact stored bytes:',sum(r['stored_bytes'] for r in rs))
for r in rs[9:]:
    c=r['client']
    print({'index':r['index'],'seconds':r['seconds'],'cycles':r['cycles'],'relief':r['relief'],
           'peak_MiB':c['closed']['lifetime_physical']/2**20,
           'first_idle_MiB':c['first_cycle_idle']['physical']/2**20,
           'last_idle_MiB':c['final_cycle_idle']['physical']/2**20,
           'post_relief_idle_MiB':c['idle']['physical']/2**20})
