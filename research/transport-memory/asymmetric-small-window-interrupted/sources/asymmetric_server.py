"""Verified staged uploads with independently paced responses and overlap evidence."""
import asyncio,hashlib,json,ssl,sys,time
from h2.connection import H2Connection
from h2.config import H2Configuration
from h2.events import RequestReceived,DataReceived,StreamEnded,StreamReset,ConnectionTerminated
from h2.settings import SettingCodes
from asymmetric_format import request_size,request_hash
from paced_format import body,dimensions
n,proto,bursts,port=map(int,sys.argv[1:5]);cert,key=sys.argv[5:7]
tokens,events,hz,base,growth,mixed=map(int,sys.argv[7:13])
record,terminal=dimensions(tokens,events);payload=record*events+terminal
headers=[0]*bursts;arrivals=[0]*bursts;barriers=[asyncio.Event() for _ in range(bursts)]
connections=0;resumed=0;streams_max=0;inflight=0;max_inflight=0;request_bytes=0;response_bytes=0;seen=set();expected={}
clock=lambda:time.clock_gettime_ns(time.CLOCK_MONOTONIC)
def emit(**row):print(json.dumps(row),flush=True)
def opened(path,length):
 global inflight,max_inflight
 burst,identifier=map(int,path.strip('/').split('/'));assert 0<=burst<bursts and 0<=identifier<n
 assert (burst,identifier) not in seen;seen.add((burst,identifier))
 size=request_size(base,burst,identifier,growth,mixed);assert length==size
 if size not in expected:expected[size]=request_hash(size)
 headers[burst]+=1;inflight+=1;max_inflight=max(max_inflight,inflight)
 if headers[burst]==n:barriers[burst].set();emit(headers_admitted_burst=burst,count=n,monotonic_ns=clock())
 return burst,identifier,size
def received(burst,identifier,size,digest):
 assert digest==expected[size];arrivals[burst]+=1
 emit(request_complete=identifier,burst=burst,bytes=size,monotonic_ns=clock())
async def accept(reader,writer):
 global connections,resumed,streams_max,inflight,request_bytes,response_bytes
 connections+=1;obj=writer.get_extra_info('ssl_object');reused=obj.session_reused;resumed+=int(reused)
 emit(connection=connections,resumed=reused,tls_version=obj.version())
 try:
  if proto==1:
   while True:
    raw=await reader.readuntil(b'\r\n\r\n');lines=raw.split(b'\r\n');path=lines[0].split()[1].decode()
    length=int(next(x.split(b':',1)[1] for x in lines if x.lower().startswith(b'content-length:')))
    burst,identifier,size=opened(path,length);hasher=hashlib.sha256();left=size
    while left:
     data=await reader.read(min(left,16384));assert data;hasher.update(data);left-=len(data);request_bytes+=len(data)
    received(burst,identifier,size,hasher.digest());await barriers[burst].wait();await asyncio.sleep(.2)
    writer.write(b'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n');await writer.drain()
    start=clock();offset=0
    for index in range(1,events+1):
     await asyncio.sleep(max(0,(start+int(index/hz*1e9)-clock())/1e9))
     target=index*record+(terminal if index==events else 0)
     while offset<target:
      z=min(16384,target-offset);data=body(offset,z,tokens,events)
      if offset==0:emit(first_sse=identifier,burst=burst,monotonic_ns=clock())
      writer.write(f'{z:x}\r\n'.encode()+data+b'\r\n');await writer.drain();offset+=z;response_bytes+=z
    writer.write(b'0\r\n\r\n');await writer.drain();inflight-=1
    emit(response_complete=identifier,burst=burst,monotonic_ns=clock())
  else:
   h=H2Connection(H2Configuration(client_side=False));h.initiate_connection();h.update_settings({SettingCodes.MAX_CONCURRENT_STREAMS:1000})
   writer.write(h.data_to_send());await writer.drain();requests={};pending={}
   async def pump():
    global response_bytes,inflight
    while True:
     now=clock()
     for sid,state in list(pending.items()):
      burst,identifier,offset,start,headed=state
      if not barriers[burst].is_set():continue
      if not start:state[3]=now+200_000_000;continue
      if now<start:continue
      if not headed:
       h.send_headers(sid,[(':status','200'),('content-type','text/event-stream')]);state[4]=True
      count=min(events,int((now-start)/1e9*hz));target=count*record+(terminal if count==events else 0)
      z=min(target-offset,16384,h.local_flow_control_window(sid))
      if z>0:
       if offset==0:emit(first_sse=identifier,burst=burst,monotonic_ns=now)
       h.send_data(sid,body(offset,z,tokens,events),end_stream=offset+z==payload);response_bytes+=z
       if offset+z==payload:
        del pending[sid];inflight-=1;emit(response_complete=identifier,burst=burst,monotonic_ns=clock())
       else:state[2]+=z
     data=h.data_to_send()
     if data:writer.write(data);await writer.drain()
     await asyncio.sleep(.001)
   task=asyncio.create_task(pump())
   try:
    while data:=await reader.read(65536):
     for ev in h.receive_data(data):
      if isinstance(ev,RequestReceived):
       fields=dict(ev.headers);burst,identifier,size=opened(fields[b':path'].decode(),int(fields[b'content-length']))
       requests[ev.stream_id]=[burst,identifier,size,0,hashlib.sha256()];streams_max=max(streams_max,len(requests)+len(pending))
      elif isinstance(ev,DataReceived):
       state=requests[ev.stream_id];state[3]+=len(ev.data);state[4].update(ev.data);request_bytes+=len(ev.data)
       h.acknowledge_received_data(ev.flow_controlled_length,ev.stream_id)
      elif isinstance(ev,StreamEnded):
       burst,identifier,size,got,digest=requests.pop(ev.stream_id);assert got==size
       received(burst,identifier,size,digest.digest());pending[ev.stream_id]=[burst,identifier,0,0,False]
      elif isinstance(ev,StreamReset):raise AssertionError('unexpected stream reset')
      elif isinstance(ev,ConnectionTerminated):return
     writer.write(h.data_to_send());await writer.drain()
   finally:task.cancel();await asyncio.gather(task,return_exceptions=True)
 except (asyncio.IncompleteReadError,ConnectionResetError,BrokenPipeError):pass
 finally:writer.close()
async def main():
 ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(cert,key);ctx.set_alpn_protocols(['h2'] if proto==2 else ['http/1.1'])
 server=await asyncio.start_server(accept,'127.0.0.1',port,ssl=ctx,backlog=2048)
 emit(ready=True,ssl=ssl.OPENSSL_VERSION)
 async with server:await server.serve_forever()
try:asyncio.run(main())
except KeyboardInterrupt:pass
finally:emit(requests_per_burst=arrivals,headers_per_burst=headers,connections=connections,resumed_connections=resumed,full_handshakes=connections-resumed,streams_max=streams_max,max_inflight=max_inflight,request_bytes=request_bytes,response_bytes=response_bytes)
