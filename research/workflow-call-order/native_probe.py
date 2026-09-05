import struct, subprocess, json, hashlib
from pathlib import Path
exe=Path(__file__).resolve().parents[2] / 'zig-out/bin/onepage-workflow-evaluator'
source='''export default async function ({ agent }) {
  let ordinal = 0;
  const call = (name) => agent({key: String(++ordinal), task: name});
  const a = (async () => { await call("A"); return await call("C"); })();
  const b = (async () => { await Promise.resolve(); await Promise.resolve(); return await call("B"); })();
  return await Promise.all([a, b]);
}'''
def u32(n):return struct.pack('<I',n)
def string(s):
 b=s.encode();return u32(len(b))+b
class Reader:
 def __init__(self,b):self.b=b;self.i=0
 def n(self,k):v=self.b[self.i:self.i+k];self.i+=k;return v
 def num(self,k):return int.from_bytes(self.n(k),'little')
 def text(self):return self.n(self.num(4)).decode()
 def data(self):
  t=self.num(1)
  if t==0:return None
  if t in (1,2):return t==2
  if t==3:return struct.unpack('<d',self.n(8))[0]
  if t==4:return self.text()
  if t==5:return [self.data() for _ in range(self.num(4))]
  if t==6:return {self.text():self.data() for _ in range(self.num(4))}
  raise ValueError(t)
def run(visible):
 frame=b'OPWE'+struct.pack('<H',1)+string(source)+b'\0'+struct.pack('<H',len(visible))
 for key,value in visible.items():frame+=string(key)+b'\0\4'+string(value)
 proc=subprocess.run([str(exe)],input=frame,capture_output=True,timeout=10)
 if proc.returncode:raise RuntimeError(proc.stderr.decode())
 r=Reader(proc.stdout);assert r.n(6)==b'OPWO\1\0';tag=r.num(1)
 if tag==1:return {'blocked':[Reader(r.n(r.num(4))).data() for _ in range(r.num(2))]}
 if tag==0:return {'completed':r.data()}
 return {'error_tag':tag,'error':r.text()}
print(json.dumps({'executable_sha256':hashlib.sha256(exe.read_bytes()).hexdigest(),'empty':run({}),'full_first_barrier':run({'1':'answer A','2':'answer B'}),'next_barrier':run({'1':'answer A','2':'answer B','3':'second answer B'})},indent=2))
