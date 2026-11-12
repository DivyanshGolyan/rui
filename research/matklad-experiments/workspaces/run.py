#!/usr/bin/env python3
import json, pathlib, platform, random, statistics, subprocess, sys, datetime
root=pathlib.Path(__file__).resolve().parent
sanitize='--sanitize' in sys.argv
flags=['-O1','-g','-fsanitize=address,undefined','-fno-omit-frame-pointer'] if sanitize else ['-O2']
binary=root/('probe_san' if sanitize else 'probe')
subprocess.run(['clang',*flags,'-Wall','-Wextra','-Werror',str(root/'probe.c'),'-o',str(binary)],check=True)
smoke='--smoke' in sys.argv or sanitize
rows=[]
rng=random.Random(20260905)
for repetition in range(1 if smoke else 7):
    cases=[(m,n) for n in ([1048576] if smoke else [1048576,8388608,33554432]) for m in ['separate_eager','separate_lazy','shared']]
    rng.shuffle(cases)
    for mode,n in cases:
        row=json.loads(subprocess.check_output([str(binary),mode,str(n),'3' if smoke else '24']))
        row.update(repetition=repetition,sequence=len(rows))
        rows.append(row)
report={'recorded_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'platform':platform.platform(),'seed':20260905,'smoke':smoke,'sanitizers':sanitize,'rows':rows}
(root/('sanitized-smoke.json' if sanitize else 'smoke.json' if smoke else 'results.json')).write_text(json.dumps(report,indent=2)+'\n')
for n in sorted({r['stage_bytes'] for r in rows}):
    for mode in ['separate_eager','separate_lazy','shared']:
        rs=[r for r in rows if r['stage_bytes']==n and r['mode']==mode]
        print(n,mode,'footprint_delta',int(statistics.median(r['after_footprint']-r['base_footprint'] for r in rs)),'elapsed_ms',round(statistics.median(r['elapsed_ns']/1e6 for r in rs),3))
