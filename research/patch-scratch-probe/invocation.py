#!/usr/bin/env python3
"""Closed Git invocation evidence, not production implementation."""
import difflib,json,pathlib,subprocess,tempfile,os
P=pathlib.Path
rows=[]
for git in ['/usr/bin/git','/opt/homebrew/bin/git']:
 for kind in ['ordinary','global_crlf','local_crlf','self_attributes','self_encoding','local_encoding','local_ident','parent_repository']:
  with tempfile.TemporaryDirectory(prefix='onepage-invocation-') as tmp:
   root=P(tmp);d=root/'scratch';d.mkdir();home=root/'home';(home/'.config/git').mkdir(parents=True)
   attrs=home/'.config/git/attributes';attrs.write_text('* text eol=crlf\n')
   config=home/'.gitconfig';config.write_text('[core]\n autocrlf = true\n[filter "expand"]\n smudge = false\n')
   if kind=='parent_repository': subprocess.run([git,'init','-q',str(root)],check=True);(root/'.gitattributes').write_text('* text eol=crlf\n')
   if kind=='local_crlf': (d/'.gitattributes').write_text('* text eol=crlf\n')
   if kind=='local_encoding': (d/'.gitattributes').write_text('* working-tree-encoding=UTF-16\n')
   if kind=='local_ident': (d/'.gitattributes').write_text('* ident\n')
   target='.gitattributes' if kind in ['self_attributes','self_encoding'] else 'target'
   old='* text eol=crlf\n' if kind=='self_attributes' else ('* working-tree-encoding=UTF-16\n' if kind=='self_encoding' else 'old $Id$\n')
   new=old+'new\n';(d/target).write_text(old)
   data=''.join(difflib.unified_diff(old.splitlines(True),new.splitlines(True),fromfile='a/'+target,tofile='b/'+target)).encode()
   env={'PATH':'/usr/bin:/bin','LC_ALL':'C','HOME':str(home),'GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null','GIT_ATTR_NOSYSTEM':'1','GIT_CEILING_DIRECTORIES':str(root)}
   argv=[git,'-c','core.attributesFile=/dev/null','-c','core.autocrlf=false','apply','--no-index','--whitespace=nowarn','-']
   r=subprocess.run(argv,cwd=d,env=env,input=data,capture_output=True)
   actual=(d/target).read_bytes()
   assert r.returncode==0 and actual==new.encode(),(git,kind,r.returncode,actual,r.stderr)
   rows.append({'git':git,'case':kind,'returncode':r.returncode,'exact_bytes':True,'files':sorted(x.name for x in d.iterdir())})
P(__file__).with_name('invocation-results.json').write_text(json.dumps(rows,indent=2)+'\n')
print(json.dumps(rows,indent=2))
