#!/usr/bin/env python3
"""Throwaway heap-limit sweep; generated report shapes, not saved workflow ports."""
import pathlib, subprocess, tempfile, json, hashlib, re
HERE=pathlib.Path(__file__).resolve().parent; ROOT=HERE.parents[1]
old=ROOT/'research/evaluator-serial-probe/run.py'
ns={'__file__':str(old),'__name__':'fixtures'}
exec(old.read_text().split('rows=[]')[0],ns)
frame,decode=ns['frame'],ns['decode']
fixtures={k:v for k,v in ns['cases'].items() if k in ['tiny','fanout64','partial-replay','aggregate-256k','objects20k','heap-exhaustion']}
for n,size in [(61,12000),(5120,140),(20000,140)]:
    source=f'''export default async function () {{
      const rows=[]; for(let i=0;i<{n};i++) rows.push({{id:i,text:String(i)+":"+"x".repeat({size})}});
      const encoded=rows.map(x=>x.text).join("|"); const copy=encoded.split("|");
      return [rows.length,copy.length,encoded.length,copy[copy.length-1].length];
    }}'''
    rows=[{'id':i,'text':str(i)+':'+'x'*size} for i in range(n)]
    expected=[n,n,len('|'.join(x['text'] for x in rows)),len(rows[-1]['text'])]
    fixtures[f'assemble-copy-{n}x{size}']=(frame(source),0,expected)
p=ROOT/'src/workflow_protocol.zig'; original=subprocess.check_output(['git','show','399fa3f:src/workflow_protocol.zig'],cwd=ROOT,text=True)
results=[]
with tempfile.TemporaryDirectory(prefix='onepage-heap-sizing-') as tmp:
    tmp=pathlib.Path(tmp);sup=tmp/'supervisor'
    subprocess.run(['clang','-O2','-Wall','-Wextra','-Werror',str(ROOT/'research/evaluator-serial-probe/supervisor.c'),'-o',str(sup)],check=True)
    try:
        for mib in [4,8,16,32]:
            source,count=re.subn(r'(engine_heap_bytes[^=]*=\s*)16 \* 1024 \* 1024',rf'\g<1>{mib} * 1024 * 1024',original)
            assert count==1
            p.write_text(source)
            subprocess.run(['zig','build','evaluator-probe','-Doptimize=ReleaseSafe'],cwd=ROOT,check=True)
            exe=ROOT/'zig-out/bin/onepage-workflow-evaluator';binary_hash=hashlib.sha256(exe.read_bytes()).hexdigest()
            for name,(request,expected_tag,expected) in fixtures.items():
                path=tmp/(name+'.frame');path.write_bytes(request)
                run=subprocess.run([str(sup),str(exe),str(path)],capture_output=True,text=True,timeout=15)
                assert run.returncode==0,(name,run.stderr)
                metric=json.loads(run.stdout);assert metric['exit_code']==0 and metric['signal']==0 and not metric['timeout'],metric
                tag,value=decode(path.with_suffix('.frame.out').read_bytes())
                actual=[x['key'] for x in value] if tag==1 else value
                passed=(tag,actual)==(expected_tag,expected)
                assert passed or tag in [2,4],(name,tag,value)
                if mib==32: assert passed,(name,tag,value)
                metric.update(heap_limit_mib=mib,case=name,expected_result=passed,outcome_tag=tag,outcome=value if tag>=2 else 'checked',binary_sha256=binary_hash,input_sha256=hashlib.sha256(request).hexdigest())
                results.append(metric)
                print(json.dumps({k:metric[k] for k in ['heap_limit_mib','case','expected_result','outcome_tag','outcome']}),flush=True)
    finally:p.write_text(original)
(HERE/'results.json').write_text(json.dumps(results,indent=2)+'\n')
