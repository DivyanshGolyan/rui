import hashlib,json,os,pathlib,re,statistics,subprocess,tempfile
P=pathlib.Path;base=P(__file__).parent;variants=[('split16',16384,0),('shared16',16384,1),('shared4',4096,1)]
executables={}
for name,window,reuse in variants:
 exe='/tmp/onepage-edit-'+name;executables[name]=exe
 subprocess.run(['cc','-O2','-Wall','-Wextra','-Wno-deprecated-declarations',f'-DW={window}',f'-DREUSE={reuse}',str(base/'tuning.c'),'-o',exe],check=True)
 env=dict(os.environ,EXACT_EDIT_EXE=exe,EXACT_EDIT_RESULTS='correctness-'+name+'.json')
 subprocess.run(['python3',str(base/'run.py')],env=env,stdout=subprocess.DEVNULL,check=True)
rows=[]
with tempfile.TemporaryDirectory(prefix='onepage-buffer-comparison-') as tmp:
 d=P(tmp)
 fixtures=[('64KiB',32766),('1MiB_many_lines',500000),('128MiB',67108862)]
 for fixture,linecount in fixtures:
  src=d/'source';old=d/'old';new=d/'new';out=d/'output';pre=hashlib.sha256();post=hashlib.sha256()
  with src.open('wb') as f:
   remaining=linecount
   while remaining:
    n=min(remaining,32768);b=b'x\n'*n;f.write(b);pre.update(b);post.update(b);remaining-=n
   f.write(b'end\n');pre.update(b'end\n');post.update(b'changed\n')
  old.write_bytes(b'end\n');new.write_bytes(b'changed\n')
  for repetition in range(5):
   order=variants[repetition%3:]+variants[:repetition%3]
   for name,window,reuse in order:
    r=subprocess.run(['/usr/bin/time','-l',executables[name],str(src),str(old),str(new),str(out)],capture_output=True,check=True)
    v=json.loads(r.stdout);assert v['preimage']==pre.hexdigest() and v['postimage']==post.hexdigest()
    # Check bytes actually written, separately from C's computed hash.
    h=hashlib.sha256()
    with out.open('rb') as f:
     while b:=f.read(65536):h.update(b)
    assert h.hexdigest()==post.hexdigest();assert out.stat().st_size==src.stat().st_size+4
    memory={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+(maximum resident set size|peak memory footprint)\s*$',r.stderr.decode(),re.M)}
    rows.append(dict(fixture=fixture,source_bytes=src.stat().st_size,repetition=repetition,variant=name,measurements=v,memory=memory));out.unlink()
summary=[]
for fixture,_ in [('64KiB',0),('1MiB_many_lines',0),('128MiB',0)]:
 for name,_,_ in variants:
  r=[x for x in rows if x['fixture']==fixture and x['variant']==name]
  summary.append(dict(fixture=fixture,variant=name,median_wall_ms=1000*statistics.median(x['measurements']['wall_seconds'] for x in r),median_cpu_ms=1000*statistics.median(x['measurements']['cpu_seconds'] for x in r),median_footprint=statistics.median(x['memory']['peak memory footprint'] for x in r),read_calls=r[0]['measurements']['read_calls'],write_calls=r[0]['measurements']['write_calls']))
(base/'tuning-results.json').write_text(json.dumps(dict(correctness_cases=36,benchmark_cases=len(rows),summary=summary,raw=rows),indent=2)+'\n')
print(json.dumps(summary,indent=2))
