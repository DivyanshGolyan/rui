import re,sys
# top-level declaration inventory: start line, end line (line of matching top-level '}' or ';'), kind, name
def inv(path):
    L=open(path).read().split('\n')
    out=[];i=0;n=len(L)
    pat=re.compile(r'^(pub\s+)?(export\s+)?(inline\s+)?(fn|const|var|test)\s*("?[^ (:=]*"?[^(=]*)')
    starts=[]
    for idx,l in enumerate(L):
        if re.match(r'^(pub |export |inline |fn |const |var |test |comptime )',l):
            starts.append(idx)
    starts.append(n)
    for a,b in zip(starts,starts[1:]):
        # trim trailing blank/comment lines before b
        e=b
        while e>a+1 and (L[e-1].strip()=='' or L[e-1].lstrip().startswith('//')): e-=1
        m=pat.match(L[a])
        kind=m.group(4) if m else 'other'
        name=(m.group(5).strip() if m else L[a][:40])
        out.append((a+1,e,e-a,kind,name[:70]))
    return out
for p in sys.argv[1:]:
    for r in inv(p): print("%6d %6d %5d %-5s %s"%r)
