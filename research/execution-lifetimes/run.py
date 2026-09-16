#!/usr/bin/env python3
"""Serial native lifetime measurements. The lock also coordinates sibling tasks."""
import asyncio
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import shlex
import subprocess
import sys
import tempfile
import threading
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent

class Server:
    def __init__(self, count, size):
        self.count, self.size, self.arrived = count, size, 0
        self.ready = threading.Event()
        self.thread = threading.Thread(target=self.main)
        self.thread.start()
        self.ready.wait()

    def main(self):
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        self.gate = asyncio.Event()
        self.server = self.loop.run_until_complete(asyncio.start_server(self.handle, '127.0.0.1', 0, backlog=2048))
        self.port = self.server.sockets[0].getsockname()[1]
        self.ready.set()
        self.loop.run_forever()
        self.server.close()
        self.loop.run_until_complete(self.server.wait_closed())
        tasks = asyncio.all_tasks(self.loop)
        for task in tasks:
            task.cancel()
        self.loop.run_until_complete(asyncio.gather(*tasks, return_exceptions=True))
        self.loop.close()

    async def handle(self, reader, writer):
        try:
            headers = await reader.readuntil(b'\r\n\r\n')
            if b'Content-Length: 128' in headers:
                assert await reader.readexactly(128) == b'a\n' * 64
            self.arrived += 1
            if self.arrived == self.count:
                self.gate.set()
            await self.gate.wait()
            writer.write(f'HTTP/1.1 200 OK\r\nContent-Length: {self.size}\r\nConnection: close\r\n\r\n'.encode())
            await writer.drain()
            await asyncio.sleep(.5)
            block = b'a\n' * 8192
            for offset in range(0, self.size, len(block)):
                writer.write(block[:min(len(block), self.size-offset)])
                await writer.drain()
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            writer.close()
            try: await writer.wait_closed()
            except ConnectionError: pass

    def close(self):
        self.loop.call_soon_threadsafe(self.loop.stop)
        self.thread.join()

def command(*args):
    return subprocess.check_output(args, text=True).strip()

def main():
    smoke = '--smoke' in sys.argv
    output = HERE / ('smoke.json' if smoke else 'results.json')
    result = dict(revision=command('git','rev-parse','HEAD'), machine=platform.platform(),
                  python=sys.version, compiler=command('clang','--version'),
                  started=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                  sources={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in HERE.glob('*') if p.suffix in ('.py','.c','.zig')},
                  cases=[])
    with tempfile.TemporaryDirectory(prefix='rui-lifetime-build-') as tmp:
        exe = str(Path(tmp)/'probe')
        build = Path(os.environ.get('CURL_BUILD', '/tmp/rui-transport-memory-build')).resolve()
        curl = build/'curl-8.22.0'
        library = curl/'lib/.libs/libcurl.a'
        if not library.exists():
            raise SystemExit('Build the pinned experimental dependencies with prepare.py first, or set CURL_BUILD.')
        flags = shlex.split(command(str(curl/'curl-config'), '--static-libs'))[1:]
        compile_command = ['clang','-O2','-Wall','-Wextra','-I'+str(curl/'include'),str(HERE/'probe.c'),str(library),*flags,'-o',exe]
        result['compile_command'] = compile_command
        result['curl_archive_sha256'] = hashlib.sha256(library.read_bytes()).hexdigest()
        result['curl_config'] = command(str(curl/'curl-config'),'--configure')
        subprocess.run(compile_command,check=True)
        with open('/tmp/rui-memory-experiments.lock','a') as lock:
            print('Waiting for shared benchmark lock', flush=True)
            fcntl.flock(lock,fcntl.LOCK_EX)
            print('Acquired shared benchmark lock', flush=True)
            points = [(n,4096) for n in ([1] if smoke else [1,100,1000])]
            if not smoke:
                points += [(100,1024),(100,1048576)]
            for kind in ['model','bash','edit']:
                for n,size in points:
                    for variant in ['baseline','early']:
                        server=Server(n,size) if kind=='model' else None
                        try:
                            url=f'http://127.0.0.1:{server.port}/' if server else '-'
                            start=time.monotonic()
                            child=subprocess.Popen([exe,kind,variant,str(n),str(size),url],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
                            try:
                                stdout,stderr=child.communicate(timeout=120)
                            finally:
                                try: os.killpg(child.pid,signal.SIGKILL)
                                except ProcessLookupError: pass
                                child.wait()
                            proc=subprocess.CompletedProcess(child.args,child.returncode,stdout,stderr)
                            case=dict(kind=kind,variant=variant,count=n,payload_bytes=size,seconds=time.monotonic()-start,
                                      exit=proc.returncode,stderr=proc.stderr, samples=[json.loads(x) for x in proc.stdout.splitlines()])
                            result['cases'].append(case)
                            output.write_text(json.dumps(result,indent=2)+'\n')
                            print(kind,variant,n,size,proc.returncode,flush=True)
                            if proc.returncode:
                                raise RuntimeError(proc.stderr)
                        finally:
                            if server: server.close()
    print(output)

if __name__=='__main__':
    main()
