"""One local plain-HTTP transfer at a selected socket descriptor; no high load."""
from pathlib import Path
import datetime, hashlib, http.server, json, platform, subprocess, tempfile, threading
P=Path(__file__).resolve().parent
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header('Content-Length','2');self.end_headers();self.wfile.write(b'OK')
    def log_message(self,*args): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
thread=threading.Thread(target=server.serve_forever);thread.start()
rows=[]
try:
    with tempfile.TemporaryDirectory(prefix='onepage-single-fd-') as tmp:
        binary=str(Path(tmp)/'probe')
        subprocess.run(['clang','-O2','-std=c11','-Wall','-Wextra','-Werror',str(P/'probe.c'),'-lcurl','-o',binary],check=True)
        for minimum in (0,1023,1024,1100):
            for mode in ('easy','socket'):
                r=subprocess.run([binary,f'http://127.0.0.1:{server.server_port}/',str(minimum),mode],capture_output=True,text=True,timeout=15,check=True)
                rows.append(dict(minimum=minimum,mode=mode,stdout=r.stdout,stderr=r.stderr))
                print(r.stdout,end='')
finally:
    server.shutdown();server.server_close();thread.join()
(P/'results.json').write_text(json.dumps(dict(date=datetime.datetime.now().astimezone().isoformat(),platform=platform.platform(),source_hashes={f:hashlib.sha256((P/f).read_bytes()).hexdigest() for f in ('probe.c','run.py')},runs=rows),indent=2)+'\n')
