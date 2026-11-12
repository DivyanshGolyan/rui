#!/usr/bin/env python3
"""Run the existing production Store density fixture without changing its source."""
import datetime,fcntl,hashlib,json,os,pathlib,platform,signal,subprocess,time
here=pathlib.Path(__file__).resolve().parent
with open('/tmp/rui-memory-experiments.lock','a') as lock:
    print('Waiting for production fixture lock',flush=True)
    fcntl.flock(lock,fcntl.LOCK_EX)
    print('Running production Store density fixture',flush=True)
    start=time.monotonic()
    child=subprocess.Popen(['zig','build','host-store-density'],cwd=here.parents[1],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
    try:
        stdout,stderr=child.communicate(timeout=600)
    except BaseException:
        os.killpg(child.pid,signal.SIGTERM)
        try: child.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid,signal.SIGKILL)
            child.communicate()
        raise
    p=subprocess.CompletedProcess(child.args,child.returncode,stdout,stderr)
    (here/'production-results.json').write_text(json.dumps({'command':'zig build host-store-density','revision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=here.parents[1],text=True).strip(),'machine':platform.platform(),'recorded_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'source_sha256':{name:hashlib.sha256((here.parents[1]/name).read_bytes()).hexdigest() for name in ['src/host_store_density.zig','src/host_store.zig','src/session.zig','build.zig','build.zig.zon']},'exit':p.returncode,'seconds':time.monotonic()-start,'stdout':p.stdout,'stderr':p.stderr},indent=2)+'\n')
    print(p.returncode,p.stdout,p.stderr,flush=True)
    p.check_returncode()
