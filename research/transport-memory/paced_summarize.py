#!/usr/bin/env python3
"""Validate exact raw evidence, then derive per-burst latency/throughput tables."""
import argparse,csv,hashlib,json,math,pathlib
from paced_format import dimensions
p=argparse.ArgumentParser();p.add_argument('--groups',type=pathlib.Path,nargs='+',required=True);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--expected-failures',nargs='*',default=[]);a=p.parse_args();rows=[]
def q(values,percent):
 values=sorted(values);assert values
 return values[max(0,math.ceil(percent*len(values))-1)]
for group in a.groups:
 meta=json.loads((group/'metadata.json').read_text())
 for source,digest in meta['sources_sha256'].items():assert hashlib.sha256((group/'sources'/source).read_bytes()).hexdigest()==digest
 seen=set()
 for text in (group/'summary.jsonl').read_text().splitlines():
  rec=json.loads(text);case=rec['case'];name,n,protocol,bursts,payload,strategy,delay,stall,slots,cache,fail,*extra=case
  assert name not in seen;seen.add(name)
  if name in a.expected_failures:
   raw=[json.loads(x) for x in (group/(name+'.jsonl')).read_text().splitlines()]
   server=[json.loads(x) for x in (group/(name+'-server.jsonl')).read_text().splitlines()]
   assert rec['returncode']!=0 and raw==rec['measurements'] and not raw[-1].get('success')
   assert server[-1]['requests_per_burst'][0]<n and server[-1]['streams_max']<=extra[5]
   print(json.dumps({'failed_capacity_probe':name,'returncode':rec['returncode'],'server':server[-1]}))
   continue
  assert rec['returncode']==rec['control_returncode']==0
  for suffix in ['.stderr','-server.stderr']:assert not (group/(name+suffix)).read_text(), 'unexpected diagnostic output'
  raw=[json.loads(x) for x in (group/(name+'.jsonl')).read_text().splitlines()];assert raw==rec['measurements'] and raw[-1]['success']
  control=[json.loads(x) for x in (group/(name+'-controls.jsonl')).read_text().splitlines()];assert control[-1]['send_errors']==control[-1]['unacknowledged']==0
  sends={r['sent']:r for r in control if 'sent'in r};acks={r['ack']:r for r in control if 'ack'in r};assert len(sends)==len(acks)==control[-1]['sent_total']
  for seq,r in acks.items():assert r['sent_ns']==sends[seq]['sent_ns'] and r['rtt_ns']==r['ack_ns']-r['sent_ns']>=0
  server=[json.loads(x) for x in (group/(name+'-server.jsonl')).read_text().splitlines()];assert server[-1]['requests_per_burst']==[n]*bursts
  conn=[r for r in server if 'connection'in r];assert len(conn)==server[-1]['connections']
  if protocol==2:assert server[-1]['streams_max']<=min(extra[4],extra[5])
  assert all(r['tls_version']=='TLSv1.3' for r in conn)
  events={};samples={};cpus={};active={};burst_summaries={};verified={};last=None
  for r in raw:
   if 'event'in r:
    last=(r['burst'],r['event']);events[last]=r
   elif 'phase'in r:
    assert last and last[1]==r['phase'];samples[last]=r;active.setdefault(last[0],[]).append(r)
   elif 'cpu_event'in r:cpus[(r['burst'],r['cpu_event'])]=r['cpu_seconds']
   elif 'burst_summary'in r:burst_summaries[r['burst_summary']]=r
   elif 'verified_burst'in r:verified[r['verified_burst']]=r
  if extra and stall:
   stall_events=[r for r in raw if r.get('stall_started')]
   assert len(stall_events)==bursts and all(r['min_written']>=extra[0] and r['active_transfers']==n for r in stall_events)
  clean=samples[(bursts,'retained_idle')];assert clean['curl_live']==clean['tls_live']==clean['app_bytes']==clean['scratch_bytes']==0 and clean['fds']==3
  offset=0
  for burst in range(bursts):
   start=events[(burst,'transfer_start')];finish=events[(burst,'capture_complete')];b=burst_summaries[burst]
   expected=(n-int(bool(fail)))*payload;assert verified[burst]['verified_bytes']==expected and verified[burst]['capture_failures']==int(bool(fail))
   if not fail:assert b['capture_bytes']==expected and b['transport_errors']==0
   assert finish['queue_bytes']==finish['queue_chunks']==0 and finish['written']==b['capture_bytes']
   tokens,event_count,hz=extra[7:10];record_bytes,terminal_bytes=dimensions(tokens,event_count)
   offers=[r for r in server if 'offered_events' in r];assert len(offers)==event_count
   assert [r['offered_events'] for r in offers]==list(range(1,event_count+1))
   assert all(r['offered_body_bytes']==n*(r['offered_events']*record_bytes+(terminal_bytes if r['offered_events']==event_count else 0)) for r in offers)
   assert server[-1]['sent_body_bytes']==server[-1]['expected_body_bytes']==expected
   assert server[-1]['tls_ciphertext_to_tcp_bytes']>expected
   completed=[r for r in raw if 'capture_finished' in r]
   assert len(completed)==n and {r['capture_finished'] for r in completed}==set(range(n))
   terminal_lag=[(r['monotonic_ns']-offers[-1]['monotonic_ns'])/1e6 for r in completed]
   assert min(terminal_lag)>=0
   gaps=[];body_backlogs=[];offset_offer=0
   progress=[r for r in raw if 'capture_progress' in r and start['monotonic_ns']<=r['monotonic_ns']<offers[-1]['monotonic_ns']]
   for r in progress:
    while offset_offer<len(offers) and offers[offset_offer]['monotonic_ns']<=r['monotonic_ns']:offset_offer+=1
    offered_events=offset_offer
    gaps.append(max(0,offered_events-min(event_count,r['min_written']//record_bytes)))
   assert gaps

   assert finish['queue_peak_bytes']<=slots*16384
   loaded=[r for r in acks.values() if start['monotonic_ns']<=r['sent_ns']<=finish['monotonic_ns']]
   assert len(loaded)>=3,'missing or mismatched clock domain'
   latency=[r['rtt_ns']/1e6 for r in loaded]
   new=b['connections_created'];connections=conn[offset:offset+new];assert len(connections)==new;offset+=new
   reused_sessions=sum(r['resumed'] for r in connections)
   idle=samples[(burst,'serviced_idle')];elapsed=(finish['monotonic_ns']-start['monotonic_ns'])/1e9
   cpu=cpus[(burst,'capture_complete')]-cpus[(burst,'transfer_start')]
   rows.append({'group':str(group),'case':name,'synthetic_tokens_s':tokens*hz,'tokens_per_event':tokens,'events_s':hz,'delta_event_bytes':record_bytes,'content_B_s_per_stream':tokens*hz*4,'sse_B_s_per_stream':record_bytes*hz,'terminal_body_bytes_per_stream':terminal_bytes,'tls_ciphertext_bytes':server[-1]['tls_ciphertext_to_tcp_bytes'],'terminal_capture_p95_ms':q(terminal_lag,.95),'terminal_capture_max_ms':max(terminal_lag),'streaming_gap_p95_events':q(gaps,.95),'streaming_gap_max_events':max(gaps),'fixture_schedule_max_late_ms':max(r['lateness_ns'] for r in offers)/1e6,'payload':payload,'warm':extra[0],'rate':extra[1],'receive_buffer':extra[2],'host_cap':extra[3],'local_stream_cap':extra[4],'server_stream_cap':extra[5],'known_length':extra[6] if len(extra)>6 else 1,'burst':burst,'n':n,'protocol':protocol,'strategy':strategy,'delay_us':delay,'stall_ms':stall,'slots':slots,'cache':cache,'capture_seconds':elapsed,'verified_bytes':expected,'verified_MiB_s':expected/1048576/elapsed,'control_samples':len(latency),'control_p95_ms':q(latency,.95),'control_max_ms':max(latency),'generator_lateness_max_ms':max(sends[r['ack']]['schedule_lateness_ns']/1e6 for r in loaded),'callback_max_ms':finish['callback_max_s']*1000,'perform_max_ms':finish['perform_max_s']*1000,'unpause_max_ms':finish['unpause_max_s']*1000,'write_max_ms':finish['write_max_s']*1000,'queue_peak_bytes':finish['queue_peak_bytes'],'curl_live_sample_max':max(r['curl_live'] for r in active[burst]),'tls_live_sample_max':max(r['tls_live'] for r in active[burst]),'curl_peak':max(r['curl_peak'] for r in active[burst]),'tls_peak':max(r['tls_peak'] for r in active[burst]),'process_physical_highwater':max(r['max_physical'] for r in active[burst]),'idle_physical':idle['physical'],'idle_curl_live':idle['curl_live'],'idle_tls_live':idle['tls_live'],'idle_fds':idle['fds'],'new_connections':new,'resumed_new_connections':reused_sessions,'full_handshakes':new-reused_sessions,'new_connection_setup_mean_ms':b['new_connection_appconnect_us_sum']/max(1,new)/1000,'handshake_phase_mean_ms':b['handshake_phase_us_sum']/max(1,new)/1000,'cpu_seconds':cpu,'mean_cpu_cores':cpu/elapsed})
  assert offset==len(conn)
with open(a.output,'w') as f:
 writer=csv.DictWriter(f,fieldnames=list(rows[0]),lineterminator='\n');writer.writeheader();writer.writerows(rows)
print(json.dumps({'cases':sum(1 for r in rows if r['burst']==0),'bursts':len(rows),'verified_bytes':sum(r['verified_bytes'] for r in rows)},indent=2))
for r in rows:print(f"{r['case']} burst {r['burst']}: p95 {r['control_p95_ms']:.2f} ms, max {r['control_max_ms']:.2f} ms, {r['verified_MiB_s']:.2f} MiB/s, new/full/resumed {r['new_connections']}/{r['full_handshakes']}/{r['resumed_new_connections']}")
