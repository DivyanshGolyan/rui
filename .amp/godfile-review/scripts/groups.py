import json,sys,re,collections,itertools,subprocess
# args: cochange.json  pinfile  groupspec(json list of [startline,endline,group])
co=json.load(open(sys.argv[1])); pin=sys.argv[2]; spec=json.load(open(sys.argv[3]))
sys.path.insert(0,'/tmp/scripts')
text=open(pin).read()
exec(open('/tmp/scripts/regions_fn.py').read())
regs=regions(text)
name2g={}
for a,b,name,kind in regs:
    g='other'
    for s,e,gr in spec:
        if s<=a<=e: g=gr;break
    name2g[name]=g
cnt=collections.Counter(); pair=collections.Counter(); solo=collections.Counter(); unk=collections.Counter()
for c in co:
    gs=set()
    for r in c['regions']:
        g=name2g.get(r)
        if g is None: unk[r]+=1; continue
        gs.add(g)
    gs.discard('tests-support')
    for g in gs: cnt[g]+=1
    if len(gs)==1: solo[next(iter(gs))]+=1
    for a,b in itertools.combinations(sorted(gs),2): pair[(a,b)]+=1
    c['groups']=sorted(gs)
print('commits',len(co))
print('group: touched / only-this-group')
for g,n in cnt.most_common(): print(f'  {g:14s} {n:4d} {solo[g]:4d}')
print('top pairs'); 
for (a,b),n in pair.most_common(25): print(f'  {a}+{b}: {n}')
print('unmapped (renamed/removed) names top:',unk.most_common(12))
json.dump(co,open(sys.argv[1].replace('.json','.g.json'),'w'))
