import re
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
