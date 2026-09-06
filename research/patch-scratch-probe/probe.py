#!/usr/bin/env python3
"""Throwaway real-Git reservation and inherited scratch-lock experiment."""
import difflib, fcntl, json, os, pathlib, re, resource, shutil, signal, subprocess, sys, tempfile, time
P=pathlib.Path
ENV={'PATH':'/usr/bin:/bin','LC_ALL':'C','GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null'}
ARGS=['apply','--no-index','--whitespace=nowarn','-']

def locked(fd):
    try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError: return True
    fcntl.flock(fd,fcntl.LOCK_UN)
    return False

def host(root,git):
    fd=os.open(root+'/scratch.lock',os.O_RDWR|os.O_CREAT,0o600)
    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    child=subprocess.Popen([git]+ARGS,cwd=root+'/job',env=ENV,stdin=0,
       stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,pass_fds=(fd,))
    print(json.dumps({'child':child.pid}),flush=True)
    while True: signal.pause()

if len(sys.argv)>1 and sys.argv[1]=='host':
    host(sys.argv[2],sys.argv[3]);sys.exit()

def patch(old,new):
    return ''.join(difflib.unified_diff(old.splitlines(True),new.splitlines(True),fromfile='a/target',tofile='b/target')).encode()

def run_case(root,git,name,old,new,limit_override=None, hold_old=False):
    d=root/name;d.mkdir(); target=d/'target';target.write_bytes(old.encode())
    data=patch(old,new);s=len(old.encode()); m=s+len(data); reservation=s+m if hold_old else m
    # Compare existing retained handle with closing after hash/metadata capture.
    before=os.open(target,os.O_RDONLY)
    initial=os.fstat(before)
    if not hold_old: os.close(before)
    def limit():
        n=m if limit_override is None else limit_override
        resource.setrlimit(resource.RLIMIT_FSIZE,(n,n))
        resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    proc=subprocess.Popen(['/usr/bin/time','-l',git]+ARGS,cwd=d,env=ENV,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,preexec_fn=limit)
    out,err=proc.communicate(data,timeout=10)
    oldstat=os.fstat(before) if hold_old else initial
    actual=(oldstat.st_size if hold_old else 0)+sum(x.stat().st_size for x in d.iterdir() if x.is_file() and (not hold_old or x.stat().st_ino!=oldstat.st_ino))
    files=[x.name for x in d.iterdir()]
    assert actual<=reservation,(name,actual,reservation)
    if limit_override is None:
        assert proc.returncode==0,(name,err)
        assert target.read_bytes()==new.encode(),name
        assert files==['target'],files
    else: assert proc.returncode!=0,(name,proc.returncode)
    if hold_old: os.close(before)
    shutil.rmtree(d)
    return {'case':name,'source':s,'patch':len(data),'output_bound':m,'reservation':reservation,'observed_after_git_including_open_old_inode':actual,'held_old_handle':hold_old,'old_inode_unlinked':oldstat.st_nlink==0 if hold_old else None,'returncode':proc.returncode,'memory':{label:int(value) for value,label in re.findall(r'^\s*(\d+)\s+(maximum resident set size|peak memory footprint)\s*$',err.decode(),re.M)},'files_after_git':files,'cleanup':not d.exists()}

def crash_case(root,git,kill_helper=False):
    d=root/('crash-kill' if kill_helper else 'crash-complete');d.mkdir();(d/'job').mkdir();(d/'job/target').write_text('old\n')
    hostproc=subprocess.Popen([sys.executable,__file__,'host',str(d),git],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=False)
    child=json.loads(hostproc.stdout.readline())['child']
    other=os.open(d/'scratch.lock',os.O_RDWR)
    try:
        # Wait until actual Git has exec'd and is reading stdin, not merely pre-exec child.
        for _ in range(200):
            cmd=subprocess.run(['/bin/ps','-p',str(child),'-o','comm='],capture_output=True,text=True).stdout.strip()
            if 'git' in cmd: break
            time.sleep(.01)
        else: raise AssertionError('Git exec not observed')
        assert locked(other),'live host lock absent'
        hostproc.kill();hostproc.wait(timeout=5)
        time.sleep(.05)
        assert locked(other),'surviving Git did not retain inherited lock'
        if kill_helper: os.kill(child,signal.SIGKILL)
        else: hostproc.stdin.write(patch('old\n','new\n'));hostproc.stdin.flush()
        hostproc.stdin.close()
        for _ in range(500):
            if not locked(other): break
            time.sleep(.01)
        else: raise AssertionError('lock not released after helper finished')
        value=(d/'job/target').read_text()
        assert value==('old\n' if kill_helper else 'new\n'),value
        # Restart acquires ownership before deleting stale job. Keep permanent lock inode.
        fcntl.flock(other,fcntl.LOCK_EX|fcntl.LOCK_NB)
        shutil.rmtree(d/'job');assert not (d/'job').exists()
        return {'helper': 'killed' if kill_helper else 'completed_after_host_death','git_exec_observed':True,'restart_blocked_while_helper_alive':True,'restart_cleanup_after_lock':True,'target_before_cleanup':value}
    finally:
        if hostproc.poll() is None: hostproc.kill();hostproc.wait()
        try: os.kill(child,signal.SIGKILL)
        except ProcessLookupError: pass
        os.close(other)

def failed_cleanup(root):
    d=root/'cleanup-failure';d.mkdir();(d/'still-owned').write_bytes(b'x')
    used=100;occupied=1
    try: os.rmdir(d) # Real ENOTEMPTY: emulate interrupted/failed tree removal.
    except OSError as e: error=e.errno
    else: raise AssertionError('expected cleanup failure')
    assert used==100 and occupied==1 and d.exists()
    shutil.rmtree(d);used=0;occupied=0
    return {'injected_rmdir_errno':error,'reservation_and_slot_retained_on_failure':True,'released_after_success':used==occupied==0,'limitation':'policy harness, not integrated Host cleanup'}

results={'purpose':'reservation arithmetic, real Git inode overlap, inherited scratch lock and crash cleanup; not whole-Host memory certification','platform':sys.platform,'runs':[]}
for git in ['/usr/bin/git','/opt/homebrew/bin/git']:
    with tempfile.TemporaryDirectory(prefix='onepage-patch-probe-') as tmp:
        root=P(tmp)
        cases=[('replace','old\n','new\n'),('grow','context\n','context\n'+'addition\n'*1000),('shrink','start\n'+'remove\n'*1000+'end\n','start\nend\n'),('one_mib_large_line_patch','a'*1048575+'\n','a'*1048575+'\n'+'added\n'),('many_lines','x\n'*500000+'end\n','x\n'*500000+'changed\n')]
        rows=[run_case(root,git,*c) for c in cases]
        rows.append(run_case(root,git,'retained_old_handle_control','x\n'*500000+'end\n','x\n'*500000+'changed\n',hold_old=True))
        rows.append(run_case(root,git,'kernel_limit','old\n','old\n'+'added\n'*1000,limit_override=32))
        results['runs'].append({'git':git,'version':subprocess.check_output([git,'--version'],text=True).strip(),'cases':rows,'crash':[crash_case(root,git),crash_case(root,git,True)],'cleanup':failed_cleanup(root)})
results['accounting_shape']={'per_active_patch_reservation_u64_bytes':8,'for_1000':8000,'shared_limit_and_used_u64_bytes':16,'scratch_lock_files_per_host':1,'extra_inherited_lock_descriptors_per_git_helper':1,'note':'field counts, not measured process footprint; existing custody/FD state/alignment and Git heap are additional'}
P(__file__).with_name('results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
