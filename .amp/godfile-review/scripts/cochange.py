import re,sys,subprocess,collections,json
repo,path,rev=sys.argv[1],sys.argv[2],sys.argv[3]
def git(*a): return subprocess.run(['git','-C',repo]+list(a),capture_output=True,text=True).stdout
decl=re.compile(r'(pub\s+)?(export\s+)?(inline\s+)?(fn|const|var|test)\s+("[^"]*"|[A-Za-z_0-9@]+)')
def regions(text):
    L=text.split('\n'); out=[]
    def scan(a,b,ind,prefix):
        st=[]
        for i in range(a,b):
            l=L[i]
            if l.startswith(' '*ind) and not l.startswith(' '*(ind+1)) and decl.match(l[ind:]): st.append(i)
        st.append(b)
        for x,y in zip(st,st[1:]):
            m=decl.match(L[x][ind:]); name=prefix+m.group(5)
            kind=m.group(4)
            if ind==0 and y-x>300 and kind=='const': scan(x+1,y,4,name+'.')
            else: out.append((x+1,y,name,kind))
    scan(0,len(L),0,'')
    return out
shas=git('log','--format=%H',rev,'--',path).split()
res=[]
for s in shas:
    try: text=git('show',f'{s}:{path}')
    except: continue
    if not text: continue
    regs=regions(text)
    d=git('show','-U0','--format=','--no-renames',s,'--',path)
    touched=collections.Counter()
    for m in re.finditer(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@',d,re.M):
        st=int(m.group(1)); n=int(m.group(2)) if m.group(2) is not None else 1
        rng=range(st,st+max(n,1))
        for (a,b,name,kind) in regs:
            if kind=='test': continue
            if any(a<=x<=b for x in (rng.start,rng.stop-1)) or (rng.start<=a and rng.stop-1>=b):
                touched[name]+=1
    subj=git('log','-1','--format=%s',s).strip()
    res.append({'sha':s[:8],'subj':subj,'regions':sorted(touched)})
json.dump(res,open(sys.argv[4],'w'))
print(len(res))
