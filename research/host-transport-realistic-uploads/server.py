"""Throwaway local TLS fixture; every wave proves the full cohort connected."""
import argparse, asyncio, json, resource, signal, ssl, time

async def main(a):
    start = time.monotonic()
    stats = dict(accepted=0, completed=0, disconnected=0, cancelled=0, body_bytes=0, waves=[])
    cohorts = [dict(connected=asyncio.Event(), terminal=asyncio.Event(), arrived=0,
                    ready=0, completed=0, first=None) for _ in range(a.cycles)]
    delta = b'data: {"type":"response.output_text.delta","delta":"xxxx"}\n\n'
    terminal = (b'data: {"type":"response.output_item.done","item":{"type":"message",'
                b'"role":"assistant","content":[{"type":"output_text","text":"' + b't'*65536 + b'"}]}}\n\n'
                b'data: {"type":"response.completed","response":{"status":"completed"}}\n\n')
    async def handle(reader, writer):
        try:
            head = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 30)
            operation = int(head.split(b' ')[1].split(b'operation=')[1])
            held = a.control and operation % a.capacity == 0
            length = next(int(l.split(b':')[1]) for l in head.split(b'\r\n') if l.lower().startswith(b'content-length:'))
            assert length == a.request_bytes
            remaining = length
            while remaining:
                chunk = await asyncio.wait_for(reader.readexactly(min(remaining,65536)),30)
                remaining -= len(chunk)
            del chunk
            idx = stats['accepted'] // a.capacity
            c = cohorts[idx]
            stats['accepted'] += 1
            now = time.monotonic()
            if c['first'] is None: c['first'] = now
            c['arrived'] += 1
            if c['arrived'] == a.capacity:
                c['start'] = now + .1
                c['connected'].set()
            await asyncio.wait_for(c['connected'].wait(), 45)
            await asyncio.sleep(max(0, c['start']-time.monotonic()))
            writer.write(b'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n')
            for event in range(a.seconds*100):
                await asyncio.sleep(max(0, c['start']+event/100-time.monotonic()))
                writer.write(delta)
                await writer.drain()
                stats['body_bytes'] += len(delta)
            c['ready'] += 1
            if c['ready'] == a.capacity:
                c['terminal_at'] = time.monotonic()+.005
                c['terminal'].set()
            await asyncio.wait_for(c['terminal'].wait(), 45)
            await asyncio.sleep(max(0, c['terminal_at']-time.monotonic()))
            if held:
                assert await asyncio.wait_for(reader.read(), 60) == b''
                stats['cancelled'] += 1
            else:
                writer.write(terminal)
                await writer.drain()
                stats['body_bytes'] += len(terminal)
                stats['completed'] += 1
            c['completed'] += 1
            if c['completed'] == a.capacity:
                stats['waves'].append(dict(wave=idx+1, concurrent=c['arrived'],
                    setup_seconds=c['start']-.1-c['first'],
                    generation_seconds=c['terminal_at']-.005-c['start'],
                    terminal_write_seconds=time.monotonic()-c['terminal_at']))
        except Exception as e:
            stats['disconnected'] += 1
            print(json.dumps({'error':repr(e)}), flush=True)
        finally:
            writer.close()
            try: await writer.wait_closed()
            except Exception: pass
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(a.cert,a.key)
    server = await asyncio.start_server(handle,'127.0.0.1',0,ssl=ctx,backlog=2048)
    stop=asyncio.Event()
    for sig in (signal.SIGINT,signal.SIGTERM): asyncio.get_running_loop().add_signal_handler(sig,stop.set)
    print(json.dumps({'ready':True,'port':server.sockets[0].getsockname()[1]}),flush=True)
    async with server: await stop.wait()
    u=resource.getrusage(resource.RUSAGE_SELF)
    stats.update(wall_seconds=time.monotonic()-start,cpu_seconds=u.ru_utime+u.ru_stime,max_rss_bytes=u.ru_maxrss,
        expected_body_bytes=a.capacity*a.cycles*(a.seconds*100*len(delta)+len(terminal)) - (len(terminal) if a.control else 0))
    print(json.dumps(stats),flush=True)

p=argparse.ArgumentParser()
for name in ('cert','key'): p.add_argument('--'+name,required=True)
for name,default in [('capacity',100),('cycles',1),('seconds',4)]: p.add_argument('--'+name,type=int,default=default)
p.add_argument('--control',action='store_true')
p.add_argument('--request-bytes',type=int,default=4096)
asyncio.run(main(p.parse_args()))
