#!/usr/bin/env python3
"""Serial real-QuickJS experiment; synthetic workflows, no providers or Store."""
import pathlib,subprocess,tempfile,struct,json,hashlib,statistics,random,sys
BURST="--burst-only" in sys.argv
HERE=pathlib.Path(__file__).resolve().parent;ROOT=HERE.parents[1];EXE=ROOT/'zig-out/bin/onepage-workflow-evaluator'
def string(x):
 b=x.encode();return struct.pack('<I',len(b))+b
def data(x):
 if x is None:return b'\0'
 if isinstance(x,str):return b'\4'+string(x)
 if isinstance(x,int):return b'\3'+struct.pack('<d',x)
 raise TypeError(x)
def frame(source,visible=None):
 visible=visible or {};r=b'OPWE\1\0'+string(source)+data(None)+struct.pack('<H',len(visible))
 for k,v in visible.items():r+=string(k)+b'\0'+data(v)
 return r
class Reader:
 def __init__(self,b):self.b=b;self.i=0
 def take(self,n):r=self.b[self.i:self.i+n];assert len(r)==n;self.i+=n;return r
 def num(self,n):return int.from_bytes(self.take(n),'little')
 def text(self):return self.take(self.num(4)).decode()
 def value(self):
  t=self.num(1)
  if t==0:return None
  if t in (1,2):return t==2
  if t==3:return struct.unpack('<d',self.take(8))[0]
  if t==4:return self.text()
  if t==5:return [self.value() for _ in range(self.num(4))]
  if t==6:return {self.text():self.value() for _ in range(self.num(4))}
  raise ValueError(t)
def decode(b):
 r=Reader(b);assert r.take(6)==b'OPWO\1\0';tag=r.num(1)
 if tag==0:v=r.value()
 elif tag==1:v=[Reader(r.take(r.num(4))).value() for _ in range(r.num(2))]
 else:v=r.text()
 assert r.i==len(b);return tag,v
fan='export default async function ({agent}) { return await Promise.all(Array.from({length:64},(_,i)=>agent({key:String(i),task:"work"}))); }'
agg='export default async function ({agent}) { const v=await Promise.all(Array.from({length:64},(_,i)=>agent({key:String(i),task:"work"}))); return v.reduce((n,x)=>n+x.length,0); }'
cases={
 'tiny':(frame('export default async function () { return 42; }'),0,42),
 'fanout64':(frame(fan),1,[str(i) for i in range(64)]),
 'partial-replay':(frame(fan,{str(i):'done' for i in range(32)}),1,[str(i) for i in range(32,64)]),
 'aggregate-256k':(frame(agg,{str(i):'x'*4096 for i in range(64)}),0,262144),
 'near-result-60k':(frame('export default async function () { return "x".repeat(60000); }'),0,'x'*60000),
 'report-700k-rejected':(frame('export default async function () { return "x".repeat(700000); }'),4,'WorkflowOutputBytes'),
 'objects20k':(frame('export default async function () { const a=[]; for(let i=0;i<20000;i++) a.push({i,text:"entry-"+i}); return a.length; }'),0,20000),
 'heap-exhaustion':(frame("export default async function () { const a=[]; while(true) a.push('x'.repeat(100000)); }"),2,'WorkflowRejected'),
 'runaway':(frame('export default async function () { while(true) {} }'),4,'CpuTime'),
}
rows=[];batches=[]
with tempfile.TemporaryDirectory(prefix='onepage-evaluator-serial-') as d:
 temp=pathlib.Path(d);sup=temp/'supervisor'
 subprocess.run(['clang','-O2','-Wall','-Wextra','-Werror',str(HERE/'supervisor.c'),'-o',str(sup)],check=True)
 def batch(label,names):
  paths=[]
  for i,name in enumerate(names):
   p=temp/f'{len(batches)}-{i}.frame';p.write_bytes(cases[name][0]);paths.append(p)
  p=subprocess.Popen([str(sup),str(EXE),*map(str,paths)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
  try:out,err=p.communicate(timeout=max(15,len(names)*3))
  except subprocess.TimeoutExpired:p.terminate();p.communicate(timeout=10);raise
  assert p.returncode==0,(out,err)
  measurements=[json.loads(x) for x in out.splitlines()];assert len(measurements)==len(names)
  for name,path,m in zip(names,paths,measurements):
   assert m['exit_code']==0 and not m['timeout'] and m['signal']==0,(name,m)
   assert m['child_samples']>0,(name,'no physical samples')
   tag,v=decode(path.with_suffix('.frame.out').read_bytes());expected_tag,expected=cases[name][1:]
   assert tag==expected_tag,(name,tag,str(v)[:100])
   if tag==1:assert [x['key'] for x in v]==expected,(name,v)
   else:assert v==expected,(name,tag,str(v)[:100])
   m.update(case=name,batch=label,input_bytes=len(cases[name][0]),outcome_tag=tag,input_sha256=hashlib.sha256(cases[name][0]).hexdigest());rows.append(m)
  batches.append({'label':label,'jobs':len(names),'last_queue_wait_ms':measurements[-1]['queue_wait_ms'],'completion_ms':measurements[-1]['queue_wait_ms']+measurements[-1]['service_ms']})
  print(label,'passed',len(names),'jobs',flush=True)
 if BURST:
  batch('tiny-burst-1000',['tiny']*1000)
 else:
  # Five rotated repetitions, each containing all workload classes.
  for rep in range(5):
   names=list(cases);random.Random(700+rep).shuffle(names);batch('mixed-'+str(rep),names)
  batch('tiny-burst-50',['tiny']*50)
  batch('runaway-then-tiny',['runaway']+['tiny']*10)
  batch('aggregate-burst-20',['aggregate-256k']*20)
summary=[]
for name in cases:
 a=[r for r in rows if r['case']==name and r['batch'].startswith('mixed-')]
 if not a:continue
 summary.append({'case':name,'repetitions':len(a),'median_service_ms':statistics.median(r['service_ms'] for r in a),'max_service_ms':max(r['service_ms'] for r in a),'median_child_peak_mib':statistics.median(r['sampled_child_peak']/1048576 for r in a),'median_combined_peak_mib':statistics.median(r['sampled_combined_peak']/1048576 for r in a),'median_added_combined_mib':statistics.median((r['sampled_combined_peak']-r['baseline_parent'])/1048576 for r in a),'max_loop_gap_ms':max(r['loop_max_gap_ms'] for r in a),'outcome_tag':a[0]['outcome_tag']})
(HERE/('burst-results.json' if BURST else 'results.json')).write_text(json.dumps({'platform':subprocess.check_output(['sw_vers'],text=True),'binary_sha256':hashlib.sha256(EXE.read_bytes()).hexdigest(),'rows':rows,'batches':batches},indent=2)+'\n')
(HERE/('burst-summary.json' if BURST else 'summary.json')).write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2));print(json.dumps(batches,indent=2))
