"""Run: python3 research/host-capacity-scaling/run.py [--smoke]. macOS only."""
import argparse, hashlib, json, os, pathlib, platform, resource, select, shutil, signal, sqlite3, subprocess, sys, tempfile, time
P=pathlib.Path(__file__).resolve().parent
p=argparse.ArgumentParser(); p.add_argument('--smoke',action='store_true'); p.add_argument('--capacity',type=int,choices=[100,500,1000]); p.add_argument('--curl-build',type=pathlib.Path); p.add_argument('--native-poll',action='store_true'); p.add_argument('--refined',action='store_true'); a=p.parse_args()
if a.refined and a.capacity:
    p.error('--refined cannot be combined with --capacity')
resource.setrlimit(resource.RLIMIT_NOFILE,(8192,resource.getrlimit(resource.RLIMIT_NOFILE)[1]))
flags=['-O2','-std=c11','-Wall','-Wextra','-Werror']
link=['-lcurl','-lsqlite3','-lpthread']
if a.curl_build:
    flags += ['-I'+str(a.curl_build/'include')]
    link = [str(a.curl_build/'lib/.libs/libcurl.a'),'-framework','CoreFoundation','-framework','Security','-framework','SystemConfiguration','-lz','-lsqlite3','-lpthread']
meta={'date':time.strftime('%Y-%m-%dT%H:%M:%S%z'),'platform':platform.platform(),'python':sys.version,
      'native_poll':a.native_poll,'curl_build':str(a.curl_build),'link_flags':link,'fd_limit':resource.getrlimit(resource.RLIMIT_NOFILE),'flags':flags,
      'machine':subprocess.check_output(['sysctl','hw.model','hw.memsize','hw.logicalcpu','hw.pagesize'],text=True),
      'clang':subprocess.check_output(['clang','--version'],text=True),
      'source_hashes':{f:hashlib.sha256((P/f).read_bytes()).hexdigest() for f in ('prototype.c','server.py','run.py')},
      'disk_free_bytes':shutil.disk_usage('/tmp').free}
if a.curl_build:
    meta['curl_config']=(a.curl_build/'lib/curl_config.h').read_text()
    meta['curl_archive_sha256']=hashlib.sha256((a.curl_build/'lib/.libs/libcurl.a').read_bytes()).hexdigest()
output=P/('smoke.json' if a.smoke else ('single.json' if a.capacity else 'results.json'))
if a.refined: output=P/('refined-smoke.json' if a.smoke else 'refined-results.json')
results={'metadata':meta,'runs':[]}
def save(): output.write_text(json.dumps(results,indent=2)+'\n')
with tempfile.TemporaryDirectory(prefix='onepage-capacity-PROTOTYPE-') as tmp:
    root=pathlib.Path(tmp); binary=root/'probe'; cert=root/'cert.pem'; key=root/'key.pem'
    subprocess.run(['clang',*flags,str(P/'prototype.c'),'-o',str(binary),*link],check=True)
    subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(key),'-out',str(cert),'-days','1','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost','-addext','extendedKeyUsage=serverAuth','-addext','keyUsage=digitalSignature,keyEncipherment,keyCertSign'],check=True,capture_output=True)
    cases=[(10,1,1,m) for m in (1,2)] if a.smoke else [(c,1,4,m) for order in [(100,500,1000),(500,1000,100),(1000,100,500)] for c in order for m in ((1,2) if order[0]!=500 else (2,1))]+[(1000,5,4,0)]
    if a.refined: cases=[(10,1,1,3)] if a.smoke else [(c,1,4,3) for order in [(100,500,1000),(500,1000,100),(1000,100,500)] for c in order]
    if a.capacity: cases=[(a.capacity,1,4,m) for m in (1,2)]
    for index,(capacity,cycles,seconds,control) in enumerate(cases):
        case=root/str(index); case.mkdir(); server=None; client=None
        row={'index':index,'capacity':capacity,'cycles':cycles,'seconds':seconds,'control_mode':control}
        try:
            server=subprocess.Popen([sys.executable,str(P/'server.py'),'--cert',str(cert),'--key',str(key),'--capacity',str(capacity),'--cycles',str(cycles),'--seconds',str(seconds),*(['--control'] if control else [])],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            if not select.select([server.stdout],[],[],10)[0]: raise RuntimeError('server readiness timeout')
            ready=json.loads(server.stdout.readline()); port=ready['port']
            env={k:v for k,v in os.environ.items() if not k.startswith('ONEPAGE_PROOF_')}; env.update(ONEPAGE_PROOF_CYCLES=str(cycles),ONEPAGE_PROOF_EFFECT_OUTPUT_LIMIT=str(1024*1024),ONEPAGE_PROOF_HOST_SCRATCH_QUOTA=str(256*1024*1024))
            if a.native_poll: env['ONEPAGE_PROOF_NATIVE_POLL']='1'
            if a.smoke: env['ONEPAGE_PROOF_VERBOSE']='1'
            env['ONEPAGE_PROOF_CONTROL']=str(control)
            if not control: env['ONEPAGE_PROOF_MEMORY_DETAIL']='1'
            started=time.monotonic()
            client=subprocess.Popen([str(binary),'integrated',str(capacity),f'https://localhost:{port}/responses',str(cert),str(case),str(case/'proof.sqlite3'),'owner','90','model-only'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
            out,err=client.communicate(timeout=150 if cycles==1 else 240)
            row.update(client_returncode=client.returncode,client_stderr=err,wall_seconds=time.monotonic()-started)
            row['client']=json.loads(out)
            server.terminate(); sout,serr=server.communicate(timeout=10)
            row.update(server_lines=[json.loads(l) for l in sout.splitlines()],server_stderr=serr)
            s=row['server_lines'][-1]; c=row['client']; n=capacity*cycles
            with sqlite3.connect(case/'proof.sqlite3') as db:
                stored=db.execute('SELECT coalesce(sum(length(bytes)),0) FROM artifact').fetchone()[0]
                integrity=db.execute('PRAGMA integrity_check').fetchone()[0]
            row['stored_bytes']=stored; row['integrity']=integrity
            row['checks']={
                'client_success':client.returncode==0 and c['completion_classes']['success']==n-bool(control) and c['resolution_rows']==n and not c['host_fatal'],
                'full_cohorts':s['accepted']==n and s['completed']==n-bool(control) and s['cancelled']==bool(control) and s['disconnected']==0 and len(s['waves'])==cycles and all(w['concurrent']==capacity for w in s['waves']),
                'exact_bytes':c['received_bytes']==s['body_bytes']==s['expected_body_bytes'] and stored==c['received_bytes']-c['control']['discarded_bytes'],
                'cleanup':c['scratch_logical_final']==0 and c['closed']['fds']==c['unopened']['fds'],
                'integrity':integrity=='ok',
                'control':not control or (c['control']['stop_rows']==1 and c['control']['cancelled_rows']==1 and 0<c['control']['request_ns']<=c['control']['commit_ns']<=c['control']['removed_ns']<=c['control']['released_ns'] and c['control']['pending_at_commit']>=1 and c['control']['request_ns']<c['control']['ordinary_finished_ns'])}
            row['passed']=all(row['checks'].values())
        except Exception as e: row.update(passed=False,error=repr(e))
        finally:
            for proc in (client,server):
                if proc is not None and proc.poll() is None:
                    proc.terminate()
                    try: proc.communicate(timeout=5)
                    except subprocess.TimeoutExpired: proc.kill(); proc.communicate()
            results['runs'].append(row); save(); shutil.rmtree(case)
        print(json.dumps({'index':index,'capacity':capacity,'cycles':cycles,'passed':row['passed'],'error':row.get('error'),'checks':row.get('checks')}),flush=True)
        if not row['passed']: raise SystemExit(1)
print(output)
