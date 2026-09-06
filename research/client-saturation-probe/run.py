#!/usr/bin/env python3
"""Throwaway probe: native server measured separately from Python load generator."""
import json, pathlib, resource, socket, statistics, subprocess, tempfile, time
ROOT=pathlib.Path(__file__).resolve().parent
soft,hard=resource.getrlimit(resource.RLIMIT_NOFILE)
resource.setrlimit(resource.RLIMIT_NOFILE,(min(hard,max(soft,4096)),hard))
results=[]
with tempfile.TemporaryDirectory(prefix='op-client-probe-') as tmp:
    binary=tmp+'/probe'; obj=tmp+'/parser.o'
    subprocess.run(['zig','build-obj',str(ROOT/'parser.zig'),'-O','ReleaseFast','-femit-bin='+obj],check=True)
    subprocess.run(['clang','-O2','-Wall','-Wextra','-mmacosx-version-min=15.7.7',str(ROOT/'probe.c'),obj,'-o',binary],check=True)
    class Probe:
        def __init__(self,ordinary=100,reserve=1,header=10,stall=60):
            self.path=tmp+'/s';self.sockets=[]
            self.p=subprocess.Popen([binary,self.path,str(ordinary+reserve),str(ordinary),str(header),str(stall)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,bufsize=1)
            assert self.p.stdout.readline().strip()=='ready'
            self.sample()
        def sample(self):
            self.p.stdin.write('s');self.p.stdin.flush();return json.loads(self.p.stdout.readline())
        def connect(self):
            s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.settimeout(5);s.connect(self.path);self.sockets.append(s);return s
        def wait(self,field,count):
            until=time.monotonic()+5
            while True:
                x=self.sample()
                if x[field]==count:return x
                assert time.monotonic()<until,(field,count,x)
                time.sleep(.005)
        def request(self,header):
            start=time.monotonic();s=self.connect();s.sendall(header);data=b''
            while True:
                chunk=s.recv(8192)
                if not chunk:break
                data+=chunk
            s.close();return data,(time.monotonic()-start)*1000
        def hold(self,mode,n):
            for idx in range(n):
                s=self.connect()
                if mode=='headers':s.sendall(b'GET /large HTTP/1.1\r\nX: ')
                elif mode=='upload':s.sendall(b'POST /upload HTTP/1.1\r\nHost: local\r\nContent-Length: 1048576\r\n\r\n'+b'x'*4096)
                else:s.sendall(b'GET /large HTTP/1.1\r\nHost: local\r\n\r\n')
                self.wait('active',idx+1)
            self.wait({'headers':'headers','upload':'uploads','download':'downloads'}[mode],n)
        def close(self):
            for s in self.sockets:s.close()
            self.p.stdin.write('q');self.p.stdin.flush();self.p.wait(timeout=5);assert self.p.returncode==0
            self.p.stdin.close();self.p.stdout.close()
    stop=b'POST /stop HTTP/1.1\r\nHost: local\r\nContent-Length: 0\r\n\r\n'
    ordinary=b'GET /status HTTP/1.1\r\nHost: local\r\n\r\n'
    # Rotate resource cases. Header-held connections are temporary, not keep-alive.
    for rep in range(3):
        cases=[(m,n) for m in ['headers','upload','download'] for n in [16,100,256]]
        cases=cases[rep:]+cases[:rep]
        for mode,n in cases:
            p=Probe(n)
            try:
                baseline=p.sample();p.hold(mode,n);time.sleep(.05)
                samples=[p.sample() for _ in range(8)]
                latencies=[]
                if mode!='headers':
                    for _ in range(20):
                        data,ms=p.request(stop);assert data.endswith(b'\r\n\r\nxx') and b'200 OK' in data;latencies.append(ms)
                    data,_=p.request(ordinary);assert b'503 Service Unavailable' in data
                held=p.sample()
                for s in p.sockets:s.close()
                p.wait('active',0);after=p.sample()
                assert after['scratch_files']==0 and after['ordinary']==0
                row=dict(case=mode,n=n,repetition=rep,baseline=baseline,held=held,after=after,median_physical=statistics.median(s['physical'] for s in samples),stop_ms=latencies)
                results.append(row);print(json.dumps(dict(case=mode,n=n,rep=rep,physical=row['median_physical'],stop_median_ms=statistics.median(latencies) if latencies else None)),flush=True)
            finally:p.close()
    # Negative control: no headroom means fresh stop connection is rejected.
    p=Probe(16,0)
    try:
        p.hold('upload',16)
        try:data,_=p.request(stop)
        except (BrokenPipeError,ConnectionResetError):data=b''
        assert b'200 OK' not in data
        results.append(dict(case='no_headroom',stop_rejected=True,state=p.sample()))
    finally:p.close()
    # Compressed test deadlines exercise state transitions, not selected durations.
    p=Probe(16,1,header=.3,stall=.5)
    try:
        p.hold('upload',16);h=p.connect();h.sendall(b'POST /stop HTTP/1.1\r\nX: ');p.wait('headers',1)
        started=time.monotonic()
        while time.monotonic()-started<.4:
            try:h.sendall(b'x')
            except (BrokenPipeError,ConnectionResetError):break
            time.sleep(.05)
        assert p.sample()['headers']==0
        data,ms=p.request(stop);assert b'200 OK' in data
        p.wait('active',0);end=p.sample();assert end['scratch_files']==0 and end['expired']>=17
        results.append(dict(case='header_trickle_and_upload_stall',state=end,stop_ms=ms))
    finally:p.close()
    p=Probe(16,1,stall=.3)
    try:
        p.hold('download',16);p.wait('active',0);end=p.sample();assert end['scratch_files']==0 and end['expired']==16
        results.append(dict(case='download_stall',state=end))
    finally:p.close()
    # Slow progress survives a stall deadline over a longer total transfer.
    p=Probe(16,1,stall=.3)
    try:
        s=p.connect();s.sendall(b'POST /upload HTTP/1.1\r\nHost: local\r\nContent-Length: 10\r\n\r\n')
        for _ in range(10):s.sendall(b'x');time.sleep(.1)
        data=b''
        while True:
            chunk=s.recv(8192)
            if not chunk:break
            data+=chunk
        assert b'200 OK' in data and p.sample()['expired']==0
        results.append(dict(case='slow_progress',state=p.sample()))
    finally:p.close()
(ROOT/'results.json').write_text(json.dumps(results,indent=2)+'\n')
print('All measured cases and explicit admission/deadline checks passed.')
