"""Bounded local TLS fixture; reads complete staged requests before the response barrier."""
import asyncio, hashlib, json, ssl, sys
from h2.connection import H2Connection
from h2.config import H2Configuration
from h2.events import DataReceived, StreamEnded, ConnectionTerminated, StreamReset
from h2.settings import SettingCodes
n, reqbytes, outbytes, items, protocol, port = map(int, sys.argv[1:7])
cert,key=sys.argv[7:9]
arrived=0
barrier=asyncio.Event()
connections=0
max_streams=0
stride=reqbytes//items
expected=hashlib.sha256()
for off in range(0,reqbytes,16384):
    expected.update(bytes(10 if (j+1)%stride==0 and (j+1)//stride<=items else 97 for j in range(off,min(off+16384,reqbytes))))
expected=expected.digest()
async def accept(reader,writer):
    global arrived,connections,max_streams
    connections+=1
    try:
        if protocol==1:
            heads=await reader.readuntil(b'\r\n\r\n')
            length=int(next(x.split(b':',1)[1] for x in heads.split(b'\r\n') if x.lower().startswith(b'content-length:')))
            assert length==reqbytes
            sha=hashlib.sha256()
            while length:
                b=await reader.readexactly(min(length,16384));sha.update(b);length-=len(b)
            assert sha.digest()==expected
            arrived+=1
            if arrived==n:barrier.set()
            await barrier.wait();await asyncio.sleep(.3)
            writer.write(f'HTTP/1.1 200 OK\r\nContent-Length: {outbytes}\r\nConnection: keep-alive\r\n\r\n'.encode())
            for off in range(0,outbytes,16384):
                writer.write(b'x'*min(16384,outbytes-off));await writer.drain()
            # Keep the server side alive through cache-retention snapshots.
            await reader.read()
        else:
            h=H2Connection(H2Configuration(client_side=False));h.initiate_connection();h.update_settings({SettingCodes.MAX_CONCURRENT_STREAMS:1000})
            writer.write(h.data_to_send());await writer.drain()
            hashes={};sizes={};pending={};ended=set()
            async def pump():
                await barrier.wait();await asyncio.sleep(.3)
                while True:
                    for sid in list(ended):
                        h.send_headers(sid,[(':status','200'),('content-length',str(outbytes))]);pending[sid]=outbytes;ended.remove(sid)
                    for sid,left in list(pending.items()):
                        z=min(left,16384,h.local_flow_control_window(sid))
                        if z:
                            h.send_data(sid,b'x'*z,end_stream=z==left)
                            if z==left:del pending[sid]
                            else:pending[sid]-=z
                    data=h.data_to_send()
                    if data:writer.write(data);await writer.drain()
                    await asyncio.sleep(.0001)
            task=asyncio.create_task(pump())
            try:
                while data:=await reader.read(65536):
                    for ev in h.receive_data(data):
                        if isinstance(ev,DataReceived):
                            hashes.setdefault(ev.stream_id,hashlib.sha256()).update(ev.data)
                            sizes[ev.stream_id]=sizes.get(ev.stream_id,0)+len(ev.data)
                            h.acknowledge_received_data(ev.flow_controlled_length,ev.stream_id)
                        elif isinstance(ev,StreamEnded):
                            sid=ev.stream_id
                            assert sizes.pop(sid)==reqbytes and hashes.pop(sid).digest()==expected
                            ended.add(sid);arrived+=1;max_streams=max(max_streams,len(ended)+len(pending))
                            if arrived==n:barrier.set()
                        elif isinstance(ev,StreamReset):
                            pending.pop(ev.stream_id,None);ended.discard(ev.stream_id)
                        elif isinstance(ev,ConnectionTerminated):return
                    writer.write(h.data_to_send());await writer.drain()
            finally:
                task.cancel()
                await asyncio.gather(task,return_exceptions=True)
    except (ConnectionResetError,BrokenPipeError):pass
    except Exception as e:
        print(json.dumps({'error':repr(e)}),flush=True);raise
    finally:
        writer.close()
async def main():
    ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(cert,key);ctx.set_alpn_protocols(['h2'] if protocol==2 else ['http/1.1'])
    server=await asyncio.start_server(accept,'127.0.0.1',port,ssl=ctx,backlog=2048)
    print(json.dumps({'ready':True,'python_ssl':ssl.OPENSSL_VERSION}),flush=True)
    async with server:await server.serve_forever()
try:asyncio.run(main())
except KeyboardInterrupt:pass
finally:print(json.dumps({'requests_integrity_checked':arrived,'connections':connections,'max_streams':max_streams}),flush=True)
