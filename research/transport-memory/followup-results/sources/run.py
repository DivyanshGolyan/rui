#!/usr/bin/env python3
"""Run serially under the lock shared by the four memory experiments."""
import argparse, re, shutil, fcntl, hashlib, json, os, pathlib, platform, resource, signal, socket, subprocess, time
HERE=pathlib.Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--build',type=pathlib.Path,default=pathlib.Path('/tmp/onepage-transport-memory-build'));p.add_argument('--quick',action='store_true');p.add_argument('--match',default='');p.add_argument('--sanitize',action='store_true');p.add_argument('--output',type=pathlib.Path,default=HERE/'results');args=p.parse_args();b=args.build.resolve();out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
def cmd(a,**kw):return subprocess.check_output(a,text=True,**kw).strip()
ssl=pathlib.Path('/opt/homebrew/Cellar/openssl@3/3.6.3')
compile=['cc','-O2','-Wall','-Wextra','-Wno-deprecated-declarations','-DCURL_STATICLIB','-I'+str(b/'curl-8.22.0/include'),'-I'+str(ssl/'include'),str(HERE/'probe.c'),str(b/'curl-8.22.0/lib/.libs/libcurl.a'),str(b/'ng/lib/libnghttp2.a'),'-L'+str(ssl/'lib'),'-lssl','-lcrypto','-lz','-framework','CoreFoundation','-framework','CoreServices','-framework','Security','-framework','SystemConfiguration','-o',str(b/'probe')]
if args.sanitize:compile[1:1]=['-fsanitize=address,undefined','-fno-omit-frame-pointer']
subprocess.run(compile,check=True)
cert=b/'cert.pem';key=b/'key.pem'
if not cert.exists():subprocess.run([str(ssl/'bin/openssl'),'req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(key),'-out',str(cert),'-days','2','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost,IP:127.0.0.1'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
meta={'revision':cmd(['git','rev-parse','HEAD']),'machine':platform.uname()._asdict(),'memory_bytes':cmd(['sysctl','-n','hw.memsize']),'compiler':cmd(['cc','--version']),'compile':compile,'openssl':cmd([str(ssl/'bin/openssl'),'version','-a']),'dependencies':cmd([str(b/'venv/bin/pip'),'freeze']),'linked':cmd(['otool','-L',str(b/'probe')]),'sources_sha256':{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in [HERE/'probe.c',HERE/'server.py',HERE/'run.py']},'curl_config':(b/'curl-8.22.0/libcurl.pc').read_text(),'nghttp2_sha256':'e05cb1388eaca3830aded4ccf20044b6e1ac1a61411dcca11b0437c4285c8bc2','curl_sha256':'f7ef3ae8a22e521f289803fe93543eb64c329b58aa73a9e224dfd915a2a5f4f7'}
(out/'sources').mkdir(exist_ok=True)
for source in ['probe.c','server.py','run.py','build.py']:shutil.copy2(HERE/source,out/'sources'/source)
(out/'metadata.json').write_text(json.dumps(meta,indent=2)+'\n')
# name, concurrency, request bytes, response bytes, items, sink mode, idle cache, buffer bytes, HTTP version
cases=[]
for proto in [1,2]:
 for n in [1,100,1000]:cases.append((f'h{proto}-n{n}',n,1024,65536,1,0,-1,16384,proto))
for proto in [1,2]:
 for cache in [1,16]:cases.append((f'h{proto}-cache{cache}',1000,1024,65536,1,0,cache,16384,proto))
 for buf in [1024,1048576]:cases.append((f'h{proto}-buffer{buf}',100,1024,1048576,1,0,16,buf,proto))
 for size,items in [(1048576,1),(1048576,4096),(1024,128)]:cases.append((f'h{proto}-request{size}-items{items}',100,size,65536,items,0,16,16384,proto))
 for size in [65536,1048576,16777216]:cases.append((f'h{proto}-pause-{size}',8,1024,size,1,1,16,16384,proto))
 cases.append((f'h{proto}-slow-pause',100,1024,65536,1,2,16,16384,proto))
 cases.append((f'h{proto}-slow-write',100,1024,1048576,1,3,16,16384,proto))
 cases.append((f'h{proto}-sink-error',8,1024,65536,1,4,16,16384,proto))
for proto in [1,2]:
 for size in [65536,1048576,16777216]:cases.append((f'h{proto}-control-{size}',8,1024,size,1,0,16,16384,proto))
 for mode in [1,2]:cases.append((f'h{proto}-stall1000-mode{mode}',1000,1024,65536,1,mode,16,16384,proto))
for proto in [1,2]:
 cases.append((f'h{proto}-upload16k-small',1000,1024,65536,1,0,16,16384,proto,16384))
 cases.append((f'h{proto}-upload16k-large',100,1048576,65536,1,0,16,16384,proto,16384))
if args.quick:cases=[('smoke-h1',1,1024,65536,1,0,16,16384,1),('smoke-h2',8,1024,65536,1,0,16,16384,2)]
cases=[c for c in cases if re.search(args.match,c[0])]
with open('/tmp/onepage-memory-experiments.lock','a') as lock:
 print('Waiting for shared benchmark lock',flush=True);fcntl.flock(lock,fcntl.LOCK_EX);print('Acquired shared benchmark lock',flush=True)
 for case in cases:
  name,n,r,o,items,mode,cache,buf,proto,*extra=case
  upload=extra[0] if extra else 0
  with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
  prefix=out/name
  (out/(name+'-vm-before.txt')).write_text(cmd(['vm_stat']))
  (out/(name+'-network-before.txt')).write_text(cmd(['netstat','-m']))
  with open(out/(name+'-server.jsonl'),'w') as serverlog,open(out/(name+'-server.stderr'),'w') as err:
   def limits():resource.setrlimit(resource.RLIMIT_NOFILE,(8192,8192))
   server=subprocess.Popen([str(b/'venv/bin/python'),str(HERE/'server.py'),str(n),str(r),str(o),str(items),str(proto),str(port),str(cert),str(key)],stdout=serverlog,stderr=err,preexec_fn=limits)
   try:
    for _ in range(200):
     if '"ready": true' in (out/(name+'-server.jsonl')).read_text():break
     if server.poll() is not None:raise RuntimeError('server exited')
     time.sleep(.05)
    else:raise TimeoutError('server readiness')
    argv=[str(b/'probe'),str(n),str(r),str(o),str(items),str(mode),str(cache),str(buf),str(proto==2 and 1 or 0),f'https://localhost:{port}/',str(cert),str(upload)]
    with open(out/(name+'.jsonl'),'w') as raw,open(out/(name+'.stderr'),'w') as cerr:
     result=subprocess.run(argv,stdout=raw,stderr=cerr,timeout=135)
    rows=[json.loads(x) for x in (out/(name+'.jsonl')).read_text().splitlines()]
    record={'case':case,'command':argv,'returncode':result.returncode,'measurements':rows}
    with open(out/'summary.jsonl','a') as f:f.write(json.dumps(record)+'\n')
    print(name,'exit',result.returncode,flush=True)
    if result.returncode:raise RuntimeError(f'{name} failed; raw evidence retained')
   finally:
    server.send_signal(signal.SIGINT)
    try:server.wait(timeout=5)
    except subprocess.TimeoutExpired:server.kill();server.wait()
  assert json.loads((out/(name+'-server.jsonl')).read_text().splitlines()[-1])['requests_integrity_checked']==n
  (out/(name+'-vm-after.txt')).write_text(cmd(['vm_stat']))
  (out/(name+'-network-after.txt')).write_text(cmd(['netstat','-m']))
