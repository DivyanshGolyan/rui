import hashlib,json,pathlib,subprocess,tempfile,re
P=pathlib.Path
exe='/tmp/onepage-exact-edit-probe-bin';results=[]
with tempfile.TemporaryDirectory(prefix='onepage-exact-fixture-') as tmp:
 d=P(tmp)
 cases=[('small',b'old\n',b'old',b'new'),('boundary',b'x'*16382+b'NEEDLE'+b'end',b'NEEDLE',b'replaced'),('overlapping',b'ababa',b'aba',b'X'),('missing',b'abc',b'def',b'X'),('empty',b'abc',b'',b'X'),('crlf',b'one\r\ntwo\r\n',b'two',b'three'),('utf8','hi café!'.encode(),'café'.encode(),'你好'.encode()),('deletion',b'abc def',b'abc ',b''),('many_lines',b'x\n'*500000+b'end\n',b'end\n',b'changed\n'),('large',None,b'UNIQUE_MARKER',b'new'),('large_replacement',b'prefix OLD suffix',b'OLD',b'Y'*4194304),('large_needle',b'a'*1000000+b'b',b'a'*1000000+b'b',b'new')]
 for name,data,old,new in cases:
  src=d/'input';needle=d/'old';rep=d/'new';out=d/'output'
  if data is None:
   with src.open('wb') as f:
    for _ in range(128):f.write(b'x'*1048576)
    f.write(old)
  else:src.write_bytes(data)
  needle.write_bytes(old);rep.write_bytes(new)
  r=subprocess.run(['/usr/bin/time','-l',exe,str(src),str(needle),str(rep),str(out)],capture_output=True)
  status=json.loads(r.stdout) if r.stdout else {'result':'empty_needle_rejected'}
  expected=4 if name=='overlapping' else (5 if name=='missing' else (3 if name=='empty' else 0))
  assert r.returncode==expected,(name,r.returncode,r.stderr)
  if expected==0:
   def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
     while b:=f.read(65536):h.update(b)
    return h.hexdigest()
   assert status['preimage']==digest(src) and status['postimage']==digest(out)
   if data is not None:assert out.read_bytes()==data.replace(old,new,1)
   else:
    assert out.stat().st_size==128*1048576+3
    with out.open('rb') as f:f.seek(-3,2);assert f.read()==b'new'
   out.unlink()
  else:assert not out.exists()
  memory={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+(maximum resident set size|peak memory footprint)\s*$',r.stderr.decode(),re.M)}
  results.append({'case':name,'source_bytes':src.stat().st_size,'old_bytes':len(old),'new_bytes':len(new),'returncode':r.returncode,'status':status,'memory':memory})
P(__file__).with_name('results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
