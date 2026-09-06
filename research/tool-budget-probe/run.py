#!/usr/bin/env python3
"""Reproduce the isolated native resource probe; no workload processes spawned."""
import json,pathlib,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='onepage-tool-budget-') as temp:
    binary=temp+'/probe'
    subprocess.run(['clang','-O2','-Wall','-Wextra','-Werror',str(root/'probe.c'),'-o',binary],check=True)
    runs=[]
    for i in range(3):
        p=subprocess.run([binary],capture_output=True,text=True,timeout=45)
        row=dict(repetition=i,exit_code=p.returncode,stderr=p.stderr,samples=[json.loads(x) for x in p.stdout.splitlines()])
        runs.append(row); print(json.dumps(row),flush=True)
    (root/'results.json').write_text(json.dumps(runs,indent=2)+'\n')
    if any(r['exit_code'] for r in runs):raise SystemExit('Resource probe did not fully pass; inspect retained results.')
