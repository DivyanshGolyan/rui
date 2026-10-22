import json,sys,re,collections
exec(open('/tmp/scripts/regions_fn.py').read())
path,spec=sys.argv[1],json.load(open(sys.argv[2]))
text=open(path).read(); L=text.split('\n')
regs=[r for r in regions(text) if r[3]!='test']
def grp(a):
    for s,e,g in spec:
        if s<=a<=e: return g
    return 'other'
defs={}
for a,b,name,kind in regs:
    short=name.split('.')[-1]
    if len(short)<4 or short in('init','deinit','open','close','read','run','slice','append'): continue
    defs.setdefault(short,set()).add(grp(a))
edges=collections.Counter(); ex=collections.defaultdict(set)
for a,b,name,kind in regs:
    g=grp(a)
    if g=='tests-support': continue
    body='\n'.join(L[a:b])
    for w in set(re.findall(r'\b[A-Za-z_][A-Za-z0-9_]*\b',body)):
        if w in defs and g not in defs[w]:
            for h in defs[w]:
                if h=='tests-support': continue
                edges[(g,h)]+=1; ex[(g,h)].add(w)
for (g,h),n in sorted(edges.items(),key=lambda x:-x[1]):
    print(f'{g:18s} -> {h:18s} {n:3d}  {",".join(sorted(ex[(g,h)])[:14])}')
