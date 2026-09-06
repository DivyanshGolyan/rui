#!/usr/bin/env python3
import json,pathlib,statistics,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parent
results=[]
with tempfile.TemporaryDirectory(prefix='onepage-scratch-account-') as tmp:
    binary=tmp+'/probe'
    subprocess.run(['clang','-O2','-Wall','-Wextra','-Werror',str(root/'probe.c'),'-o',binary],check=True)
    def run(args):
        p=subprocess.run([binary,*args],capture_output=True,text=True,timeout=30)
        assert p.returncode==0,(args,p.returncode,p.stdout,p.stderr)
        return json.loads(p.stdout)
    results.append(run([]));results.append(run(['race']))
    # Each case writes 128 MiB into real unlinked scratch files, then closes them.
    # Reverse accounting order each repetition, and rotate writer populations.
    for rep in range(5):
        counts=[1,2,8];counts=counts[rep%3:]+counts[:rep%3]
        for n in counts:
            for accounting in ([0,1] if rep%2==0 else [1,0]):
                r=run([str(n),str(accounting)]);r['repetition']=rep;results.append(r)
    (root/'results.json').write_text(json.dumps(results,indent=2)+'\n')
for n in [1,2,8]:
    for accounting in [0,1]:
        rs=[r for r in results if r.get('writers')==n and r['case']=='throughput' and r['accounting']==accounting]
        print(json.dumps(dict(writers=n,accounting=accounting,median_wall=statistics.median(r['wall_seconds'] for r in rs),median_cpu=statistics.median(r['cpu_seconds'] for r in rs),peak_physical=max(r['physical_lifetime_peak'] for r in rs))))
print('Correctness, concurrent cap, and 30 comparative I/O cases passed.')
