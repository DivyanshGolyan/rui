#!/usr/bin/env python3
"""Throwaway real-child capture probe. No production, provider or machine config changes."""
import json,pathlib,platform,subprocess,tempfile,time,statistics,hashlib
here=pathlib.Path(__file__).resolve().parent
rows=[]
with tempfile.TemporaryDirectory(prefix='onepage-bash-probe-') as d:
 root=pathlib.Path(d);exe=root/'probe'
 subprocess.run(['clang','-O2','-Wall','-Wextra','-Werror',str(here/'probe.c'),'-o',str(exe)],check=True)
 def case(n,size,mode='output',waves=1,quota=8*1024**3,rep=0):
  work=root/f'case-{len(rows)}';work.mkdir()
  p=subprocess.Popen([str(exe),str(n),str(size),mode,str(waves),str(quota),str(work)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
  try:out,err=p.communicate(timeout=120)
  except subprocess.TimeoutExpired:
   p.terminate();p.communicate(timeout=10);raise
  assert p.returncode==0,(p.returncode,out,err)
  r=json.loads(out);r.update(mode=mode,bytes_per_stream=size,waves=waves,quota=quota,repeat=rep)
  assert r['ready']==r['started']
  assert r['final_fds']==r['baseline_fds'] and not list(work.iterdir())
  assert r['peak_scratch']<=quota
  if not r['launch_errno']:assert r['started']==n*waves
  if mode=='hold':assert r['cancelled']==r['started']
  elif quota<2*size*n:assert r['capture_failures']>0
  else:assert r['completed']==r['started'] and r['captured_bytes']==r['started']*2*size
  rows.append(r);print(json.dumps(r),flush=True)
 # Correctness/failure cases first.
 case(10,0,'eof');case(10,0,'hold');case(10,65536,quota=8192)
 case(100,65536,waves=5)
 for rep,order in enumerate(([100,500,1000],[500,1000,100],[1000,100,500])):
  for n in order:
   for size in ([0,65536] if rep%2==0 else [65536,0]):case(n,size,rep=rep)
report={'platform':platform.platform(),'source_sha256':hashlib.sha256((here/'probe.c').read_bytes()).hexdigest(),'rows':rows,'method':'Parent-only physical footprint sampled before and during real child cohorts; fresh processes except the five-wave churn case. Bash execs a tiny fixture producer; one shared copying window; stdout/stderr unlinked scratch. No fsync/SQLite, provider or production Host. FD observer storage is pre-touched before baseline.','limitations':['Sampled footprint can miss brief peaks; ru_maxrss is OS lifetime peak RSS, not physical footprint.','The 56-byte owner is a prototype shape, not final Host custody state. Shared poll table and buffer are separate; no allocator instrumentation.','Kernel and child memory excluded; source fixture replaces Bash using exec after real shell launch.','Capture writes are synchronous and callbacks are not production controls; no saturation/latency guarantee.','No large command/input materialization, descendants, permissions or effect recovery. Full child cohorts are ready before release.','No machine-wide limits changed; launch failures are reported, not successful capacity claims.']}
(here/'results.json').write_text(json.dumps(report,indent=2)+'\n')
summary=[]
for n in [100,500,1000]:
 for size in [0,65536]:
  a=[r for r in rows if r['requested']==n and r['bytes_per_stream']==size and r['waves']==1 and r['mode']=='output' and r['quota']==8*1024**3]
  summary.append(dict(children=n,bytes_per_stream=size,repetitions=len(a),launch_errors=[r['launch_errno'] for r in a],achieved=min(r['cohort_max'] for r in a),peak_mib=statistics.median(r['sampled_peak_footprint']/1048576 for r in a),added_kib=statistics.median((r['sampled_peak_footprint']-r['baseline_footprint'])/1024 for r in a),retained_mib=statistics.median(r['retained_footprint']/1048576 for r in a),peak_fds=max(r['peak_fds'] for r in a),peak_threads=max(r['peak_threads'] for r in a)))
(here/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
