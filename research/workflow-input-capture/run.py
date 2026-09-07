#!/usr/bin/env python3
"""Throwaway actual pinned C libraries; no providers, no production Host."""
import json, pathlib, subprocess, tempfile, tarfile, statistics, platform, hashlib
HERE=pathlib.Path(__file__).resolve().parent
CACHE=pathlib.Path.home()/'.cache/zig/p'
Q='N-V-__8AAC-eRACa__taXkae9pRIZde7nn8oQSxb9n9rhkFp'
S='N-V-__8AAGVtrgCcOcmjrOJnagmnRyMrcKaOo09KbU-vu8w8'
rows=[]
with tempfile.TemporaryDirectory(prefix='onepage-input-probe-') as folder:
 root=pathlib.Path(folder)
 for name,archive in [('q',Q),('s',S)]:
  dest=root/name;dest.mkdir()
  with tarfile.open(CACHE/(archive+'.tar.gz')) as tar: tar.extractall(dest,filter='data')
 q=next((root/'q').rglob('quickjs.h')).parent;s=next((root/'s').rglob('sqlite3.c')).parent
 exe=root/'probe'
 cmd=['clang','-O2','-std=gnu11','-funsigned-char','-D_GNU_SOURCE','-DQUICKJS_NG_BUILD=1','-DSQLITE_THREADSAFE=0','-DSQLITE_DEFAULT_PAGE_SIZE=4096','-DSQLITE_DEFAULT_FOREIGN_KEYS=1','-DSQLITE_MAX_MMAP_SIZE=0','-DSQLITE_DEFAULT_SYNCHRONOUS=3','-DSQLITE_DQS=0','-DSQLITE_OMIT_LOAD_EXTENSION=1','-DSQLITE_OMIT_SHARED_CACHE=1','-DSQLITE_TEMP_STORE=1','-DSQLITE_USE_URI=0','-DSQLITE_ENABLE_API_ARMOR=1','-I'+str(q),'-I'+str(s),str(HERE/'probe.c'),*[str(q/x) for x in ['quickjs.c','dtoa.c','libregexp.c','libunicode.c']],str(s/'sqlite3.c'),'-o',str(exe)]
 subprocess.run(cmd,check=True,timeout=120)
 cases=[(2,64,2),(16,4096,2),(128,4096,2),(512,4096,2),(1024,4096,2),(2048,4096,2),(128,32768,2),(16,64,128)]
 for rep in range(3):
  for b,size,findings in cases:
   case=root/f'{rep}-{b}-{size}-{findings}';case.mkdir()
   result=subprocess.run([str(exe),str(case),str(b),str(size),str(findings),str(HERE/'workflow.js')],capture_output=True,text=True,timeout=90)
   assert result.returncode==0,(b,size,findings,result.stdout,result.stderr)
   got=[dict(json.loads(line),rep=rep) for line in result.stdout.splitlines()]
   assert got and got[0]['success'],(result.stdout,result.stderr)
   if b<=128 and size<=4096 and findings==2: assert len(got)==4 and all(x['success'] for x in got)
   for row in got:
    row['child_diagnostics']=result.stderr.splitlines()
    if not row['success']: assert row['child_exit']==20 and row['child_signal']==0 and 'out of memory' in result.stderr,(row,result.stderr)
   rows.extend(got)
   print(rep,b,size,findings,'phases',len(got),'last_success',got[-1]['success'],flush=True)
 summary=[]
 for b,size,f in cases:
  for phase in range(4):
   group=[r for r in rows if (r['branches'],r['bytes_per_finding'],r['findings'],r['phase'])==(b,size,f,phase)]
   if not group:continue
   entry=dict(branches=b,bytes_per_finding=size,findings=f,phase=phase,runs=len(group),successful=sum(r['success'] for r in group))
   for k in ['capture_bytes','capture_ms','eval_ms','validation_ms','admission_ms','longest_admission_ms','publication_ms','child_peak_rss_bytes','parent_peak_rss_bytes']:entry[k]=statistics.median(r[k] for r in group)
   summary.append(entry)
 payload={'scope':'throwaway C harness, pinned libraries, synthetic results; not production Host qualification','platform':platform.platform(),'sqlite_archive':S,'quickjs_archive':Q,'binary_sha256':hashlib.sha256(exe.read_bytes()).hexdigest(),'rows':rows,'summary':summary}
 (HERE/'results.json').write_text(json.dumps(payload,indent=2)+'\n')
 print(json.dumps(summary,indent=2))
