#!/usr/bin/env python3
"""Follow the initial attribution with a dirty-unit predictor and filesystem control."""
import datetime, fcntl, hashlib, json, os, pathlib, platform, signal, subprocess, tempfile, time
HERE=pathlib.Path(__file__).resolve().parent
ROOT=HERE.parents[1]
OUT=HERE/'generated'/'write-attribution'
base=json.loads((HERE/'write-attribution-provenance.json').read_text())
assert (OUT/'src/host_store_density.zig').exists(), 'Run write_attribution.py first'
assert hashlib.sha256((OUT/'src/host_store_density.zig').read_bytes()).hexdigest()==base['modified_fixture_sha256']

def run(args,env=None):
 p=subprocess.Popen([str(a) for a in args],cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
 try: out,err=p.communicate(timeout=600)
 except BaseException:
  os.killpg(p.pid,signal.SIGTERM)
  try:p.communicate(timeout=5)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.communicate()
  raise
 assert p.returncode==0,(p.returncode,out,err)
 return out,err

def swap(text,a,b):
 assert text.count(a)==1,(a,text.count(a))
 return text.replace(a,b)

s=(HERE/'write_probe.c').read_text().replace('#include <sqlite3.h>', '#include <sqlite3.h>\n#include <sys/statvfs.h>')
s=swap(s,'static int heavy;', '''static int heavy;
static unsigned char dirty_units[4][8192];
static uint64_t dirty_count[4], unit_bytes[4], clipped_bytes[4];
static unsigned unit_size, block_size;
static void mark_units(int kind, sqlite3_int64 offset, int bytes){
 for(uint64_t u=offset/unit_size;u<=(offset+bytes-1)/unit_size;u++){
  assert(u<65536);unsigned char mask=1u<<(u%8);
  if(!(dirty_units[kind][u/8]&mask)){dirty_units[kind][u/8]|=mask;dirty_count[kind]++;}
 }
}''')
s=swap(s,'s->writes++;if(r==SQLITE_OK)', 'if(r==SQLITE_OK)mark_units(((File*)f)->kind,o,n);\n s->writes++;if(r==SQLITE_OK)')
s=swap(s,'s->syncs++;s->full_syncs', 'if(r==SQLITE_OK){int k=((File*)f)->kind;uint64_t amount=dirty_count[k]*unit_size;unit_bytes[k]+=amount;sqlite3_int64 size;assert(real(f)->pMethods->xFileSize(real(f),&size)==SQLITE_OK);uint64_t tail=size%unit_size,last=size/unit_size;if(tail&&last<65536&&(dirty_units[k][last/8]&(1u<<(last%8))))amount-=unit_size-((tail+block_size-1)/block_size)*block_size;clipped_bytes[k]+=amount;dirty_count[k]=0;memset(dirty_units[k],0,sizeof dirty_units[k]);}s->syncs++;s->full_syncs')
s=swap(s,'metrics[w->kind].opens++;','metrics[w->kind].opens++;dirty_count[w->kind]=0;memset(dirty_units[w->kind],0,sizeof dirty_units[w->kind]);')
s=swap(s,'int write_probe_install(void){parent=', 'int write_probe_install(void){unit_size=sysconf(_SC_PAGESIZE);struct statvfs fs;assert(statvfs(".",&fs)==0);block_size=fs.f_frsize;assert(unit_size>0&&block_size>0&&unit_size%block_size==0);parent=')
s=swap(s,'memset(metrics,0,sizeof metrics);','memset(dirty_units,0,sizeof dirty_units);memset(dirty_count,0,sizeof dirty_count);memset(unit_bytes,0,sizeof unit_bytes);memset(clipped_bytes,0,sizeof clipped_bytes);memset(metrics,0,sizeof metrics);')
s=swap(s,' printf("}}\\n");fflush(stdout);',' printf("}}\\n");printf("{\\"granularity_population\\":%llu,\\"unit_bytes\\":%u,\\"database_predicted\\":%llu,\\"journal_predicted\\":%llu,\\"block_bytes\\":%u,\\"database_clipped\\":%llu,\\"journal_clipped\\":%llu}\\n",population,unit_size,unit_bytes[0],unit_bytes[1],block_size,clipped_bytes[0],clipped_bytes[1]);fflush(stdout);')
(OUT/'unit-probe.c').write_text(s)
cmd=[str(OUT/'unit-probe.c') if a==str(HERE/'write_probe.c') else '-femit-bin='+str(OUT/'unit-probe') if a.startswith('-femit-bin=') else a for a in base['compile_command']]
print('Building dirty-unit diagnostic',flush=True)
_,compile_err=run(cmd)
run(['cc','-O2','-Wall','-Wextra',HERE/'granularity.c','-o',OUT/'calibration'])
meta={'recorded_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'source_revision':run(['git','rev-parse','HEAD'])[0].strip(),'machine':platform.platform(),'base_provenance':'write-attribution-provenance.json','modified_wrapper_sha256':hashlib.sha256(s.encode()).hexdigest(),'compile_stderr':compile_err,'source_sha256':{n:hashlib.sha256((HERE/n).read_bytes()).hexdigest() for n in ['write_probe.c','write_granularity.py','granularity.c']},'instrumentation':'Additional 32 KiB static bitmaps record unique system-page-sized units dirtied by successful xWrite calls since last successful xSync, separately per file class. A second predictor clips the last dirty unit at file length rounded to the measured filesystem fragment size. No write coalescing or semantic change. This fixture has at most one open file per class.'}
records=[]
with open('/tmp/onepage-memory-experiments.lock','a') as lock:
 print('Waiting for shared experiment lock',flush=True);fcntl.flock(lock,fcntl.LOCK_EX)
 for cache in [64,128]:
  env=os.environ.copy();env['ONEPAGE_PROBE_CACHE_KIB']=str(cache);env['ONEPAGE_PROBE_OS_ATTRIBUTION']='1'
  t=time.monotonic();out,err=run([OUT/'unit-probe'],env)
  records.append({'cache_kib':cache,'seconds':time.monotonic()-t,'records':[json.loads(x) for x in out.splitlines() if x.startswith('{')],'stderr':err})
  print('Dirty-unit case',cache,'complete',flush=True)
 with tempfile.TemporaryDirectory(prefix='onepage-write-calibration-',dir=ROOT/'.zig-cache') as td:
  out,err=run([OUT/'calibration',pathlib.Path(td)/'calibration.bin'])
  calibration=[json.loads(x) for x in out.splitlines()]
(HERE/'write-granularity-results.json').write_text(json.dumps({'production':records,'calibration':calibration},indent=2)+'\n')
(HERE/'write-granularity-provenance.json').write_text(json.dumps(meta,indent=2)+'\n')
for run_record in records:
 for population in [100,1000,10000]:
  t=next(x for x in run_record['records'] if x.get('write_probe_population')==population)
  assert t['begins']==t['commits']==population and t['rollbacks']==0
  assert all(x['failures']==0 for x in t['files'].values())
print('Useful-work and successful-I/O assertions passed; predictor residuals remain measurements.')
