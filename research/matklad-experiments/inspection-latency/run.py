#!/usr/bin/env python3
"""Pinned SQLite native inspection scheduling/abort sensitivity, not the Host."""
import argparse,os,hashlib,json,pathlib,random,re,subprocess,tempfile,tarfile,platform
ap=argparse.ArgumentParser();ap.add_argument('--bytewise',action='store_true');opts=ap.parse_args()
H=pathlib.Path(__file__).resolve().parent
R=H.parents[2]
probe=H/('bytewise-probe.c' if opts.bytewise else 'probe.c')
O=H/'generated';O.mkdir(exist_ok=True)
env=subprocess.check_output(['zig','env'],text=True)
cache=pathlib.Path(re.search(r'\.global_cache_dir = "([^"]+)"',env)[1])
pkg=re.search(r'\.sqlite = .*?\.hash = "([^"]+)"',(R/'build.zig.zon').read_text(),re.S)[1]
archive=cache/'p'/(pkg+'.tar.gz')
if not archive.exists():subprocess.run(['zig','build','--fetch=all'],cwd=R,check=True)
if not (O/'sqlite').exists():
 with tarfile.open(archive) as f:f.extractall(O/'sqlite',filter='data')
source=next((O/'sqlite').rglob('sqlite3.c'))
config=(R/'build.zig').read_text().split('fn configureSqlite(',1)[1].split('\nfn ',1)[0]
macros=['-D'+k+'='+v for k,v in re.findall(r'addCMacro\("([^"]+)", "([^"]+)"\)',config)]
binary=O/'probe'
subprocess.run(['cc','-O2','-c',str(source),*macros,'-o',str(O/'sqlite.o')],check=True)
subprocess.run(['cc','-O2','-Wall','-Wextra','-Werror','-I'+str(source.parent),str(probe),str(O/'sqlite.o'),'-o',str(binary)],check=True)
# Width includes escape-heavy strings. Delays emulate scratch service stalls per batch.
cases=[
 ('small',1000,128,100,0,0,0,1),
 ('medium',10000,128,100,0,0,0,1),
 ('large',100000,128,100,0,0,0,1),
 ('wide',100000,1024,100,0,0,0,1),
 ('settlements-after-backlog',10000,128,100,0,0,0,0),
 ('slow-scratch',10000,128,100,1,0,0,1),
 ('deadline-10ms',100000,128,100,0,10,0,1),
 ('slow-deadline-10ms',10000,128,100,1,10,0,1),
 ('stalled-batch-50ms',10000,128,100,50,10,0,1),
 ('byte-budget-1MiB',100000,128,100,0,0,1048576,1),
 ('batch-10',10000,128,10,0,0,0,1),
 ('batch-1000',10000,128,1000,0,0,0,1),
]
rows=[]
with tempfile.TemporaryDirectory(prefix='onepage-inspection-') as td:
 td=pathlib.Path(td)
 jobs=[(case,rep) for case in cases for rep in range(3)]
 random.Random(906).shuffle(jobs)
 for case,rep in jobs:
  name,n,w,b,delay,budget,cap,fair=case
  db=td/'fixture.sqlite'
  args=[str(n),str(w),str(b),str(delay),str(budget),str(cap),str(fair)]
  subprocess.run([binary,db,'seed',*args],check=True,capture_output=True,timeout=120)
  export=td/'report.jsonl'
  child_env=dict(os.environ)
  if name=='small' and rep==0 and not opts.bytewise:child_env['ONEPAGE_PROBE_REPORT']=str(export)
  p=subprocess.run([binary,db,'run',*args],capture_output=True,text=True,timeout=120,env=child_env)
  if export.exists():
   lines=[json.loads(x) for x in export.read_bytes().splitlines()]
   assert lines[0]=={'revision':2} and lines[-1]=={'end':True,'revision':2,'count':n}
   assert len(lines)==n+2
   for i,row in enumerate(lines[1:-1],1):
    assert row['seq']==i and row['binding']==''.join(['\n','"','\\','b'][j%4] for j in range(w))
   # A truncated delivery must fail the terminal-frame oracle.
   assert lines[-2].get('end') is not True
   export.unlink()
  assert p.returncode==0,(name,p.stderr)
  events=[json.loads(x) for x in p.stdout.splitlines()]
  summary=events[-1];captures=events[:-1]
  assert len(captures)==8
  assert summary['complete']+summary['failed']==8
  if budget or cap: assert summary['failed']==8,(name,summary)
  else: assert summary['complete']==8,(name,summary)
  assert summary['control_ack_ms']>=captures[0]['ms']
  if not fair:assert summary['settlement_ack_ms']>=sum(x['ms'] for x in captures)
  if fair:assert summary['settlement_ack_ms']>=summary['control_ack_ms']
  rows.append(dict(case=name,repeat=rep,records=n,width=w,batch=b,delay_ms=delay,budget_ms=budget,byte_budget=cap,fair=bool(fair),captures=captures,summary=summary))
  db.unlink()
  print(name,rep,round(summary['control_ack_ms'],2),round(summary['settlement_ack_ms'],2),flush=True)
report=dict(platform=platform.platform(),source_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip(),sqlite_package=pkg,sqlite_macros=macros,probe_sha256=hashlib.sha256(probe.read_bytes()).hexdigest(),cases=rows)
(H/('bytewise-results.json' if opts.bytewise else 'results.json')).write_text(json.dumps(report,indent=2)+'\n')
