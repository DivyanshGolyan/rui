import re,sys
path,a,b,ind=sys.argv[1],int(sys.argv[2]),int(sys.argv[3]),int(sys.argv[4])
L=open(path).read().split('\n')
sp=' '*ind
st=[]
for i in range(a-1,b):
    l=L[i]
    if l.startswith(sp) and not l.startswith(sp+' ') and re.match(r'(pub |fn |const |var |test |inline )',l[ind:]):
        st.append(i)
st.append(b)
for x,y in zip(st,st[1:]):
    m=re.match(r'(pub\s+)?(inline\s+)?(fn|const|var|test)\s+("[^"]*"|[A-Za-z_0-9@"]+)',L[x][ind:])
    print("%6d %5d %s %s"%(x+1,y-x,m.group(3) if m else '?',m.group(4) if m else L[x][:50]))
