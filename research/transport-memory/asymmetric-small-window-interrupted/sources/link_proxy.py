"""Isolated TLS-byte relay: shared directional rate and per-chunk forwarding delay.

TCP endpoints acknowledge locally. This is not packet-level RTT/loss/congestion
emulation. Each direction shares a 256-chunk budget plus one pending read per connection
and asyncio buffers.
"""
import asyncio,json,sys,time
port,upstream,up_rate,down_rate,one_way_ms=map(int,sys.argv[1:])
forwarded=[0,0];received=[0,0];next_time=[0.,0.];connections=0;active=0;maximum=0
budgets=[asyncio.Semaphore(256),asyncio.Semaphore(256)]
async def forward(reader,writer,direction):
 queue=asyncio.Queue(maxsize=256)
 async def read():
  while data:=await reader.read(16384):
   received[direction]+=len(data)
   await budgets[direction].acquire()
   try:await queue.put((asyncio.get_running_loop().time()+one_way_ms/1000,data))
   except BaseException:budgets[direction].release();raise
  await queue.put(None)
 async def write():
  rate=[up_rate,down_rate][direction]
  while item:=await queue.get():
   try:
    deadline,data=item;now=asyncio.get_running_loop().time()
    when=max(deadline,next_time[direction]);next_time[direction]=when+len(data)/rate
    await asyncio.sleep(max(0,when-now));writer.write(data);await writer.drain();forwarded[direction]+=len(data)
   finally:budgets[direction].release()
  if writer.can_write_eof():writer.write_eof()
 tasks=[asyncio.create_task(read()),asyncio.create_task(write())]
 try:await asyncio.gather(*tasks)
 finally:
  for task in tasks:task.cancel()
  await asyncio.gather(*tasks,return_exceptions=True)
  while not queue.empty():
   if queue.get_nowait() is not None:budgets[direction].release()
async def accept(reader,writer):
 global connections,active,maximum
 connections+=1;active+=1;maximum=max(maximum,active);other=None
 try:
  remote,other=await asyncio.open_connection('127.0.0.1',upstream,limit=16384)
  await asyncio.gather(forward(reader,other,0),forward(remote,writer,1))
 except (ConnectionError,asyncio.IncompleteReadError):pass
 finally:
  active-=1;writer.close()
  if other:other.close()
async def main():
 server=await asyncio.start_server(accept,'127.0.0.1',port,limit=16384,backlog=2048)
 print(json.dumps({'ready':True,'up_B_s':up_rate,'down_B_s':down_rate,'one_way_delay_ms':one_way_ms,'global_queue_chunks_per_direction':256,'chunk_max':16384}),flush=True)
 async with server:await server.serve_forever()
try:asyncio.run(main())
except KeyboardInterrupt:pass
finally:print(json.dumps({'connections':connections,'maximum_connections':maximum,'received_up':received[0],'received_down':received[1],'forwarded_up':forwarded[0],'forwarded_down':forwarded[1]}),flush=True)
