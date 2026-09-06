#!/usr/bin/env python3
"""Measure the existing native arena and disjoint-lifetime buffer reuse."""
import pathlib,subprocess,tempfile,json,hashlib
HERE=pathlib.Path(__file__).resolve().parent;ROOT=HERE.parents[1]
old_runner=ROOT/'research/evaluator-serial-probe/run.py'
ns={'__file__':str(old_runner),'__name__':'fixture_definitions'}
exec(old_runner.read_text().split('rows=[]')[0],ns)
frame,cases,decode=ns['frame'],ns['cases'],ns['decode']
fixtures={k:v[0] for k,v in cases.items() if k in ['tiny','fanout64','partial-replay','aggregate-256k','near-result-60k','objects20k']}
fixtures['large-source']=frame('/*'+'s'*60000+'*/ export default async function () {return 42;}')
for n,size in [(200,6000),(245,8000)]:
 source=f'export default async function ({{agent}}) {{ for(let i=0;i<{n};i++) await agent({{key:String(i),task:"work",input:"x".repeat({size})}}); return {n}; }}'
 fixtures[f'requests-{n}x{size}']=frame(source,{str(i):'done' for i in range(n)})
string=ns['string'];data=ns['data']
source='export default async function ({agent}) { const x=await agent({key:"0",task:"work"}); return x.a+x.b; }'
obj=b'\6'+(2).to_bytes(4,'little')+string('a')+data(2)+string('b')+data(3)
fixtures['visible-object-keys']=b'OPWE\1\0'+string(source)+data(None)+(1).to_bytes(2,'little')+string('0')+b'\0'+obj
bad=b'\6'+(2).to_bytes(4,'little')+string('a')+data(2)+string('a')+data(3)
fixtures['duplicate-argument-key']=b'OPWE\1\0'+string('export default async function () { return 42; }')+bad+(0).to_bytes(2,'little')
p=ROOT/'src/workflow_evaluator.zig'
# Build reproducibly from this experiment's known parent, even on reruns.
original=subprocess.check_output(['git','show','edc82c5:src/workflow_evaluator.zig'],cwd=ROOT,text=True)
base=original.replace('const std = @import("std");','const std = @import("std");\nconst probe_c = @cImport({ @cInclude("stdio.h"); });',1)
base=base.replace('    const allocator = arena.allocator();','''    defer _ = probe_c.fprintf(probe_c.__stderrp, "{\\"arena_used\\":%zu,\\"arena_capacity\\":%zu,\\"state_bytes\\":%zu,\\"key_workspace_bytes\\":%zu,\\"descriptor_workspace_bytes\\":%zu}\\n", arena.end_index, bridge_storage.len, @as(usize, @sizeOf(Evaluation)), @as(usize, protocol.Limits.data_entries * @sizeOf([]const u8)), @as(usize, protocol.Limits.workflow_output_bytes));
    const allocator = arena.allocator();''',1)
reuse=base.replace('.descriptor_scratch = try allocator.alloc(u8, protocol.Limits.workflow_output_bytes),','.descriptor_scratch = std.mem.sliceAsBytes(key_storage)[0..protocol.Limits.workflow_output_bytes],')
reuse=reuse.replace('        const key_storage = try allocator.alloc([]const u8, protocol.Limits.data_entries);','''        comptime { if (protocol.Limits.data_entries * @sizeOf([]const u8) < protocol.Limits.workflow_output_bytes) @compileError("probe reuse capacity insufficient"); }
        const key_storage = try allocator.alloc([]const u8, protocol.Limits.data_entries);''')
rows=[]
for mode,source in [('baseline',base),('reuse',reuse)]:
 p.write_text(source)
 subprocess.run(['zig','build','evaluator-probe','-Doptimize=ReleaseSafe'],cwd=ROOT,check=True)
 exe=ROOT/'zig-out/bin/onepage-workflow-evaluator'
 for name,request in fixtures.items():
  result=subprocess.run([str(exe)],input=request,capture_output=True,timeout=10,close_fds=True,env={})
  assert result.returncode==0,(mode,name,result.stderr.decode(errors='replace'))
  tag,value=decode(result.stdout);metric=json.loads(result.stderr.decode())
  if name in cases:
   expected_tag,expected=cases[name][1:];assert tag==expected_tag,(mode,name,tag,value)
   if tag==1:assert [x['key'] for x in value]==expected
   else:assert value==expected
  elif name=='visible-object-keys':assert tag==0 and value==5
  elif name=='duplicate-argument-key':assert (tag,value)==(5,'DuplicateKey')
  elif name=='large-source':assert tag==0 and value==42
  elif name=='requests-200x6000':assert tag==0 and value==200
  elif name=='requests-245x8000':
   assert (tag,value)==((4,'BridgeArena') if mode=='baseline' else (0,245)),(mode,name,tag,value)
  metric.update(mode=mode,case=name,input_bytes=len(request),output_bytes=len(result.stdout),outcome_tag=tag,result=value if not isinstance(value,(str,list)) else (value if tag>=2 else 'checked'),source_sha256=hashlib.sha256(source.encode()).hexdigest(),binary_sha256=hashlib.sha256(exe.read_bytes()).hexdigest())
  rows.append(metric);print(json.dumps(metric),flush=True)
(HERE/'baseline-evaluator.zig.txt').write_text(base)
(HERE/'results.json').write_text(json.dumps(rows,indent=2)+'\n')
