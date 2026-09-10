#!/usr/bin/env python3
"""Attribute production density-fixture writes without altering its commits or durability."""
import datetime, fcntl, hashlib, json, os, pathlib, platform, re, shutil, signal, subprocess, time
HERE=pathlib.Path(__file__).resolve().parent
ROOT=HERE.parents[1]
OUT=HERE/'generated'/'write-attribution'
OUT.mkdir(parents=True,exist_ok=True)
def run(args, *, timeout=600, env=None):
    p=subprocess.Popen([str(x) for x in args],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True,env=env)
    try: out,err=p.communicate(timeout=timeout)
    except BaseException:
        os.killpg(p.pid,signal.SIGTERM)
        try: p.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid,signal.SIGKILL);p.communicate()
        raise
    if p.returncode: raise RuntimeError((args,p.returncode,out,err))
    return out,err

def replace_once(text,old,new):
    assert text.count(old)==1,(old,text.count(old))
    return text.replace(old,new)

# Build from copies so measurement additions never modify production source.
shutil.copytree(ROOT/'src',OUT/'src',dirs_exist_ok=True)
fixture=(ROOT/'src/host_store_density.zig').read_text()
modified=fixture
modified='extern fn write_probe_install() c_int;\nextern fn write_probe_cache() u16;\nextern fn write_probe_reset() void;\nextern fn write_probe_report(population: u64) void;\n'+modified
modified=replace_once(modified,'    defer host_store.disableProcessHeapLimit();','    defer host_store.disableProcessHeapLimit();\n    if (write_probe_install() != 0) return error.WriteProbeInstallationFailed;')
modified=replace_once(modified,'.{ .fault = journal.hook() }','.{ .fault = journal.hook(), .page_cache_kib = write_probe_cache() }')
modified=replace_once(modified,'    const usage_before = try processUsage();','    write_probe_reset();\n    const usage_before = try processUsage();')
modified=replace_once(modified,'    try std.Io.File.stdout().writeStreamingAll(io, encoded);\n}\n\nconst TransientSample', '    try std.Io.File.stdout().writeStreamingAll(io, encoded);\n    write_probe_report(population);\n}\n\nconst TransientSample')
(OUT/'src/host_store_density.zig').write_text(modified)
# The existing production build populates this pinned dependency directory.
pkg=re.search(r'\.sqlite = .*?\.hash = "([^"]+)"',(ROOT/'build.zig.zon').read_text(),re.S)[1]
sqlite=ROOT/'zig-pkg'/pkg/'sqlite3.c'
if not sqlite.exists(): run(['zig','build','--fetch=all'])
assert sqlite.exists(), 'Run zig build host-store-density once to materialize the pinned package'
block=(ROOT/'build.zig').read_text().split('fn configureSqlite(',1)[1].split('\nfn ',1)[0]
macros=['-D'+k+'='+v for k,v in re.findall(r'addCMacro\("([^"]+)", "([^"]+)"\)',block)]
cmd=['zig','build-exe',str(OUT/'src/host_store_density.zig'),'-OReleaseSafe','-lc','-I'+str(sqlite.parent),*macros,'-cflags','-std=c99','-fno-strict-aliasing','--',str(sqlite),'-cflags','-std=c11','-Wall','-Wextra','--',str(HERE/'write_probe.c'),'-femit-bin='+str(OUT/'probe')]
print('Building measurement-only fixture',flush=True)
out,err=run(cmd)
metadata={'recorded_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'source_revision':run(['git','rev-parse','HEAD'])[0].strip(),'machine':platform.platform(),'hardware':run(['sysctl','-n','hw.model','hw.memsize','hw.ncpu'])[0],'zig_version':run(['zig','version'])[0].strip(),'macros':macros,'sqlite_sha256':hashlib.sha256(sqlite.read_bytes()).hexdigest(),'source_sha256':{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in ['src/host_store_density.zig','src/host_store.zig','src/session.zig','build.zig','build.zig.zon','research/sqlite-memory/write_probe.c','research/sqlite-memory/write_attribution.py']},'modified_fixture_sha256':hashlib.sha256(modified.encode()).hexdigest(),'compile_command':cmd,'compile_stderr':err,'fixture_changes':'Add passthrough VFS/SQL trace installation, reset/report calls, and select an existing supported cache profile. Session.create, SQL, schema, identity randomness, transaction count and durability unchanged. All three original population loops and post-population transient fixtures execute.','instrumentation_bytes':'32 KiB static page-write bitmap plus 4 fixed aggregate metric records and wrapper file headers; per-operation OS sampling enabled only for heavy attribution cases.'}
records=[]
with open('/tmp/onepage-memory-experiments.lock','a') as lock:
    print('Waiting for shared experiment lock',flush=True);fcntl.flock(lock,fcntl.LOCK_EX)
    print('Running serial production write attribution',flush=True)
    metadata['filesystem']=run(['df','-k',str(ROOT)])[0]
    metadata['vm_stat_before']=run(['vm_stat'])[0]
    cases=[('baseline',64,False),('attributed',64,True),('light',64,False),('light',128,False),('light',64,False),('light',128,False),('attributed',128,True)]
    for kind,cache,heavy in cases:
        env=os.environ.copy();env['ONEPAGE_PROBE_CACHE_KIB']=str(cache);env['ONEPAGE_PROBE_OS_ATTRIBUTION']=str(int(heavy))
        command=['zig','build','host-store-density'] if kind=='baseline' else [OUT/'probe']
        start=time.monotonic();stdout,stderr=run(command,env=env)
        sample={'kind':kind,'cache_kib':cache,'os_attribution':heavy,'wall_seconds_including_startup':time.monotonic()-start,'records':[json.loads(x) for x in stdout.splitlines() if x.startswith('{')],'stderr':stderr}
        records.append(sample)
        (HERE/'write-attribution-results.json').write_text(json.dumps(records,indent=2)+'\n')
        print(kind,cache,heavy,'complete',flush=True)
    metadata['vm_stat_after']=run(['vm_stat'])[0]
(HERE/'write-attribution-provenance.json').write_text(json.dumps(metadata,indent=2)+'\n')
for run_record in records:
    r=run_record['records']
    if run_record['kind']=='baseline': continue
    for p in [100,1000,10000]:
        fixture_row=next(x for x in r if x.get('sessions')==p)
        trace=next(x for x in r if x.get('write_probe_population')==p)
        assert trace['begins']==trace['commits']==p and trace['rollbacks']==0
        assert trace['inserts']==4*p
        files=trace['files'];assert files['wal']['writes']==files['wal']['opens']==0
        assert files['database']['write_bytes']==fixture_row['sqlite_page_writes']*4096
        assert trace['unique_main_pages_per_transaction_sum']+trace['repeated_main_page_writes_in_transaction']==files['database']['writes']
        assert files['journal']['opens']==files['journal']['closes']==files['journal']['deletes']==p
        assert all(f['failures']==0 for f in files.values())
        if run_record['os_attribution']:
            attributed=sum(f[k] for f in files.values() for k in ['os_write','os_sync','os_truncate','os_delete'])
            assert attributed<=fixture_row['process_disk_write_bytes']
print('All useful-work, transaction, journal, page-write and attribution assertions passed')
