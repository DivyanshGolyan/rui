#!/usr/bin/env python3
"""Bounded, serial, offline-after-dependency-download QuickJS decoding probe."""
import argparse, ctypes, fcntl, hashlib, json, os, pathlib, platform, resource, struct, subprocess, tempfile, time, tracemalloc, urllib.request
HERE=pathlib.Path(__file__).resolve().parent
PIN='1ab8676f4b6d6d669baeb5f21790fb9734636a20'
URL=f'https://github.com/quickjs-ng/quickjs/archive/{PIN}.tar.gz'
p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,default=None);p.add_argument('--source',type=pathlib.Path);p.add_argument('--sanitize',action='store_true');args=p.parse_args()
if args.output is None:args.output=HERE/('sanitizer-results.json' if args.sanitize else 'results.json')

def script(mode,n,results=32):
    setup="const a=await lookup(0); if(a.length===0)throw Error('empty');"
    if mode=='selective': body="const a=await lookup(SELECTED); mark('loaded'); if(a[0].length===0)throw Error('empty');"
    elif mode=='separate':body="for(let i=0;i<20;i++){let a=await lookup(0);a[0]='changed';let b=await lookup(0);if(a===b||b[0]==='changed')throw Error('alias');mark('loaded');}"
    elif mode=='promise':body="const p=lookup(0);const a=await p;a[0]='changed';for(let i=0;i<10000;i++)if(await p!==a)throw Error('identity');mark('loaded');"
    elif mode=='retained':body=f"let held=[];for(let i=0;i<{n};i++)held.push(await lookup(0));mark('loaded');held=null;"
    elif mode=='burst':body="for(let j=0;j<3;j++){let held=[];for(let i=0;i<4;i++)held.push(await lookup(0));mark('burst_loaded');held=null;await 0;mark('burst_released');}"
    elif mode=='unicode':body="const a=await lookup(0);if(a[0] !== '😀é中')throw Error('unicode');mark('loaded');"
    else:body=setup+"mark('loaded');"
    return '(async()=>{'+body.replace('SELECTED',str(min(31,results-1)))+'return 1;})()'

def prepare(path,total,count,results,width=1,corrupt=None):
    # Full integrity check precedes read-only handoff. No payload-sized parent object.
    tracemalloc.start();before=tracemalloc.get_traced_memory()[0]
    h=hashlib.sha256();written=0
    with path.open('wb',buffering=0) as f:
        def emit(b):
            nonlocal written
            f.write(b);h.update(b);written+=len(b)
        for _ in range(results):
            emit(struct.pack('<II',count,width))
            for i in range(count):
                size=total//count+(i<total%count)
                if width==2:
                    b='😀é中'.encode('utf-16le');emit(struct.pack('<I',len(b)//2));emit(b)
                else:
                    emit(struct.pack('<I',size));chunk=b'x'*min(size,16384)
                    while size:
                        n=min(size,len(chunk));emit(chunk[:n]);size-=n
        os.fsync(f.fileno())
    with path.open('rb',buffering=0) as f:
        check=hashlib.sha256()
        while b:=f.read(16384):check.update(b)
    assert check.digest()==h.digest()
    parent_current,parent_peak=tracemalloc.get_traced_memory();tracemalloc.stop()
    if corrupt=='short':os.truncate(path,written-1)
    elif corrupt=='width':
        with path.open('r+b') as f:f.seek(4);f.write(struct.pack('<I',3))
    elif corrupt=='length':
        with path.open('r+b') as f:f.seek(8);f.write(struct.pack('<I',0xffffffff))
    return written//results,{'scratch_logical_bytes':path.stat().st_size,'scratch_allocated_bytes':path.stat().st_blocks*512,'sha256_before_fault':h.hexdigest(),'parent_python_current_delta':parent_current-before,'parent_python_peak':parent_peak}

with open('/tmp/onepage-memory-experiments.lock','a') as lock:
    print('Waiting for shared experiment lock',flush=True);fcntl.flock(lock,fcntl.LOCK_EX)
    with tempfile.TemporaryDirectory(prefix='onepage-evaluator-memory-') as tmp:
        tmp=pathlib.Path(tmp)
        if args.source:source=args.source.resolve();archive_hash=None
        else:
            archive=tmp/'qjs.tar.gz';urllib.request.urlretrieve(URL,archive);archive_hash=hashlib.sha256(archive.read_bytes()).hexdigest();assert archive_hash=='c788fe4f65c95ecfa4055c8778e7cb221f68fcc3315686627b0856da5c38514e'
            subprocess.run(['tar','-xzf',str(archive),'-C',str(tmp)],check=True);source=tmp/f'quickjs-{PIN}'
        binary=tmp/'probe'
        command=['clang','-O2','-g','-std=gnu11','-funsigned-char','-D_GNU_SOURCE','-DQUICKJS_NG_BUILD=1','-I',str(source),str(HERE/'probe.c')]+[str(source/x) for x in ['dtoa.c','libregexp.c','libunicode.c']]+['-lm','-lpthread','-o',str(binary)]
        if args.sanitize:command[1:1]=['-fsanitize=address,undefined','-fno-sanitize-recover=all']
        subprocess.run(command,check=True)
        metric_lib=tmp/'metrics.dylib'
        subprocess.run(['clang','-shared','-fPIC',str(HERE/'metrics.c'),'-o',str(metric_lib)],check=True)
        metrics=ctypes.CDLL(str(metric_lib));metrics.physical_footprint.restype=ctypes.c_uint64
        parent_cold=metrics.physical_footprint()
        cases=[]
        for buffered in [0,1]:
            for size in [65536,1048576,4194304]:cases.append((f'bytes-{size}',size,1,1,buffered,'once',1,None,0,1))
            for count in [1,1024,16384]:cases.append((f'items-{count}',1048576,count,1,buffered,'once',1,None,0,1))
            for mode in ['selective','separate','promise','retained','burst']:cases.append((mode,1048576,64,32 if mode=='selective' else 1,buffered,mode,4,None,0,1))
            for saved in [1,32,1024]:cases.append((f'saved-{saved}',65536,1,saved,buffered,'selective',1,None,0,1))
            cases += [('heap-exhaustion',4194304,1,1,buffered,'retained',5,None,0,1),('native-exhaustion',65536,1,1,buffered,'once',1,None,1,1)]
            for fault in ['short','width','length']:cases.append((fault,65536,4,1,buffered,'once',1,fault,0,1))
            cases.append(('unicode',8,1,1,buffered,'unicode',1,None,0,2))
        if args.sanitize:cases=[c for c in cases if c[0] in ['bytes-1048576','short','width','length','unicode','heap-exhaustion','native-exhaustion']]
        out={'harness_sha256':{f:hashlib.sha256((HERE/f).read_bytes()).hexdigest() for f in ['probe.c','run.py','metrics.c']},'sanitized':args.sanitize,'revision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=HERE.parents[1],text=True).strip(),'recorded_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'source_sha256':{f:hashlib.sha256((source/f).read_bytes()).hexdigest() for f in ['quickjs.c','quickjs.h','dtoa.c','libregexp.c','libunicode.c']},'machine':platform.platform(),'hardware':subprocess.check_output(['sysctl','hw.model','hw.memsize','hw.ncpu'],text=True) if platform.system()=='Darwin' else None,'parent_cold_physical_footprint':parent_cold,'uname':list(platform.uname()),'python':platform.python_version(),'compiler':subprocess.check_output(['clang','--version'],text=True),'quickjs_pin':PIN,'archive_sha256':archive_hash,'compile_command':command,'engine_limit':16777216,'native_window':16384,'runs':[]}
        for name,size,count,results,buffered,mode,n,fault,native_fail,width in cases:
            path=tmp/'input'
            cache_before=subprocess.check_output(['vm_stat'],text=True) if name=='saved-1024' and platform.system()=='Darwin' else None
            result_size,prep=prepare(path,size,count,results,width,fault)
            if cache_before:prep['global_vm_stat_before']=cache_before;prep['global_vm_stat_after_preparation']=subprocess.check_output(['vm_stat'],text=True)
            prep['parent_prepared_physical_footprint']=metrics.physical_footprint()
            fd=os.open(path,os.O_RDONLY);start=time.monotonic()
            try:r=subprocess.run([str(binary),str(fd),str(result_size),str(results),str(buffered),str(native_fail),script(mode,n,results)],pass_fds=(fd,),env={},input='',capture_output=True,text=True,timeout=5)
            finally:os.close(fd)
            records=[json.loads(x) for x in r.stdout.splitlines()]
            expected=10 if fault or native_fail or name=='heap-exhaustion' else 0
            assert r.returncode==expected,(name,buffered,r.returncode,r.stderr,records)
            assert r.stderr=='',r.stderr
            expected_failure={'short':'short_read','width':'malformed_width','length':'invalid_range','native-exhaustion':'native_exhaustion','heap-exhaustion':'engine_exhaustion'}.get(name,'none')
            assert records[-1]['failure']==expected_failure,(name,records)
            assert any(m['phase']==('failed' if expected else 'completed') for m in records)
            assert not expected or not any(m['phase']=='completed' for m in records)
            assert records[-1]['phase']=='runtime_freed'
            assert records[-1]['engine_allocator_live']==0 and records[-1]['native_live']==0,(name,records[-1])
            out['runs'].append({'case':name,'buffered':bool(buffered),'payload_bytes':size,'items':count,'visible_results':results,'preparation':prep,'elapsed_seconds':time.monotonic()-start,'returncode':r.returncode,'stderr':r.stderr,'measurements':records})
            path.unlink();out['runs'][-1]['parent_released_physical_footprint']=metrics.physical_footprint();print(name,buffered,r.returncode,flush=True)
        out['parent_maxrss_raw']=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(out,indent=2)+'\n')
        print(args.output)
