#!/usr/bin/env python3
import pathlib,tempfile,subprocess,json,hashlib
here=pathlib.Path(__file__).resolve().parent
rows=[]
with tempfile.TemporaryDirectory(prefix='onepage-bash-large-') as d:
 root=pathlib.Path(d);exe=root/'probe'
 subprocess.run(['clang','-O2','-Wall','-Wextra','-Werror',str(here/'probe.c'),'-o',str(exe)],check=True)
 for size in [65536,1048576,1048576,65536]:
  work=root/str(len(rows));work.mkdir()
  p=subprocess.Popen([str(exe),'100',str(size),'output','1',str(8*1024**3),str(work)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
  try:out,err=p.communicate(timeout=120)
  except subprocess.TimeoutExpired:p.terminate();p.communicate(timeout=10);raise
  assert p.returncode==0,(out,err)
  r=json.loads(out);assert r['completed']==100 and r['captured_bytes']==200*size and r['final_fds']==r['baseline_fds']
  assert not list(work.iterdir());r['bytes_per_stream']=size;rows.append(r)
(here/'large-output-results.json').write_text(json.dumps({'source_sha256':hashlib.sha256((here/'probe.c').read_bytes()).hexdigest(),'rows':rows},indent=2)+'\n')
print(json.dumps(rows))
