#!/usr/bin/env python3
import fcntl
import json
from pathlib import Path
import subprocess
import tempfile

HERE=Path(__file__).resolve().parent
ROOT=HERE.parent.parent
with tempfile.TemporaryDirectory(prefix='rui-lifetime-check-') as tmp:
    exe=str(Path(tmp)/'faults')
    prod=str(Path(tmp)/'production-bash')
    capture=str(Path(tmp)/'production-capture')
    subprocess.run(['clang','-g','-O1','-fsanitize=address,undefined','-Wall','-Wextra',str(HERE/'failures.c'),'-o',exe],check=True)
    subprocess.run(['zig','build-exe','-O','ReleaseSafe','-lc','--dep','bash','--dep','metrics',
                    '-Mroot='+str(HERE/'production_bash.zig'),'-Mbash='+str(ROOT/'src/bash_tool.zig'),
                    '-Mmetrics='+str(ROOT/'src/process_metrics.zig'),'-femit-bin='+prod],check=True)
    subprocess.run(['zig','build-exe','-O','ReleaseSafe','-lc','--dep','provider','--dep','metrics',
                    '-Mroot='+str(HERE/'production_capture.zig'),'-Mprovider='+str(ROOT/'src/codex_provider.zig'),
                    '-Mmetrics='+str(ROOT/'src/process_metrics.zig'),'-femit-bin='+capture],check=True)
    with open('/tmp/rui-memory-experiments.lock','a') as lock:
        print('Waiting for shared benchmark lock',flush=True)
        fcntl.flock(lock,fcntl.LOCK_EX)
        good=subprocess.run([exe],capture_output=True,text=True,timeout=15)
        bad=subprocess.run([exe,'broken-release'],capture_output=True,text=True,timeout=15)
        production=subprocess.run([prod],capture_output=True,text=True,timeout=30)
        assert good.returncode==0,good.stderr
        assert bad.returncode!=0 and 'heap-use-after-free' in bad.stderr,bad.stderr
        assert production.returncode==0,production.stderr
        result=dict(positive=json.loads(good.stdout),negative_exit=bad.returncode,
                    negative_diagnostic=bad.stderr,production_bash=json.loads(production.stderr),
                    production_capture=[json.loads(subprocess.run([capture,str(n)],capture_output=True,text=True,check=True,timeout=30).stderr) for n in (1,100)],
                    zig=subprocess.check_output(['zig','version'],text=True).strip())
        (HERE/'checks.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps({k:v for k,v in result.items() if k!='negative_diagnostic'},indent=2))
