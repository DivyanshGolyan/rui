"""Disposable evidence trial, not a measurement harness. No production mutations."""
import sys
import select
import argparse, hashlib, importlib.util, json, os, pathlib, subprocess, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
p=argparse.ArgumentParser();p.add_argument('binary');p.add_argument('output');p.add_argument('--logging',action='store_true');p.add_argument('--instruments',action='store_true');a=p.parse_args()
root=pathlib.Path(__file__).resolve().parents[2]; out=pathlib.Path(a.output).resolve();out.mkdir(parents=True,exist_ok=False)
store=out/'store';store.mkdir(mode=0o700); records=out/'records';records.mkdir(mode=0o700)
sys.path.insert(0,str(root/'tests/integration'))
spec=importlib.util.spec_from_file_location('fixture',root/'tests/integration/dispatch_integration.py');fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)
received=threading.Event();release=threading.Event()
class Endpoint(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_POST(self):
  self.rfile.read(int(self.headers['Content-Length']));received.set()
  if not release.wait(300):return
  body,*_=fixture.sse_answer('memory-trial','reasoning-1','answer-1','x'*100000)
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
endpoint=ThreadingHTTPServer(('127.0.0.1',0),Endpoint);threading.Thread(target=endpoint.serve_forever,daemon=True).start()
binary=str(pathlib.Path(a.binary).resolve());env=os.environ.copy()
if a.logging:env.update(MallocStackLogging='1',MallocStackLoggingNoCompact='1')
log=open(out/'host.stderr','w');host=subprocess.Popen([binary,'serve','--store',str(store),'--active-capacity','8','--provider-endpoint',f'http://127.0.0.1:{endpoint.server_port}/responses','--test-phase-trace','--test-sqlite-diagnostics'],stdout=subprocess.PIPE,stderr=log,text=True,env=env)
manifest={'binary':binary,'sha256':hashlib.sha256(pathlib.Path(binary).read_bytes()).hexdigest(),'logging':a.logging,'instruments':a.instruments,'success':False,'capacity':8,'answer_bytes':100000,'pid':host.pid,'snapshots':[]}
def cli(*args):return subprocess.check_output([binary,*args,'--store',str(store)],text=True,timeout=30)
def snapshot(name):
 d={'phase':name,'begin_ns':time.monotonic_ns(),'tools':[]}
 for label,cmd in [('footprint',['/usr/bin/footprint','-p',str(host.pid)]),('vmmap',['/usr/bin/vmmap','-summary',str(host.pid)]),('heap',['/usr/bin/heap','--noContent','-s',str(host.pid)])]+([('allocations',['/usr/bin/malloc_history',str(host.pid),'-allBySize'])] if a.logging else []):
  t=time.monotonic_ns()
  try:r=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=35);text=r.stdout;rc=r.returncode
  except subprocess.TimeoutExpired as e:text=str(e);rc='timeout'
  (out/f'{name}-{label}.txt').write_text(text);d['tools'].append({'name':label,'exit':rc,'begin_ns':t,'end_ns':time.monotonic_ns()})
 d['end_ns']=time.monotonic_ns();manifest['snapshots'].append(d);print(name,flush=True)
trace=None
try:
 if not select.select([host.stdout], [], [], 30)[0]:raise RuntimeError('Host startup timeout')
 ready=host.stdout.readline();manifest['ready']=ready
 if not ready.startswith('ready '):raise RuntimeError('Host not ready')
 if a.instruments:
  trace_log=open(out/'instruments.log','w')
  trace=subprocess.Popen(['xcrun','xctrace','record','--template','Allocations','--output',str(out/'host.trace'),'--attach',str(host.pid)],stdout=trace_log,stderr=subprocess.STDOUT)
  deadline=time.monotonic()+30
  while 'Ctrl-C to stop' not in (out/'instruments.log').read_text():
   if trace.poll() is not None or time.monotonic()>deadline:raise RuntimeError((out/'instruments.log').read_text())
   time.sleep(.25)
 snapshot('startup-idle')
 cli('configure','--session','direct/memory','--workspace',str(out),'--provider','codex','--model','fixture-model','--key','config','--record',str(records/'config.json'))
 (out/'input.txt').write_text('memory trial')
 cli('message','--session','direct/memory','--text',str(out/'input.txt'),'--key','message','--record',str(records/'message.json'))
 if not received.wait(20):raise RuntimeError('provider not reached')
 snapshot('active-awaiting-provider');release.set()
 deadline=time.monotonic()+25
 while True:
  obs=json.loads(cli('observe-command','--key','message'))
  if obs.get('observation',{}).get('result',{}).get('status')=='completed':break
  if time.monotonic()>deadline:raise RuntimeError(str(obs))
  time.sleep(.05)
 answer=cli('read-result','--key','message');assert answer=='x'*100000
 (out/'observation.json').write_text(json.dumps(obs,indent=2))
 deadline=time.monotonic()+25
 while True:
  inspection=json.loads(cli('inspect-session','--session','direct/memory'))
  if inspection['execution']['custody_occupied']=='0' and inspection['execution']['scratch_used_bytes']=='0':break
  if time.monotonic()>deadline:raise RuntimeError('Cleanup did not complete: '+str(inspection))
  time.sleep(.05)
 (out/'inspection.json').write_text(json.dumps(inspection,indent=2))
 snapshot('after-result');time.sleep(1);snapshot('retained-idle')
 assert all(t['exit']==0 for phase in manifest['snapshots'] for t in phase['tools']), 'snapshot tool failed'
 manifest['success']=True
finally:
 release.set()
 try:
  if trace is not None:
   if trace.poll() is None:
    trace.send_signal(2)
    try:trace.wait(timeout=45)
    except subprocess.TimeoutExpired:
     trace.kill();trace.wait();manifest['success']=False;manifest['trace_timeout']=True
   trace_log.close()
   trace_text=(out/'instruments.log').read_text()
   if trace.returncode != 0 or '[Error]' in trace_text or 'Recording completed.' not in trace_text:
    manifest['success']=False
    manifest['trace_error']=trace_text
 except Exception as error:
  manifest['success']=False
  manifest['trace_error']=str(error)
 finally:
  host.terminate()
  try:host.wait(timeout=5)
  except subprocess.TimeoutExpired:host.kill();host.wait()
  endpoint.shutdown();log.close();manifest['exit']=host.returncode
  (out/'manifest.json').write_text(json.dumps(manifest,indent=2))
if not manifest['success']:raise SystemExit('Collection failed; see manifest and logs')
