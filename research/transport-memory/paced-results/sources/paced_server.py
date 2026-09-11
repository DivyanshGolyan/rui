"""Paced SSE with an all-request barrier and encrypted-output byte accounting."""
import asyncio,json,ssl,sys,time,hashlib
from h2.connection import H2Connection
from h2.config import H2Configuration
from h2.events import DataReceived,StreamEnded,ConnectionTerminated,StreamReset
from h2.settings import SettingCodes
from paced_format import body,dimensions
n,tokens,events,hz,port=map(int,sys.argv[1:6]);cert,key=sys.argv[6:8]
record_len,terminal_len=dimensions(tokens,events);payload=record_len*events+terminal_len
arrivals=0;connections=0;resumed=0;streams_max=0;wire_bytes=0;sent_body=0;offered=0
ready=asyncio.Event();offer_done=asyncio.Event();clock=lambda:time.clock_gettime_ns(time.CLOCK_MONOTONIC)

def emit(**values):print(json.dumps(values),flush=True)

async def offer():
 global offered
 await ready.wait();began=clock();emit(offer_start_ns=began,record_bytes=record_len,terminal_bytes=terminal_len,tokens_per_event=tokens,events=events,hz=hz)
 for i in range(1,events+1):
  deadline=began+int(i/hz*1e9)
  await asyncio.sleep(max(0,(deadline-clock())/1e9))
  offered=i*record_len
  if i==events:offered+=terminal_len
  now=clock();emit(offered_events=i,monotonic_ns=now,deadline_ns=deadline,lateness_ns=max(0,now-deadline),offered_body_bytes=offered*n,offered_content_bytes=i*tokens*4*n)
 offer_done.set()

async def accept(reader,writer):
 global connections,resumed,arrivals,streams_max,wire_bytes,sent_body
 connections+=1;obj=writer.get_extra_info('ssl_object');reused=obj.session_reused;resumed+=int(reused)
 emit(connection=connections,resumed=reused,tls_version=obj.version())
 # Pinned asyncio instrumentation: counts ciphertext handed to TCP after handshake,
 # including H2 framing/TLS records; not IP/TCP headers or actual retransmissions.
 transport=writer.transport._ssl_protocol._transport
 underlying_write=transport.write
 def counted_write(data):
  global wire_bytes
  wire_bytes+=len(data);return underlying_write(data)
 transport.write=counted_write
 h=H2Connection(H2Configuration(client_side=False));h.initiate_connection();h.update_settings({SettingCodes.MAX_CONCURRENT_STREAMS:1000})
 writer.write(h.data_to_send());await writer.drain();hashes={};sizes={};pending={};headed=set()
 async def pump():
  global sent_body
  while True:
   if ready.is_set():
    for sid,off in list(pending.items()):
     if sid not in headed:
      h.send_headers(sid,[(':status','200'),('content-type','text/event-stream')]);headed.add(sid)
     z=min(offered-off,16384,h.local_flow_control_window(sid))
     if z>0:
      h.send_data(sid,body(off,z,tokens,events),end_stream=off+z==payload);sent_body+=z
      if off+z==payload:del pending[sid]
      else:pending[sid]=off+z
    data=h.data_to_send()
    if data:writer.write(data);await writer.drain()
   await asyncio.sleep(.001)
 task=asyncio.create_task(pump())
 try:
  while data:=await reader.read(65536):
   for ev in h.receive_data(data):
    if isinstance(ev,DataReceived):
     hashes.setdefault(ev.stream_id,hashlib.sha256()).update(ev.data);sizes[ev.stream_id]=sizes.get(ev.stream_id,0)+len(ev.data)
     h.acknowledge_received_data(ev.flow_controlled_length,ev.stream_id)
    elif isinstance(ev,StreamEnded):
     sid=ev.stream_id;assert sizes.pop(sid)==1024 and hashes.pop(sid).digest()==hashlib.sha256(b'a'*1024).digest()
     arrivals+=1;pending[sid]=0;streams_max=max(streams_max,len(pending))
     if arrivals==n:ready.set();emit(admitted=arrivals)
    elif isinstance(ev,StreamReset):pending.pop(ev.stream_id,None)
    elif isinstance(ev,ConnectionTerminated):return
   writer.write(h.data_to_send());await writer.drain()
 finally:
  task.cancel();await asyncio.gather(task,return_exceptions=True);writer.close()

async def main():
 ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(cert,key);ctx.set_alpn_protocols(['h2'])
 server=await asyncio.start_server(accept,'127.0.0.1',port,ssl=ctx,backlog=2048)
 emit(ready=True,ssl=ssl.OPENSSL_VERSION)
 task=asyncio.create_task(offer())
 try:
  async with server:await server.serve_forever()
 finally:task.cancel();await asyncio.gather(task,return_exceptions=True)
try:asyncio.run(main())
except KeyboardInterrupt:pass
finally:emit(requests_per_burst=[arrivals],connections=connections,resumed_connections=resumed,full_handshakes=connections-resumed,streams_max=streams_max,sent_body_bytes=sent_body,tls_ciphertext_to_tcp_bytes=wire_bytes,expected_body_bytes=payload*n)
