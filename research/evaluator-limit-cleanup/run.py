#!/usr/bin/env python3
import pathlib,subprocess,json,hashlib
HERE=pathlib.Path(__file__).resolve().parent;ROOT=HERE.parents[1]
f=ROOT/'research/evaluator-serial-probe/run.py';ns={'__file__':str(f),'__name__':'fixtures'};exec(f.read_text().split('rows=[]')[0],ns)
frame,decode=ns['frame'],ns['decode']
p=ROOT/'src/workflow_evaluator.zig';base=subprocess.check_output(['git','show','13b6e59:src/workflow_evaluator.zig'],cwd=ROOT,text=True)
old='''        if (state.microtasks == protocol.Limits.microtasks) {
            state.resource_code = "Microtasks";
            return false;
        }
        state.microtasks += 1;'''
assert old in base
candidate=base.replace(old,'        if (interruptHandler(runtime, state) != 0) return false;')
fixtures={k:v for k,v in ns['cases'].items() if k in ['tiny','fanout64','partial-replay','aggregate-256k','runaway','heap-exhaustion']}
fixtures['await-10000']=(frame('export default async function () { for(let i=0;i<10000;i++) await 0; return 10000; }'),0,10000)
fixtures['await-endless']=(frame('export default async function () { while(true) await 0; }'),4,'CpuTime')
rows=[]
for mode,source in [('baseline',base),('cpu-check',candidate)]:
 p.write_text(source);subprocess.run(['zig','build','evaluator-probe','-Doptimize=ReleaseSafe'],cwd=ROOT,check=True)
 exe=ROOT/'zig-out/bin/onepage-workflow-evaluator'
 for name,(request,tag,expected) in fixtures.items():
  result=subprocess.run([str(exe)],input=request,capture_output=True,env={},close_fds=True,timeout=7)
  assert result.returncode==0,(name,result.returncode)
  actual_tag,value=decode(result.stdout)
  if mode=='baseline' and name.startswith('await-'):tag,expected=4,'Microtasks'
  actual=[x['key'] for x in value] if actual_tag==1 else value
  assert (actual_tag,actual)==(tag,expected),(mode,name,actual_tag,actual,tag,expected)
  row={'mode':mode,'case':name,'outcome_tag':actual_tag,'value':actual,'binary_sha256':hashlib.sha256(exe.read_bytes()).hexdigest()};rows.append(row);print(json.dumps(row),flush=True)
(HERE/'microtasks-results.json').write_text(json.dumps(rows,indent=2)+'\n')
