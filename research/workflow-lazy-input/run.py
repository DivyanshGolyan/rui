#!/usr/bin/env python3
"""Throwaway pinned-library comparison. No real providers or production Host."""
import hashlib,json,os,pathlib,platform,sqlite3,subprocess,tarfile,tempfile,statistics
HERE=pathlib.Path(__file__).resolve().parent
Q='N-V-__8AAC-eRACa__taXkae9pRIZde7nn8oQSxb9n9rhkFp'
S='N-V-__8AAGVtrgCcOcmjrOJnagmnRyMrcKaOo09KbU-vu8w8'
CACHE=pathlib.Path.home()/'.cache/zig/p'
BUILD=pathlib.Path(tempfile.gettempdir())/'onepage-lazy-input-native-build'
BUILD.mkdir(exist_ok=True)
for name in (Q,S):
 destination=BUILD/name
 if not destination.exists():
  target=BUILD/('extract-'+name);target.mkdir(exist_ok=True)
  with tarfile.open(CACHE/(name+'.tar.gz')) as tar:tar.extractall(target,filter='data')
  extracted=next(target.rglob('quickjs.h' if name==Q else 'sqlite3.h')).parent
  extracted.rename(destination)
flags=['-O2','-g','-std=gnu11','-funsigned-char','-D_GNU_SOURCE','-DQUICKJS_NG_BUILD=1','-I'+str(BUILD/Q),'-I'+str(BUILD/S)]
macros=['SQLITE_THREADSAFE=0','SQLITE_DEFAULT_PAGE_SIZE=4096','SQLITE_DEFAULT_FOREIGN_KEYS=1','SQLITE_MAX_MMAP_SIZE=0','SQLITE_DEFAULT_SYNCHRONOUS=3','SQLITE_DQS=0','SQLITE_OMIT_LOAD_EXTENSION=1','SQLITE_OMIT_SHARED_CACHE=1','SQLITE_TEMP_STORE=1','SQLITE_USE_URI=0','SQLITE_ENABLE_API_ARMOR=1']
for name,source in [(f,BUILD/Q/(f+'.c')) for f in ['quickjs','dtoa','libregexp','libunicode']]+[('sqlite3',BUILD/S/'sqlite3.c')]:
 obj=BUILD/(name+'.o')
 if not obj.exists():subprocess.run(['clang',*flags,*['-D'+m for m in macros],'-c',str(source),'-o',str(obj)],check=True,timeout=120)
child=BUILD/'child';host=BUILD/'host'
subprocess.run(['clang',*flags,str(HERE/'child.c'),*[str(BUILD/(x+'.o')) for x in ['quickjs','dtoa','libregexp','libunicode']],'-o',str(child)],check=True)
subprocess.run(['clang',*flags,str(HERE/'host.c'),str(BUILD/'sqlite3.o'),'-o',str(host)],check=True)
rows=[];checks=[]
with tempfile.TemporaryDirectory(prefix='onepage-lazy-input-fixtures-') as folder:
 root=pathlib.Path(folder)
 def run(label,backend='lazy',flow='parallel',n=16,size=4096,findings=2,availability='all',action='normal',service=1,store=None,rep=0):
  directory=store or root/(label+'-'+str(len(rows)));directory.mkdir(exist_ok=True)
  args=[str(host),str(directory),str(child),str(HERE/'workflow.js'),backend,flow,str(n),str(size),str(findings),availability,action,str(service)]
  p=subprocess.run(args,capture_output=True,text=True,timeout=90)
  if action=='crash':
   assert p.returncode==-9,(p.returncode,p.stdout,p.stderr)
  else:assert p.returncode==0,(args,p.returncode,p.stdout,p.stderr)
  records=[json.loads(line) for line in p.stdout.splitlines() if line.startswith('{')];assert len(records)==1,(p.stdout,p.stderr)
  data=records[0]
  if 'child_exit' in data:
   if data['child_exit']==0:assert data['child_signal']==0 and not data['timed_out']
   elif flow not in ('cpu','native-cpu','wall'):
    assert data['child_exit'] in (20,22,23) and not data['timed_out'] and data['child_signal']==0,(args,data,p.stderr)
   engine=[json.loads(line) for line in p.stderr.splitlines() if line.startswith('{')]
   data['engine']=engine[-1] if engine else None
   if data['child_exit']==23:assert 'workflow rejected: null' in p.stderr,(args,data,p.stderr)
   data['diagnostics']=[line for line in p.stderr.splitlines() if not line.startswith('{')]
   if engine:assert data['engine']['engine_remaining_after_teardown']==0
  data.update(label=label,backend=backend,flow=flow,branches=n,bytes_per_finding=size,findings=findings,availability=availability,action=action,service=service,rep=rep)
  rows.append(data)
  print(label,backend,flow,n,size,action,'exit',data.get('child_exit'),'new',data.get('created'),'decoded',data.get('engine',{}).get('decoded') if data.get('engine') else None,flush=True)
  assert not list(directory.glob('snapshot-*'))
  return data,directory
 # Semantic checks before the sweep.
 for backend in ('eager','lazy'):
  r,_=run('object-identity',backend,flow='identity',n=0,size=0)
  assert r['published'] and r['outcome']=={'fresh':backend=='lazy','samePromise':True}
 checks.append('separate same-key calls produce fresh objects with lazy lookup; repeated await preserves Promise identity; historical Map aliasing reproduced')
 for flow in ('keys','types'):
  r,_=run('typed-and-exact-keys',flow=flow,n=0,size=0)
  assert r['published'] and (r['outcome']=='keys match' if flow=='keys' else r['pending']==1)
 checks.append('exact Unicode/prefix/long keys, successful null, saved failure and missing result are distinct')
 r,store=run('partial',n=2,size=64,availability='partial')
 assert r['published'] and r['created']==2 and r['pending']==3 and r['engine']['decoded']==1
 c=sqlite3.connect(store/'store.db');assert c.execute("SELECT count(*) FROM calls WHERE key LIKE 'verify/1/%'").fetchone()[0]==0;c.close()
 r,_=run('after-partial',n=2,size=64,availability='all',store=store)
 assert r['published'] and r['created']==2 and r['pending']==4
 r,_=run('final',n=2,size=64,availability='final',store=store)
 assert r['outcome']==4 and r['pending']==0 and r['created']==0
 r,_=run('terminal-reopen',n=2,size=64,availability='keep',store=store);assert r['already_terminal_or_cancelled']
 checks.append('A progresses alone; B finishing after membership capture is absent until fresh capture; final output remains terminal on reopen')
 r,_=run('known-conflict',n=16,size=64,action='conflict');assert r['child_exit']==0 and not r['validated'] and r['created']==0 and not r['published']
 checks.append('known changed binding rejects complete output before any new operation is admitted')
 r,_=run('truncated-input',n=2,size=64,action='truncated');assert r['child_exit']==22 and not r['published'] and not r['created']
 checks.append('truncated captured body is explicit evaluation failure, never a missing answer')
 for flow in ('cpu','native-cpu','wall'):
  r,_=run('deadline',flow=flow,n=0,size=0)
  if flow=='wall':assert r['timed_out'] and r['child_signal']==9
  else:assert r['child_exit']==21 or r['child_signal']==24
  assert not r['published'] and not r['created']
 checks.append('JavaScript CPU loop and native CPU loop stopped by CPU policy; blocked native call killed by parent elapsed deadline')
 for action in ('crash','cancel','supersede'):
  r,store=run('admission-'+action,n=16,size=256,action=action)
  c=sqlite3.connect(store/'store.db');assert c.execute("SELECT count(*) FROM calls WHERE key LIKE 'verify/%'").fetchone()[0]==4
  assert c.execute('SELECT acknowledged FROM controls').fetchone()[0]==1
  assert c.execute('SELECT result FROM unrelated').fetchone()[0]=='settled'
  assert c.execute('SELECT published FROM run').fetchone()[0]==0;c.close()
  r,_=run('resume-'+action,n=16,size=256,availability='keep',store=store)
  if action in ('crash','supersede'):assert r['published'] and r['created']==28 and r['calls']==48 and r['pending']==32
  else:assert r['already_terminal_or_cancelled']
 checks.append('real Host-process kill after four admissions preserves prefix and serviced control/settlement; reopen reuses prefix and publishes complete dependencies; cancellation and generation replacement block further admissions')
 # Compare service vs deferred service without changing transaction grouping.
 for enabled in (0,1):
  r,_=run('service-comparison',n=512,size=256,service=enabled)
  assert r['published'] and r['created']==1024 and r['serviced_after_new_calls']==(4 if enabled else 1024)
 checks.append('driver actually commits unrelated control acknowledgement and settlement after four new admissions, versus only after 1024 in deferred baseline')
 cases=[(128,4096),(128,32768),(1024,4096),(2048,4096)]
 for rep in range(2):
  for n,size in cases:
   for flow in ('parallel','sequential','selective'):
    for backend in ('eager','lazy'):
     r,store=run('memory-comparison',backend,flow,n,size,rep=rep)
     if r['child_exit']==0:
      expected=(min(n,2) if flow=='selective' else n)*2
      assert r['published'] and r['created']==expected and r['pending']==expected
      c=sqlite3.connect(store/'store.db');assert c.execute("SELECT count(*) FROM calls WHERE key LIKE 'verify/%' AND input=?",('x'*size,)).fetchone()[0]==expected;c.close()
      if backend=='lazy':assert r['engine']['preload_decoded']==0 and r['engine']['decoded']==(min(n,2) if flow=='selective' else n)
     else:assert not r['published'] and not r['created']
 checks.append('successful full-text verifier admissions preserve exact generated message lengths and complete pending sets; failed evaluations publish nothing')
 summary=[]
 for n,size in cases:
  for flow in ('parallel','sequential','selective'):
   for backend in ('eager','lazy'):
    group=[r for r in rows if r['label']=='memory-comparison' and (r['branches'],r['bytes_per_finding'],r['flow'],r['backend'])==(n,size,flow,backend)]
    entry=dict(branches=n,bytes_per_finding=size,flow=flow,backend=backend,runs=len(group),successes=sum(r['published'] for r in group))
    for key in ['membership_ms','materialize_ms','data_bytes','directory_bytes','evaluation_ms','validation_ms','admission_ms','publication_ms','sampled_combined_peak','sampled_child_peak','output_bytes']:entry[key]=statistics.median(r[key] for r in group)
    for key in ['engine_backing_peak','native_body_peak','decoded','decoded_bytes','directory_probes','cpu_ms']:entry[key]=statistics.median(r['engine'][key] for r in group if r['engine'])
    summary.append(entry)
 payload={'scope':'throwaway standalone C Storage Owner and QuickJS, not production integration','platform':platform.platform(),'quickjs_archive':Q,'sqlite_archive':S,'child_sha256':hashlib.sha256(child.read_bytes()).hexdigest(),'host_sha256':hashlib.sha256(host.read_bytes()).hexdigest(),'checks':checks,'rows':rows,'summary':summary}
 (HERE/'results.json').write_text(json.dumps(payload,indent=2)+'\n')
 print(json.dumps(summary,indent=2))
