#!/usr/bin/env python3
import pathlib,subprocess,json,re,tempfile,time,tarfile,hashlib
HERE=pathlib.Path(__file__).resolve().parent
ROOT=HERE.parents[2]
OUT=HERE/'generated';OUT.mkdir(exist_ok=True)
sqlite_dir=OUT/'sqlite'
if not sqlite_dir.exists():
 env=subprocess.run(['zig','env'],check=True,capture_output=True,text=True).stdout
 cache=pathlib.Path(re.search(r'\.global_cache_dir = "([^"]+)"',env)[1])
 pkg=re.search(r'\.sqlite = .*?\.hash = "([^"]+)"',(ROOT/'build.zig.zon').read_text(),re.S)[1]
 archive=cache/'p'/(pkg+'.tar.gz')
 if not archive.exists():subprocess.run(['zig','build','--fetch=all'],check=True,cwd=ROOT)
 sqlite_dir.mkdir()
 with tarfile.open(archive) as package:package.extractall(sqlite_dir,filter='data')
sqlite=next(sqlite_dir.rglob('sqlite3.c'))
build=(ROOT/'build.zig').read_text().split('fn configureSqlite(',1)[1].split('\nfn ',1)[0]
macros=['-D'+k+'='+v for k,v in re.findall(r'addCMacro\("([^"]+)", "([^"]+)"\)',build)]
provenance={'source_commit':subprocess.run(['git','rev-parse','HEAD'],cwd=ROOT,check=True,capture_output=True,text=True).stdout.strip(),'compiler':subprocess.run(['cc','--version'],check=True,capture_output=True,text=True).stdout,'sqlite_macros':macros,'sqlite_sha256':hashlib.sha256(sqlite.read_bytes()).hexdigest(),'probe_sha256':hashlib.sha256((HERE/'probe.c').read_bytes()).hexdigest(),'note':'Apple system library versus repository-pinned SQLite; stage metrics from one fresh process per case'}
(HERE/'provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
for kind in ['system','pinned']:
 cmd=['cc','-O2',str(HERE/'probe.c'),'-o',str(OUT/kind)]
 cmd+=['-lsqlite3'] if kind=='system' else ['-I'+str(sqlite.parent),str(sqlite),*macros]
 subprocess.run(cmd,check=True)
records=[]
with tempfile.TemporaryDirectory(prefix='rui-sqlite-probe-') as td:
 for kind in ['system','pinned']:
  for size in [1,4,16]:
   for returning in [0,1]:
    for hard,spill in ([(0,-1),(4,-1),(0,1),(0,0)] if size==16 else [(0,-1)]):
     case=f'{kind}-{size}-{returning}-{hard}-{spill}'
     t=time.monotonic()
     p=subprocess.run([OUT/kind,pathlib.Path(td)/(case+'.db'),str(size),str(returning),str(hard),str(spill)],capture_output=True,text=True,timeout=60)
     records.append({'case':case,'library':kind,'mib':size,'returning':bool(returning),'hard_heap_mib':hard,'spill_mode':spill,'exit':p.returncode,'seconds':time.monotonic()-t,'samples':[json.loads(l) for l in p.stdout.splitlines()],'stderr':p.stderr})
(HERE/'results.json').write_text(json.dumps(records,indent=2)+'\n')
for r in records:
 s=r['samples'][-1];print(r['case'],r['exit'],s.get('sqlite_high'),s.get('largest_sqlite_alloc'),s.get('peak_rss'))
