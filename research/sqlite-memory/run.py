#!/usr/bin/env python3
"""Bounded native storage experiment. All heavy work holds the sibling lock."""
import fcntl, hashlib, json, pathlib, platform, re, subprocess, tarfile, tempfile, time
HERE=pathlib.Path(__file__).resolve().parent
ROOT=HERE.parents[1]
OUT=HERE/'generated'; OUT.mkdir(exist_ok=True)
def command(args, **kw):
    return subprocess.run(args,check=True,capture_output=True,text=True,**kw).stdout

env=command(['zig','env'])
cache=pathlib.Path(re.search(r'\.global_cache_dir = "([^"]+)"',env)[1])
pkg=re.search(r'\.sqlite = .*?\.hash = "([^"]+)"',(ROOT/'build.zig.zon').read_text(),re.S)[1]
archive=cache/'p'/(pkg+'.tar.gz')
if not archive.exists(): command(['zig','build','--fetch=all'],cwd=ROOT)
sqlite_dir=OUT/'sqlite'
if not sqlite_dir.exists():
    sqlite_dir.mkdir()
    with tarfile.open(archive) as t: t.extractall(sqlite_dir,filter='data')
sqlite=next(sqlite_dir.rglob('sqlite3.c'))
build=(ROOT/'build.zig').read_text().split('fn configureSqlite(',1)[1].split('\nfn ',1)[0]
macros=['-D'+k+'='+v for k,v in re.findall(r'addCMacro\("([^"]+)", "([^"]+)"\)',build)]
source=(ROOT/'src/host_store.zig').read_text()
block=source.split('const content_schema =',1)[1].split('\n;',1)[0]
schema='\n'.join(line.strip()[2:] for line in block.splitlines() if line.strip().startswith('\\\\'))
# Only relax the earlier value-size guard for the large-value prototype.
large_schema=schema.replace('byte_length BETWEEN 1 AND 1048576','byte_length >= 1')
(OUT/'schema.h').write_text('#define CONTENT_SCHEMA '+json.dumps(large_schema)+'\n')
metadata={'revision':command(['git','rev-parse','HEAD'],cwd=ROOT).strip(),'machine':platform.platform(),'hardware':command(['sysctl','-n','hw.model','hw.memsize','hw.ncpu']).splitlines(),'compiler':command(['cc','--version']),'zig':env,'sqlite_sha256':hashlib.sha256(sqlite.read_bytes()).hexdigest(),'sqlite_package_hash':pkg,'macros':macros,'schema':large_schema,'source_sha256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in ['src/host_store.zig','build.zig','ARCHITECTURE.md','VERIFICATION.md','research/sqlite-memory/probe.c','research/sqlite-memory/run.py']},'measurement_note':'fresh process per case; Mac physical footprint stage samples, SQLite high-water continuous; malloc zone includes SQLite and libc, do not sum; source and database scratch removed per case'}
(HERE/'provenance.json').write_text(json.dumps(metadata,indent=2)+'\n')
for threadsafe in [0,1]:
    flags=[x for x in macros if not x.startswith('-DSQLITE_THREADSAFE=')]+[f'-DSQLITE_THREADSAFE={threadsafe}']
    command(['cc','-O2','-Wall','-Wextra','-Wno-deprecated-declarations','-include',str(OUT/'schema.h'),'-I'+str(sqlite.parent),str(HERE/'probe.c'),str(sqlite),*flags,'-o',str(OUT/f'probe-{threadsafe}')])
cases=[]
for n in [4096,1048576,16777216,67108864]:
    for returning in [0,1]: cases.append((1,n,1,returning,1,'normal'))
for rows in [1,100,1000]: cases.append((1,4096,rows,0,1,'normal'))
for mode in ['heap','full','short','digest','select','crash']:
    cases.append((1,16777216,3 if mode in ['short','digest'] else 1,0,1,mode))
cases.extend([(1,16777216,1,0,2,'normal'),(1,16777216,1,0,0,'normal'),(0,1048576,1,1,1,'normal'),(0,16777216,1,0,1,'normal'),(1,1048576,1,0,1,'select')])
results=[]
with open('/tmp/rui-memory-experiments.lock','a') as lock:
    print('Waiting for shared benchmark lock',flush=True)
    fcntl.flock(lock,fcntl.LOCK_EX)
    print('Acquired shared benchmark lock',flush=True)
    metadata['vm_stat_before']=command(['vm_stat'])
    with tempfile.TemporaryDirectory(prefix='rui-sqlite-memory-') as td:
        metadata['filesystem']=command(['df','-k',td])
        for idx,(ts,n,rows,ret,spill,mode) in enumerate(cases):
            with tempfile.TemporaryDirectory(dir=td) as case_dir:
                args=[str(OUT/f'probe-{ts}'),str(pathlib.Path(case_dir)/'content.db'),str(n),str(rows),str(ret),str(spill),mode]
                start=time.monotonic();p=subprocess.run(args,capture_output=True,text=True,timeout=120)
                record={'threadsafe':ts,'bytes_per_value':n,'rows':rows,'returning':ret,'spill':spill,'mode':mode,'exit':p.returncode,'seconds':time.monotonic()-start,'samples':[json.loads(line) for line in p.stdout.splitlines()],'stderr':p.stderr}
                results.append(record)
                (HERE/'results.json').write_text(json.dumps(results,indent=2)+'\n')
                print(idx,ts,n,rows,ret,spill,mode,'exit',p.returncode,flush=True)
                if mode=='crash':
                    assert p.returncode==77
                    record['recovery']=json.loads(command(args[:-1]+['recover']))
                    (HERE/'results.json').write_text(json.dumps(results,indent=2)+'\n')
                elif p.returncode: raise RuntimeError(record)
    metadata['vm_stat_after']=command(['vm_stat'])
(HERE/'provenance.json').write_text(json.dumps(metadata,indent=2)+'\n')
# Assert outcomes independently of native checks, so expected failures are not mistaken for success.
for r in results:
    failures=[s['failure_rc'] for s in r['samples'] if 'failure_rc' in s]
    expected=7 if not r['spill'] else {'full':13,'short':1001,'digest':1002}.get(r['mode'])
    assert failures==([] if expected is None else [expected]),(r,expected)
    for s in r['samples']:
        assert s.get('sqlite_peak',0)<=4*1024*1024,(r,s)
    if r['mode']!='crash': assert r['samples'][-1]['sqlite_live']==0
    if r['mode']=='select' and r['bytes_per_value']>=16777216:
        assert any(s.get('whole_select_rc')==7 for s in r['samples'])
print('All outcome, bound, and cleanup assertions passed')
