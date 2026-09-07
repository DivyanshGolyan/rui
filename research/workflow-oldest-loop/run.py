#!/usr/bin/env python3
"""Throwaway oldest-eligible query and loop; no production Host/provider work."""
import asyncio,ctypes as C,heapq,json,pathlib,platform,statistics,subprocess,tempfile,time,tarfile
HERE=pathlib.Path(__file__).resolve().parent
SQL=(HERE/'oldest.sql').read_text()
BUILD=pathlib.Path(tempfile.gettempdir())/'onepage-oldest-loop-native-build';BUILD.mkdir(exist_ok=True)
S='N-V-__8AAGVtrgCcOcmjrOJnagmnRyMrcKaOo09KbU-vu8w8'
source=BUILD/S/'sqlite3.c'
if not source.exists():
 with tarfile.open(pathlib.Path.home()/'.cache/zig/p'/(S+'.tar.gz')) as tar:tar.extractall(BUILD,filter='data')
libpath=BUILD/'sqlite.dylib'
if not libpath.exists():subprocess.run(['clang','-O2','-dynamiclib','-fPIC','-DSQLITE_THREADSAFE=0','-DSQLITE_DEFAULT_PAGE_SIZE=4096','-DSQLITE_DEFAULT_FOREIGN_KEYS=1','-DSQLITE_MAX_MMAP_SIZE=0','-DSQLITE_DEFAULT_SYNCHRONOUS=3','-DSQLITE_DQS=0','-DSQLITE_OMIT_LOAD_EXTENSION=1','-DSQLITE_OMIT_SHARED_CACHE=1','-DSQLITE_TEMP_STORE=1','-DSQLITE_USE_URI=0','-DSQLITE_ENABLE_API_ARMOR=1',str(source),'-o',str(libpath)],check=True,timeout=120)
lib=C.CDLL(str(libpath))
def api(name,restype,*args):
 f=getattr(lib,name);f.restype=restype;f.argtypes=args;return f
ptr=C.c_void_p;integer=C.c_int;i64=C.c_int64
open_db=api('sqlite3_open',integer,C.c_char_p,C.POINTER(ptr));close_db=api('sqlite3_close',integer,ptr)
execute=api('sqlite3_exec',integer,ptr,C.c_char_p,ptr,ptr,ptr);errmsg=api('sqlite3_errmsg',C.c_char_p,ptr)
prepare=api('sqlite3_prepare_v2',integer,ptr,C.c_char_p,integer,C.POINTER(ptr),ptr);step=api('sqlite3_step',integer,ptr);reset=api('sqlite3_reset',integer,ptr);finalize=api('sqlite3_finalize',integer,ptr)
column=api('sqlite3_column_int64',i64,ptr,integer);column_text=api('sqlite3_column_text',C.c_char_p,ptr,integer)
status=api('sqlite3_stmt_status',integer,ptr,integer,integer);memory=api('sqlite3_memory_used',i64);highwater=api('sqlite3_memory_highwater',i64,integer);version=api('sqlite3_libversion',C.c_char_p)
SCHEMA='''
PRAGMA journal_mode=DELETE; PRAGMA synchronous=EXTRA; PRAGMA mmap_size=0;
PRAGMA cache_size=-256; PRAGMA temp_store=FILE; PRAGMA busy_timeout=0;
CREATE TABLE run(id INTEGER PRIMARY KEY,created_at INTEGER NOT NULL,
  published_generation INTEGER,active_generation INTEGER,terminal INTEGER NOT NULL DEFAULT 0,cancelled INTEGER NOT NULL DEFAULT 0);
CREATE INDEX oldest_live ON run(created_at,id) WHERE terminal=0 AND cancelled=0;
CREATE TABLE result_owner(id INTEGER PRIMARY KEY,available INTEGER NOT NULL);
CREATE TABLE call_binding(run_id INTEGER NOT NULL REFERENCES run(id),key INTEGER NOT NULL,result_id INTEGER NOT NULL REFERENCES result_owner(id),PRIMARY KEY(run_id,key));
CREATE TABLE pending(run_id INTEGER NOT NULL,key INTEGER NOT NULL,PRIMARY KEY(run_id,key),FOREIGN KEY(run_id,key) REFERENCES call_binding(run_id,key));
'''
class DB:
 def __init__(self,path):
  self.handle=ptr();assert open_db(str(path).encode(),C.byref(self.handle))==0;self.exec(SCHEMA);self.select=self.statement(SQL)
 def exec(self,sql):
  rc=execute(self.handle,sql.encode(),None,None,None);assert rc==0,(rc,errmsg(self.handle).decode(),sql[:200])
 def statement(self,sql):
  p=ptr();rc=prepare(self.handle,sql.encode(),-1,C.byref(p),None);assert rc==0,(rc,errmsg(self.handle));return p
 def rows(self,sql,text=False):
  p=self.statement(sql);out=[]
  while (rc:=step(p))==100:out.append(column_text(p,3).decode() if text else column(p,0))
  assert rc==101;finalize(p);return out
 def eligible(self):
  rc=step(self.select);assert rc in (100,101),(rc,errmsg(self.handle));value=column(self.select,0) if rc==100 else None;assert reset(self.select)==0;return value
 def close(self):finalize(self.select);assert close_db(self.handle)==0
 def seed(self,n,deps=1,history=0):
  self.exec(f'''BEGIN;
WITH RECURSIVE seq(i) AS(SELECT 1 UNION ALL SELECT i+1 FROM seq WHERE i<{n})
INSERT INTO run(id,created_at,published_generation) SELECT i,i/7,1 FROM seq;
INSERT INTO result_owner VALUES(1,0),(2,0);
WITH RECURSIVE seq(j) AS(SELECT 1 UNION ALL SELECT j+1 FROM seq WHERE j<{deps})
INSERT INTO call_binding SELECT r.id,j,2 FROM run r CROSS JOIN seq;
INSERT INTO pending SELECT run_id,key FROM call_binding;
COMMIT;''')
  if history:self.exec(f'''BEGIN;
WITH RECURSIVE seq(i) AS(SELECT 1 UNION ALL SELECT i+1 FROM seq WHERE i<{history})
INSERT INTO run(id,created_at,published_generation,terminal) SELECT {n}+i,0,1,1 FROM seq;
WITH RECURSIVE seq(i) AS(SELECT 1 UNION ALL SELECT i+1 FROM seq WHERE i<{history})
INSERT INTO result_owner SELECT i+2,1 FROM seq;
COMMIT;''')
  self.exec('ANALYZE;')
results={'sqlite':version().decode(),'platform':platform.platform(),'scope':'pinned SQLite query measurements, virtual-time service model and small live async loop; not production qualification','query':SQL,'query_cases':[],'simulations':[],'checks':[]}
with tempfile.TemporaryDirectory(prefix='onepage-oldest-loop-fixtures-') as directory:
 root=pathlib.Path(directory)
 # Prepared query cost, with input mutations outside measurement.
 for n,deps,history in [(10,1,0),(1000,1,0),(10000,1,0),(100000,1,0),(1000,16,0),(10000,16,0),(1000,1,100000)]:
  db=DB(root/f'cost-{n}-{deps}-{history}.db');db.seed(n,deps,history)
  for case,target in [('none',None),('oldest',1),('newest',n)]:
   db.exec('UPDATE call_binding SET result_id=2; UPDATE result_owner SET available=1 WHERE id=1;')
   if target:db.exec(f'UPDATE call_binding SET result_id=1 WHERE run_id={target} AND key={deps};')
   assert db.eligible()==target
   times=[];cpus=[];steps=[];scans=[];sorts=[];heaps=[]
   for _ in range(9):
    for counter in (1,2,4):status(db.select,counter,1)
    baseline=memory();highwater(1);start=time.perf_counter_ns();cpu=time.process_time_ns();found=db.eligible();cpus.append((time.process_time_ns()-cpu)/1e6);times.append((time.perf_counter_ns()-start)/1e6)
    assert found==target;steps.append(status(db.select,4,0));scans.append(status(db.select,1,0));sorts.append(status(db.select,2,0));heaps.append(highwater(0)-baseline)
   record=dict(waiting_runs=n,dependencies_each=deps,historical_terminal_runs=history,case=case,wall_ms=times,cpu_ms=cpus,vm_steps=steps,fullscan_steps=scans,sorts=sorts,incremental_sqlite_heap=heaps,statement_bytes=status(db.select,99,0),plan=db.rows('EXPLAIN QUERY PLAN '+SQL,text=True))
   results['query_cases'].append(record)
   print('query',n,deps,history,case,'median CPU ms',round(statistics.median(cpus),3),flush=True)
  db.close()
 results['checks'].append('oldest/newest/none selection; creation-time ties use id; historical terminal Runs excluded by partial index; shared original-result lookup and multi-dependency eligibility')
 # New and interrupted generations are eligible without a finished dependency.
 db=DB(root/'states.db');db.seed(3)
 db.exec('UPDATE run SET published_generation=NULL WHERE id=2;');assert db.eligible()==2
 db.exec('UPDATE run SET active_generation=4 WHERE id=1;');assert db.eligible()==1
 db.exec('UPDATE run SET cancelled=1 WHERE id=1;');assert db.eligible()==2
 db.exec('UPDATE run SET terminal=1 WHERE id=2;');assert db.eligible() is None;db.close()
 results['checks'].append('new and interrupted work admitted without a new result; cancellation and terminality exclude selection')

 # Event heap belongs to the EXTERNAL completion fixture, never the Host.
 # SQL readiness remains authoritative; synthetic evaluator service is a scalar duration.
 def simulate(name,n,turn_seconds,duration=180,service_ms=20,burst=False):
  db=DB(root/(name+'.db'));db.seed(n);db.exec('BEGIN; DELETE FROM pending; DELETE FROM call_binding; DELETE FROM result_owner; COMMIT;')
  events=[];waiting_since={};processed=[0]*(n+1);next_id=n;selected=[];delays=[];clock=0.0;idle_checks=0;queries=0;consumed=set();last_key=[0]*(n+1)
  db.exec('BEGIN;')
  for i in range(1,n+1):
   last_key[i]=1;db.exec(f'INSERT INTO result_owner VALUES({i},0); INSERT INTO call_binding VALUES({i},1,{i}); INSERT INTO pending VALUES({i},1);')
   at=1.25 if burst else (i-0.5)*turn_seconds/n
   heapq.heappush(events,(at,i,i))
  db.exec('COMMIT;')
  def advance(end):
   nonlocal clock
   while events and events[0][0]<=end:
    when,run,owner=heapq.heappop(events);db.exec(f'UPDATE result_owner SET available=1 WHERE id={owner};');waiting_since[run]=when
   clock=end
  while clock<duration:
   chosen=db.eligible();queries+=1
   if chosen is None:
    idle_checks+=1;advance(min(duration,clock+1));continue
   assert chosen in waiting_since
   delay=clock-waiting_since.pop(chosen);delays.append(delay);processed[chosen]+=1
   if len(selected)<30:selected.append(chosen)
   owner=db.rows(f'SELECT c.result_id FROM pending p JOIN call_binding c USING(run_id,key) WHERE p.run_id={chosen}')[0]
   assert owner not in consumed;consumed.add(owner)
   advance(clock+service_ms/1000)
   # Fixed captured result consumed once. Published pending basis uses a NEW immutable result.
   if burst:db.exec(f'BEGIN; DELETE FROM pending WHERE run_id={chosen}; UPDATE run SET terminal=1 WHERE id={chosen}; COMMIT;')
   else:
    next_id+=1;last_key[chosen]+=1;key=last_key[chosen]
    db.exec(f'BEGIN; DELETE FROM pending WHERE run_id={chosen}; INSERT INTO result_owner VALUES({next_id},0); INSERT INTO call_binding VALUES({chosen},{key},{next_id}); INSERT INTO pending VALUES({chosen},{key}); UPDATE run SET published_generation=published_generation+1 WHERE id={chosen}; COMMIT;')
    heapq.heappush(events,(clock+turn_seconds,chosen,next_id))
  sorted_delays=sorted(delays);active=[x for x in processed[1:]]
  data=dict(name=name,runs=n,turn_seconds=turn_seconds,virtual_duration_seconds=duration,assumed_evaluation_lifecycle_ms=service_ms,turn_to_evaluation_ratio=turn_seconds*1000/service_ms,burst=burst,evaluations=len(delays),idle_checks=idle_checks,queries=queries,first_selected=selected,runs_never_selected=sum(x==0 for x in active),min_evaluations=min(active),max_evaluations=max(active),p95_ready_to_start_seconds=sorted_delays[int(.95*(len(sorted_delays)-1))] if delays else None,max_ready_to_start_seconds=max(delays,default=None),remaining_ready=len(waiting_since))
  db.close();results['simulations'].append(data);print('simulation',data,flush=True)
  return data
 for args in [('ordinary-100-runs-2s',100,2,180,20,False),('ordinary-1000-runs-60s',1000,60,240,20,False),('sensitivity-1000-runs-10s',1000,10,180,20,False),('burst-1000',1000,60,30,20,True)]:
  data=simulate(*args)
  if args[0].startswith('ordinary'):assert data['runs_never_selected']==0
  if data['burst']:assert data['evaluations']==1000 and data['max_ready_to_start_seconds']<22
 results['checks'].append('ordinary virtual-time traces use seconds-to-minutes completions and 20 ms evaluation lifecycle; burst drains without one-second gaps; overload sensitivity is separate')

 async def live():
  db=DB(root/'live.db');db.seed(2);db.exec('UPDATE call_binding SET result_id=1;')
  start=time.monotonic();queries=[];starts=[];heartbeats=[];completion_at=None
  async def external():
   nonlocal completion_at
   await asyncio.sleep(1.25);db.exec('UPDATE result_owner SET available=1 WHERE id=1;');completion_at=time.monotonic()-start
  async def heartbeat():
   while time.monotonic()-start<4.2:
    heartbeats.append(time.monotonic()-start);await asyncio.sleep(.05)
  async def host_loop():
   while time.monotonic()-start<4.2:
    selected=db.eligible();queries.append((time.monotonic()-start,selected))
    if selected is None:await asyncio.sleep(1);continue
    starts.append((time.monotonic()-start,selected));await asyncio.sleep(.02)
    db.exec(f'UPDATE run SET terminal=1 WHERE id={selected};')
    await asyncio.sleep(0) # Fixture service turn; no additional evaluator admission delay.
  cpu=time.process_time();await asyncio.gather(external(),heartbeat(),host_loop());cpu=time.process_time()-cpu
  assert [item[1] for item in starts]==[1,2]
  assert starts[1][0]-starts[0][0]<.25
  assert len(heartbeats)>50
  gap=max(b-a for a,b in zip(heartbeats,heartbeats[1:]));assert gap<.25
  result=dict(elapsed_seconds=time.monotonic()-start,process_cpu_seconds=cpu,completion_at=completion_at,queries=queries,evaluation_starts=starts,heartbeat_count=len(heartbeats),maximum_heartbeat_gap_seconds=gap,scope='real asyncio timer and actual SQLite query; 20 ms evaluator is an async delay, not QuickJS')
  db.close();return result
 results['live_loop']=asyncio.run(live())
 results['checks'].append('real async one-second idle wait leaves 50 ms heartbeat running; two ready workflows start about 20 ms apart without a one-second gap')
 (HERE/'results.json').write_text(json.dumps(results,indent=2)+'\n')
