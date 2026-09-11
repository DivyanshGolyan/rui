#!/usr/bin/env python3
"""Joint retention, responsiveness and reuse experiment; serial OS advisory lock."""
import sys,argparse,fcntl,hashlib,json,pathlib,platform,re,resource,signal,socket,subprocess,tempfile,time
from paced_format import dimensions
HERE=pathlib.Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--build',type=pathlib.Path,default=pathlib.Path('/tmp/onepage-transport-memory-build'));p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--match',default='');p.add_argument('--quick',action='store_true');p.add_argument('--sanitize',action='store_true');a=p.parse_args()
b=a.build.resolve();out=a.output.resolve()
if out.exists() and any(out.iterdir()):p.error('output must be empty')
out.mkdir(parents=True,exist_ok=True)
ssl=pathlib.Path('/opt/homebrew/Cellar/openssl@3/3.6.3')
binary=b/('asymmetric-'+hashlib.sha256(str(out).encode()).hexdigest()[:12])
command=['cc','-O2','-g','-Wall','-Wextra','-Wno-deprecated-declarations','-DCURL_STATICLIB','-I'+str(b/'curl-8.22.0/include'),'-I'+str(ssl/'include'),str(HERE/'asymmetric.c'),str(b/'curl-8.22.0/lib/.libs/libcurl.a'),str(b/'ng/lib/libnghttp2.a'),'-L'+str(ssl/'lib'),'-lssl','-lcrypto','-lz','-lpthread','-framework','CoreFoundation','-framework','CoreServices','-framework','Security','-framework','SystemConfiguration','-o',str(binary)]
if a.sanitize:command[1:1]=['-fsanitize=address,undefined','-fno-omit-frame-pointer']
subprocess.run(command,check=True)
def read(cmd):return subprocess.check_output(cmd,text=True).strip()
sourcefiles=['asymmetric.c','probe.c','asymmetric_run.py','asymmetric_server.py','capture_control.py','paced_format.py','asymmetric_format.py','link_proxy.py']
(out/'sources').mkdir()
for name in sourcefiles:(out/'sources'/name).write_bytes((HERE/name).read_bytes())
metadata={'utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'revision':read(['git','rev-parse','HEAD']),'machine':platform.uname()._asdict(),'cpu':read(['sysctl','-n','machdep.cpu.brand_string']),'memory':read(['sysctl','-n','hw.memsize']),'compiler':read(['cc','--version']),'runner_argv':sys.argv,'command':command,'linked':read(['otool','-L',str(binary)]),'openssl':read([str(ssl/'bin/openssl'),'version','-a']),'python_dependencies':read([str(b/'venv/bin/pip'),'freeze']),'sources_sha256':{f:hashlib.sha256((HERE/f).read_bytes()).hexdigest() for f in sourcefiles},'binaries_sha256':{str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in [binary,b/'curl-8.22.0/lib/.libs/libcurl.a',b/'ng/lib/libnghttp2.a',ssl/'lib/libssl.3.dylib',ssl/'lib/libcrypto.3.dylib']}}
(out/'metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
# name, concurrency, protocol, bursts, bytes per capture, strategy, delay us, stall ms, slots, idle cache, fail one sink
cases=[]
def case(name,protocol,upload,base,growth=0,mixed=0,stall=0,delay_ms=40,up=33554432,n=1000):
 tokens,hz,events=5,20,60;record,terminal=dimensions(tokens,events);payload=record*events+terminal
 return (name,n,protocol,4 if growth else 1,payload,2,0,stall,16,16,0,0,32768,16384,1,1000,1000,0,tokens,events,hz,upload,base,growth,mixed,up,67108864,delay_ms)
for upload in [16384,65536]:
 tag=f'u{upload//1024}'
 cases.append(case(f'h2-wan128-{tag}',2,upload,131072,up=8388608))
 cases.append(case(f'h2-wan1024-{tag}',2,upload,1048576))
 cases.append(case(f'h1-wan1024-{tag}',1,upload,1048576))
 cases.append(case(f'h2-local1024-{tag}',2,upload,1048576,delay_ms=0,up=1073741824))
 cases.append(case(f'h2-growing-{tag}',2,upload,65536,growth=1))
 cases.append(case(f'h2-overlap-stall-{tag}',2,upload,1048576,mixed=1,stall=3000))
cases.append(case('h1-wan128-debug',1,16384,131072,up=8388608))
for upload in [16384,65536]:cases.append(case(f'h1-socket16-u{upload//1024}',1,upload,1048576)+(16384,))
for sb in [0,16384]:cases.append(case(f'h1-single-socket{sb}',1,16384,4194304,n=1)+(sb,))
if a.quick:cases=[case(f'asymmetric-h{protocol}-smoke',protocol,16384,1048576,mixed=1,stall=3000,delay_ms=10,up=4194304,n=8) for protocol in [1,2]]
cases=[c for c in cases if re.search(a.match,c[0])]
if not cases:p.error('no matching cases')
with open('/tmp/onepage-memory-experiments.lock','a') as lock:
 print('Waiting for shared benchmark lock',flush=True);fcntl.flock(lock,fcntl.LOCK_EX);print('Acquired shared benchmark lock',flush=True)
 for case in cases:
  name,n,protocol,bursts,payload,strategy,delay,stall,slots,cache,fail,*extra=case
  warm,rate,receive,hosts,streams,servercap,known,tokens,events,hz,upload,request_base,growth,mixed,up_rate,down_rate,delay_ms,*optional=extra
  socket_buffer=optional[0] if optional else 0
  with tempfile.TemporaryDirectory(prefix='onepage-capture-',dir='/tmp') as tmp:
   scratch=pathlib.Path(tmp)
   subprocess.run([str(ssl/'bin/openssl'),'req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(scratch/'key.pem'),'-out',str(scratch/'cert.pem'),'-days','1','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost,IP:127.0.0.1'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   with socket.socket() as port_socket:port_socket.bind(('127.0.0.1',0));port=port_socket.getsockname()[1]
   with socket.socket() as port_socket:port_socket.bind(('127.0.0.1',0));proxy_port=port_socket.getsockname()[1]
   (out/(name+'-os-before.txt')).write_text(read(['vm_stat'])+'\n'+read(['netstat','-m'])+'\n')
   def limits():resource.setrlimit(resource.RLIMIT_NOFILE,(8192,8192))
   with open(out/(name+'-server.jsonl'),'w') as slog,open(out/(name+'-server.stderr'),'w') as serr,open(out/(name+'.stderr'),'w') as cerr,open(out/(name+'-proxy.jsonl'),'w') as plog,open(out/(name+'-proxy.stderr'),'w') as perr:
    server=subprocess.Popen([str(b/'venv/bin/python'),str(HERE/'asymmetric_server.py'),str(n),str(protocol),str(bursts),str(port),str(scratch/'cert.pem'),str(scratch/'key.pem'),str(tokens),str(events),str(hz),str(request_base),str(growth),str(mixed)],stdout=slog,stderr=serr,preexec_fn=limits)
    client=control=proxy=None
    try:
     for _ in range(200):
      if '"ready": true' in (out/(name+'-server.jsonl')).read_text():break
      assert server.poll() is None;time.sleep(.05)
     else:raise TimeoutError('server readiness')
     proxy=subprocess.Popen([str(b/'venv/bin/python'),str(HERE/'link_proxy.py'),str(proxy_port),str(port),str(up_rate),str(down_rate),str(delay_ms)],stdout=plog,stderr=perr,preexec_fn=limits)
     for _ in range(200):
      if '"ready": true' in (out/(name+'-proxy.jsonl')).read_text():break
      assert proxy.poll() is None;time.sleep(.05)
     else:raise TimeoutError('proxy readiness')
     argv=[str(binary),str(n),str(protocol),str(bursts),str(payload),str(strategy),str(delay),str(stall),str(slots),str(cache),f'https://localhost:{proxy_port}',tmp,str(fail),str(warm),str(rate),str(receive),str(hosts),str(streams),str(tokens),str(events),str(upload),str(request_base),str(growth),str(mixed),str(socket_buffer)]
     client=subprocess.Popen(argv,stdout=subprocess.PIPE,stderr=cerr,text=True,bufsize=1)
     # Independent watchdog bounds the entire process, including missing stdout.
     import threading
     watchdog=threading.Timer(180,client.kill);watchdog.start()
     rows=[]
     try:
      with open(out/(name+'.jsonl'),'w') as raw:
       for line in client.stdout:
        raw.write(line);raw.flush();row=json.loads(line);rows.append(row)
        if row.get('ready'):control=subprocess.Popen([str(b/'venv/bin/python'),str(HERE/'capture_control.py'),str(scratch/'control'),str(out/(name+'-controls.jsonl'))],stdout=subprocess.DEVNULL,stderr=cerr)
        if row.get('stop_controls') and control:control.send_signal(signal.SIGINT)
      rc=client.wait(timeout=5)
     finally:watchdog.cancel()
     assert control is not None
     if rc and control.poll() is None:control.send_signal(signal.SIGINT)
     control_rc=control.wait(timeout=5)
     with open(out/'summary.jsonl','a') as summary:summary.write(json.dumps({'case':case,'command':argv,'returncode':rc,'control_returncode':control_rc,'measurements':rows})+'\n')
     print(name,rc,control_rc,flush=True)
     assert rc==control_rc==0 and rows[-1].get('success')
    finally:
     for proc in [control,client,proxy,server]:
      if proc and proc.poll() is None:
       proc.send_signal(signal.SIGINT)
       try:proc.wait(timeout=5)
       except subprocess.TimeoutExpired:proc.kill();proc.wait()
   (out/(name+'-os-after.txt')).write_text(read(['vm_stat'])+'\n'+read(['netstat','-m'])+'\n')
   assert json.loads((out/(name+'-server.jsonl')).read_text().splitlines()[-1])['requests_per_burst']==[n]*bursts
