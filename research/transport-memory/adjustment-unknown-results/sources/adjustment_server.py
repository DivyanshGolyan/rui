"""Repeated-burst server with an all-requests barrier and verified complete input."""
import asyncio,functools,hashlib,json,ssl,sys
from h2.connection import H2Connection
from h2.config import H2Configuration
from h2.events import DataReceived,StreamEnded,ConnectionTerminated,StreamReset
from h2.settings import SettingCodes
n,size,bursts,proto,port=map(int,sys.argv[1:6]);cert,key=sys.argv[6:8]
warm=int(sys.argv[8]) if len(sys.argv)>8 else 0
warms=[0]*bursts;warm_barriers=[asyncio.Event() for _ in range(bursts)]
expected=hashlib.sha256(b'a'*1024).digest()
arrivals=[0]*bursts;barriers=[asyncio.Event() for _ in range(bursts)]
connections=0;resumed=0;streams_max=0
server_streams=int(sys.argv[9])
known=int(sys.argv[10]) if len(sys.argv)>10 else 1
@functools.lru_cache(maxsize=16)
def body(off,length):
 out=bytearray()
 while length:
  index,pos=divmod(off,256)
  record=(f'event: response.completed\ndata: {{"sequence":"{index:05d}","status":"completed"}}' if index==size//256-1 else f'event: response.output_text.delta\ndata: {{"sequence":"{index:05d}","delta":"fixture"}}').encode().ljust(254,b' ')+b'\n\n' 
  take=min(length,256-pos);out.extend(record[pos:pos+take]);off+=take;length-=take
 return bytes(out)

def complete(burst):
 arrivals[burst]+=1
 if arrivals[burst]%100==0 or arrivals[burst]==n:print(json.dumps({'admitted_burst':burst,'count':arrivals[burst],'expected':n}),flush=True)
 if arrivals[burst]==n:barriers[burst].set()
async def accept(reader,writer):
 global connections,resumed,streams_max
 connections+=1;cid=connections
 reused=writer.get_extra_info('ssl_object').session_reused
 resumed+=int(reused)
 print(json.dumps({'connection':cid,'resumed':reused,'tls_version':writer.get_extra_info('ssl_object').version()}),flush=True)
 try:
  if proto==1:
   while True:
    heads=await reader.readuntil(b'\r\n\r\n')
    fields=heads.split(b'\r\n');burst=int(fields[0].split()[1].strip(b'/'))
    length=int(next(x.split(b':',1)[1] for x in fields if x.lower().startswith(b'content-length:')))
    assert length==1024 and hashlib.sha256(await reader.readexactly(length)).digest()==expected
    complete(burst);await barriers[burst].wait();await asyncio.sleep(.1)
    writer.write(f'HTTP/1.1 200 OK\r\nContent-Length: {size}\r\nConnection: keep-alive\r\n\r\n'.encode())
    for off in range(0,size,16384):
     if warm and off==warm:
      warms[burst]+=1
      if warms[burst]==n:warm_barriers[burst].set()
      await warm_barriers[burst].wait();await asyncio.sleep(1)
     writer.write(body(off,min(size-off,16384)));await writer.drain()
  else:
   h=H2Connection(H2Configuration(client_side=False));h.initiate_connection();h.update_settings({SettingCodes.MAX_CONCURRENT_STREAMS:server_streams})
   writer.write(h.data_to_send());await writer.drain()
   hashes={};sizes={};paths={};pending={};ended={};stream_bursts={}
   from h2.events import RequestReceived
   async def pump():
    warmed=set();warm_seen=set();release=None
    while True:
     for sid,(burst,ready) in list(ended.items()):
      if barriers[burst].is_set() and asyncio.get_running_loop().time()>=ready:
       h.send_headers(sid,[(':status','200'),('content-type','text/event-stream')]+([('content-length',str(size))] if known else []));pending[sid]=size;del ended[sid]
     for sid,left in list(pending.items()):
      burst=stream_bursts[sid]
      if warm and left<=size-warm:
       warmed.add(sid)
       if sid not in warm_seen:
        warm_seen.add(sid);warms[burst]+=1
        if warms[burst]==n:warm_barriers[burst].set()
       if warm_barriers[burst].is_set() and release is None:release=asyncio.get_running_loop().time()+1
       if release is None or asyncio.get_running_loop().time()<release:continue
      z=min(left,16384,h.local_flow_control_window(sid))
      if z:
       h.send_data(sid,body(size-left,z),end_stream=z==left)
       if z==left:del pending[sid]
       else:pending[sid]-=z
     data=h.data_to_send()
     if data:writer.write(data);await writer.drain()
     await asyncio.sleep(.0001)
   task=asyncio.create_task(pump())
   try:
    while data:=await reader.read(65536):
     for ev in h.receive_data(data):
      if isinstance(ev,RequestReceived):paths[ev.stream_id]=int(dict(ev.headers)[b':path'].strip(b'/'))
      elif isinstance(ev,DataReceived):
       hashes.setdefault(ev.stream_id,hashlib.sha256()).update(ev.data);sizes[ev.stream_id]=sizes.get(ev.stream_id,0)+len(ev.data)
       h.acknowledge_received_data(ev.flow_controlled_length,ev.stream_id)
      elif isinstance(ev,StreamEnded):
       sid=ev.stream_id;assert sizes.pop(sid)==1024 and hashes.pop(sid).digest()==expected
       burst=paths.pop(sid);stream_bursts[sid]=burst;complete(burst);ended[sid]=(burst,asyncio.get_running_loop().time()+.1)
       streams_max=max(streams_max,len(ended)+len(pending))
      elif isinstance(ev,StreamReset):pending.pop(ev.stream_id,None);ended.pop(ev.stream_id,None)
      elif isinstance(ev,ConnectionTerminated):return
     writer.write(h.data_to_send());await writer.drain()
   finally:task.cancel();await asyncio.gather(task,return_exceptions=True)
 except (ConnectionResetError,BrokenPipeError,asyncio.IncompleteReadError):pass
 finally:writer.close()
async def main():
 ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(cert,key);ctx.set_alpn_protocols(['h2'] if proto==2 else ['http/1.1'])
 server=await asyncio.start_server(accept,'127.0.0.1',port,ssl=ctx,backlog=2048)
 print(json.dumps({'ready':True,'ssl':ssl.OPENSSL_VERSION}),flush=True)
 async with server:await server.serve_forever()
try:asyncio.run(main())
except KeyboardInterrupt:pass
finally:print(json.dumps({'requests_per_burst':arrivals,'connections':connections,'resumed_connections':resumed,'full_handshakes':connections-resumed,'streams_max':streams_max}),flush=True)
