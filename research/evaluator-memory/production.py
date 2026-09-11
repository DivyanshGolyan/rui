#!/usr/bin/env python3
"""Measure the unchanged legacy executable, without claiming redesigned semantics."""
import fcntl,hashlib,json,pathlib,struct,subprocess,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[2]
HERE=pathlib.Path(__file__).resolve().parent

def string(b):return struct.pack('<I',len(b))+b
with open('/tmp/onepage-memory-experiments.lock','a') as lock:
 print('Waiting for shared experiment lock',flush=True);fcntl.flock(lock,fcntl.LOCK_EX)
 with tempfile.TemporaryDirectory(prefix='onepage-evaluator-production-') as tmp:
  prefix=pathlib.Path(tmp)/'install'
  build=['zig','build','-Doptimize=ReleaseSmall','-j2','--prefix',str(prefix)]
  result=subprocess.run(build,cwd=ROOT,capture_output=True,text=True,timeout=300)
  out={'revision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'build_command':build,'build_returncode':result.returncode,'build_stdout':result.stdout,'build_stderr':result.stderr,'zig':subprocess.check_output(['zig','version'],text=True).strip(),'runs':[]}
  if result.returncode==0:
   exe=prefix/'bin/onepage-workflow-evaluator';out['executable_sha256']=hashlib.sha256(exe.read_bytes()).hexdigest()
   for size,count in [(65536,1),(262144,1),(262144,1024)]:
    source=b'export default async function ({agent}) { const a=await agent({key:"a",task:"a"}); return a.length; }'
    payload=b'\5'+struct.pack('<I',count)+b''.join(b'\4'+string(b'x'*(size//count)) for _ in range(count))
    frame=b'OPWE'+struct.pack('<H',1)+string(source)+b'\0'+struct.pack('<H',1)+string(b'a')+b'\0'+payload
    start=time.monotonic();r=subprocess.run(['/usr/bin/time','-l',str(exe)],input=frame,capture_output=True,timeout=5)
    assert r.returncode==0,(r.returncode,r.stderr)
    assert r.stdout==b'OPWO'+struct.pack('<H',1)+b'\0\3'+struct.pack('<d',count),r.stdout
    out['runs'].append({'payload_bytes':size,'item_count':count,'input_frame_bytes':len(frame),'elapsed_seconds':time.monotonic()-start,'returncode':r.returncode,'outcome_hex':r.stdout.hex(),'time_l':r.stderr.decode()})
  (HERE/'production-results.json').write_text(json.dumps(out,indent=2)+'\n')
  assert result.returncode==0,result.stderr
