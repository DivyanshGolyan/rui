import sys,re
from datetime import datetime
def t(s): h,m,x=s.split(':'); return int(h)*3600+int(m)*60+float(x)
def dur(l):
    m=re.search(r'<(\d+\.\d+)>$',l); return float(m.group(1))*1000 if m else None
for a in sys.argv[1:]:
    L=open(a).read().splitlines()
    ci=[i for i,l in enumerate(L) if ' clone(' in l and 'CLONE_THREAD' not in l and 'SIGCHLD' in l][0]
    host,ct=L[ci].split()[0],t(L[ci].split()[1]); child=re.search(r'= (\d+) <',L[ci]).group(1)
    cret=ct+dur(L[ci])/1000
    fi=[i for i in range(ci+1,len(L)) if L[i].startswith(child+' ')][0]
    between=sorted({l.split()[0] for l in L[ci+1:fi]})
    ei=[i for i in range(fi,len(L)) if L[i].startswith(child+' ') and 'execve(' in L[i]][0]
    et=t(L[ei].split()[1])
    if 'unfinished' in L[ei]:
        ri=[i for i in range(ei,len(L)) if L[i].startswith(child+' ') and 'execve resumed' in L[i]][0]; ed=dur(L[ri]); eret=t(L[ri].split()[1])
    else: ed=dur(L[ei]); eret=et+ed/1000
    rd=[l for l in L[ci:ei+40] if l.startswith(host+' ') and 'read resumed' in l]
    pre=[l for l in L[ci:ci+400] if l.startswith(host+' ')][:0]
    # pre-spawn Store/scratch fsyncs/journal/wal by host thread in 300 lines before clone
    sy=[l[:170] for l in L[max(0,ci-700):ci] if re.search(r'fsync|fdatasync|unlink\(|-journal",|ftruncate',l) and l.startswith(host+' ')]
    print(f"== {a}: host tid {host}, child {child}, lines between clone and child first syscall {fi-ci-1} tids {between}")
    print(f" clone dur {dur(L[ci]):.3f} ms; clone ret -> child first syscall {(t(L[fi].split()[1])-cret)*1000:.3f} ms ({L[fi].split()[2][:30]})")
    print(f" child first syscall -> execve entry {(et-t(L[fi].split()[1]))*1000:.3f} ms; execve dur {ed:.3f} ms ({'unfinished/resumed' if 'unfinished' in L[ei] else 'complete'})")
    print(f" clone entry -> execve entry {(et-ct)*1000:.3f} ms; -> execve return {(eret-ct)*1000:.3f} ms")
    print(" parent read:", rd[0][:140] if rd else None)
    print(" execve:", L[ei][:200])
    for s in sy[-12:]: print("  pre:", s, f"[{(ct-t(s.split()[1]))*1000:.3f} ms before clone]")
