"""Independent, periodic local control RTT client; no durable mutation is claimed."""
import json,os,pathlib,select,signal,socket,struct,sys,time
path,out=sys.argv[1:3]
stop=False

def finish(*_):
 global stop
 stop=True
signal.signal(signal.SIGINT,finish)
s=socket.socket(socket.AF_UNIX,socket.SOCK_DGRAM)
local=path+'.client';s.bind(local);s.setblocking(False)
s.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,262144)
seq=0;pending={};next_send=time.clock_gettime_ns(time.CLOCK_MONOTONIC);deadline=None;errors=0
with open(out,'w') as f:
 try:
  while not stop or pending:
   now=time.clock_gettime_ns(time.CLOCK_MONOTONIC)
   if stop and deadline is None:deadline=now+3_000_000_000
   if deadline and now>deadline:break
   if not stop and now>=next_send:
    seq+=1;payload=struct.pack('=QQ',seq,now)
    try:s.sendto(payload,path);pending[seq]=now
    except OSError as e:
     errors+=1;f.write(json.dumps({'send_error':repr(e),'seq':seq})+'\n')
    f.write(json.dumps({'sent':seq,'sent_ns':now,'schedule_lateness_ns':max(0,now-next_send)})+'\n')
    next_send+=20_000_000
   while True:
    try:data=s.recv(16)
    except BlockingIOError:break
    seqno,sent=struct.unpack('=QQ',data);assert pending.pop(seqno)==sent
    ack=time.clock_gettime_ns(time.CLOCK_MONOTONIC);f.write(json.dumps({'ack':seqno,'sent_ns':sent,'ack_ns':ack,'rtt_ns':ack-sent})+'\n')
   select.select([s],[],[],.001 if pending else .01)
 finally:
  f.write(json.dumps({'sent_total':seq,'send_errors':errors,'unacknowledged':len(pending)})+'\n');s.close();os.unlink(local)
if errors or pending:sys.exit(1)
