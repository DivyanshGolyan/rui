import json,pathlib,re,subprocess,tempfile
P=pathlib.Path
rows=[]
with tempfile.TemporaryDirectory(prefix='onepage-edit-baseline-') as t:
 d=P(t);(d/'source').write_bytes(b'x\n'*500000+b'end\n');(d/'old').write_bytes(b'end\n');(d/'new').write_bytes(b'changed\n')
 for i in range(5):
  for kind in (['baseline','edit'] if i%2==0 else ['edit','baseline']):
   args=['/tmp/onepage-exact-edit-baseline'] if kind=='baseline' else ['/tmp/onepage-exact-edit-probe-bin',str(d/'source'),str(d/'old'),str(d/'new'),str(d/'out')]
   r=subprocess.run(['/usr/bin/time','-l']+args,capture_output=True,check=True)
   rows.append({'repetition':i,'kind':kind,'memory':{k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+(maximum resident set size|peak memory footprint)\s*$',r.stderr.decode(),re.M)},'context_bytes':re.findall(r'sha256_context_bytes=(\d+)',r.stderr.decode())})
   if kind=='edit':(d/'out').unlink()
P(__file__).with_name('baseline-results.json').write_text(json.dumps(rows,indent=2)+'\n')
print(json.dumps(rows,indent=2))
