import json, pathlib, subprocess, tempfile, random, platform, hashlib
root=pathlib.Path(__file__).resolve().parent
probe=root/'research/matklad-experiments/inspection-latency'
cases=[('1000-small',1000,128,0),('10000-small',10000,128,0),('100000-small',100000,128,0),('100000-wide',100000,1024,0),('10000-slow-scratch',10000,128,1)]
jobs=[(c,r) for c in cases for r in range(3)];random.Random(152).shuffle(jobs)
results=[]
with tempfile.TemporaryDirectory() as td:
 for (name,n,w,delay),rep in jobs:
  db=pathlib.Path(td)/'fixture.db'
  args=[str(n),str(w),'100',str(delay),'0','0','1']
  subprocess.run([str(probe/'generated/probe'),str(db),'seed',*args],check=True,capture_output=True)
  p=subprocess.run([str(probe/'generated/probe'),str(db),'run',*args],check=True,capture_output=True,text=True)
  events=[json.loads(x) for x in p.stdout.splitlines()]
  assert len(events)==9 and events[-1]['complete']==8 and events[-1]['failed']==0
  assert all(x['rows']==n and not x['aborted'] for x in events[:-1])
  assert events[-1]['control_ack_ms']>=events[0]['ms']
  results.append(dict(case=name,repeat=rep,args=args,events=events))
  print(name,rep,events[-1]['control_ack_ms'],flush=True)
  db.unlink()
output=dict(platform=platform.platform(),compiler=subprocess.check_output(['cc','--version'],text=True),revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),probe_sha256=hashlib.sha256((probe/'probe.c').read_bytes()).hexdigest(),scope='Sequential synthetic single-owner captures and SQLite control-marker commits; not real Stop or Host. Other machine activity uncontrolled.',results=results)
(root/'sequential-results.json').write_text(json.dumps(output,indent=2)+'\n')
