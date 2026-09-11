#!/usr/bin/env python3
"""Validate exact raw evidence, then derive per-burst latency/throughput tables."""
import argparse,csv,hashlib,json,math,pathlib
from asymmetric_format import request_size
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
  for suffix in ['.stderr','-server.stderr','-proxy.stderr']:assert not (group/(name+suffix)).read_text(), 'unexpected diagnostic output'
  raw=[json.loads(x) for x in (group/(name+'.jsonl')).read_text().splitlines()];assert raw==rec['measurements'] and raw[-1]['success']
  control=[json.loads(x) for x in (group/(name+'-controls.jsonl')).read_text().splitlines()];assert control[-1]['send_errors']==control[-1]['unacknowledged']==0
  sends={r['sent']:r for r in control if 'sent'in r};acks={r['ack']:r for r in control if 'ack'in r};assert len(sends)==len(acks)==control[-1]['sent_total']
  for seq,r in acks.items():assert r['sent_ns']==sends[seq]['sent_ns'] and r['rtt_ns']==r['ack_ns']-r['sent_ns']>=0
  server=[json.loads(x) for x in (group/(name+'-server.jsonl')).read_text().splitlines()];assert server[-1]['requests_per_burst']==[n]*bursts
  assert server[-1]['headers_per_burst']==[n]*bursts and server[-1]['max_inflight']==n
  proxy=[json.loads(x) for x in (group/(name+'-proxy.jsonl')).read_text().splitlines()]
  assert proxy[-1]['forwarded_up']>=server[-1]['request_bytes'] and proxy[-1]['forwarded_down']>=server[-1]['response_bytes']
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
  if extra[0] and stall:
   stall_events=[r for r in raw if r.get('stall_started')]
   assert len(stall_events)==bursts and all(r['min_written']>=extra[0] and r['active_transfers']==n for r in stall_events)
  clean=samples[(bursts,'retained_idle')];assert clean['curl_live']==clean['tls_live']==clean['app_bytes']==clean['scratch_bytes']==0 and clean['fds']==3
  offset=0
  for burst in range(bursts):
   start=events[(burst,'transfer_start')];finish=events[(burst,'capture_complete')];b=burst_summaries[burst]
   expected=(n-int(bool(fail)))*payload;assert verified[burst]['verified_bytes']==expected and verified[burst]['capture_failures']==int(bool(fail))
   if not fail:assert b['capture_bytes']==expected and b['transport_errors']==0
   assert finish['queue_bytes']==finish['queue_chunks']==0 and finish['written']==b['capture_bytes']
   upload_buffer,request_base,growth,mixed,link_up,link_down,link_delay=extra[10:17]
   inputs={i:request_size(request_base,burst,i,growth,mixed) for i in range(n)}
   io=next(r for r in raw if r.get('disk_io_burst')==burst)
   assert io['staging_written']==io['staging_verified_read']==io['upload_read']==sum(inputs.values())
   assert io['capture_written']==expected
   timings={r['request_timing']:r for r in raw if 'request_timing' in r and r['burst']==burst}
   received={r['request_complete']:r for r in server if 'request_complete' in r and r['burst']==burst}
   first_sse={r['first_sse']:r for r in server if 'first_sse' in r and r['burst']==burst}
   server_done={r['response_complete']:r for r in server if 'response_complete' in r and r['burst']==burst}
   captures={r['capture_finished']:r for r in raw if 'capture_finished' in r and start['monotonic_ns']<=r['monotonic_ns']<=finish['monotonic_ns']}
   assert set(timings)==set(received)==set(first_sse)==set(server_done)==set(captures)==set(inputs)
   for i in inputs:
    assert timings[i]['upload_bytes']==received[i]['bytes']==inputs[i]
    assert timings[i]['posttransfer_us']>0 and timings[i]['starttransfer_us']>=timings[i]['posttransfer_us']
    assert timings[i]['first_read_ns']<=timings[i]['last_read_ns']<=timings[i]['first_body_ns']
   last_request=max(r['monotonic_ns'] for r in received.values())
   upload_seconds=(last_request-start['monotonic_ns'])/1e9
   overlap_ms=max(0,(last_request-min(r['monotonic_ns'] for r in first_sse.values()))/1e6)
   if mixed:assert overlap_ms>0
   stage_start=events[(burst,'burst_start')]
   staging_controls=[r['rtt_ns']/1e6 for r in acks.values() if stage_start['monotonic_ns']<=r['sent_ns']<start['monotonic_ns']]
   disk_before=next((r for r in raw if r.get('disk_physical_sample')=='burst_start' and r['burst']==burst),None)
   disk_after=next((r for r in raw if r.get('disk_physical_sample')=='capture_complete' and r['burst']==burst),None)

   assert finish['queue_peak_bytes']<=slots*16384
   loaded=[r for r in acks.values() if start['monotonic_ns']<=r['sent_ns']<=finish['monotonic_ns']]
   assert len(loaded)>=3,'missing or mismatched clock domain'
   latency=[r['rtt_ns']/1e6 for r in loaded]
   new=b['connections_created'];connections=conn[offset:offset+new];assert len(connections)==new;offset+=new
   reused_sessions=sum(r['resumed'] for r in connections)
   idle=samples[(burst,'serviced_idle')];elapsed=(finish['monotonic_ns']-start['monotonic_ns'])/1e9
   cpu=cpus[(burst,'capture_complete')]-cpus[(burst,'transfer_start')]
   rows.append({'group':str(group),'case':name,'upload_buffer':upload_buffer,'request_base':request_base,'growth':growth,'mixed':mixed,'link_up_B_s':link_up,'link_down_B_s':link_down,'one_way_delay_ms':link_delay,'request_bytes':sum(inputs.values()),'request_to_response_ratio':sum(inputs.values())/expected,'upload_peer_complete_seconds':upload_seconds,'upload_MiB_s':sum(inputs.values())/1048576/upload_seconds,'curl_posttransfer_p95_ms':q([r['posttransfer_us']/1000 for r in timings.values()],.95),'server_request_complete_p95_ms':q([(r['monotonic_ns']-start['monotonic_ns'])/1e6 for r in received.values()],.95),'first_SSE_p95_ms':q([(r['first_body_ns']-start['monotonic_ns'])/1e6 for r in timings.values()],.95),'after_request_first_SSE_p95_ms':q([(timings[i]['first_body_ns']-received[i]['monotonic_ns'])/1e6 for i in inputs],.95),'last_SSE_capture_p95_ms':q([(captures[i]['monotonic_ns']-server_done[i]['monotonic_ns'])/1e6 for i in inputs],.95),'overlap_upload_response_ms':overlap_ms,'staging_seconds':(start['monotonic_ns']-stage_start['monotonic_ns'])/1e9,'staging_control_p95_ms':q(staging_controls,.95) if staging_controls else None,'staging_control_max_ms':max(staging_controls) if staging_controls else None,'logical_file_written':sum(inputs.values())+expected,'logical_file_read':2*sum(inputs.values())+expected,'os_disk_read':disk_after['read']-disk_before['read'] if disk_after else None,'os_disk_written':disk_after['written']-disk_before['written'] if disk_after else None,'proxy_forwarded_up_case':proxy[-1]['forwarded_up'],'proxy_forwarded_down_case':proxy[-1]['forwarded_down'],'payload':payload,'warm':extra[0],'rate':extra[1],'receive_buffer':extra[2],'host_cap':extra[3],'local_stream_cap':extra[4],'server_stream_cap':extra[5],'known_length':extra[6] if len(extra)>6 else 1,'burst':burst,'n':n,'protocol':protocol,'strategy':strategy,'delay_us':delay,'stall_ms':stall,'slots':slots,'cache':cache,'capture_seconds':elapsed,'verified_bytes':expected,'verified_MiB_s':expected/1048576/elapsed,'control_samples':len(latency),'control_p95_ms':q(latency,.95),'control_max_ms':max(latency),'generator_lateness_max_ms':max(sends[r['ack']]['schedule_lateness_ns']/1e6 for r in loaded),'callback_max_ms':finish['callback_max_s']*1000,'perform_max_ms':finish['perform_max_s']*1000,'unpause_max_ms':finish['unpause_max_s']*1000,'write_max_ms':finish['write_max_s']*1000,'queue_peak_bytes':finish['queue_peak_bytes'],'curl_live_sample_max':max(r['curl_live'] for r in active[burst]),'tls_live_sample_max':max(r['tls_live'] for r in active[burst]),'curl_peak':max(r['curl_peak'] for r in active[burst]),'tls_peak':max(r['tls_peak'] for r in active[burst]),'process_physical_highwater':max(r['max_physical'] for r in active[burst]),'idle_physical':idle['physical'],'idle_curl_live':idle['curl_live'],'idle_tls_live':idle['tls_live'],'idle_fds':idle['fds'],'new_connections':new,'resumed_new_connections':reused_sessions,'full_handshakes':new-reused_sessions,'new_connection_setup_mean_ms':b['new_connection_appconnect_us_sum']/max(1,new)/1000,'handshake_phase_mean_ms':b['handshake_phase_us_sum']/max(1,new)/1000,'cpu_seconds':cpu,'mean_cpu_cores':cpu/elapsed})
  assert offset==len(conn)
with open(a.output,'w') as f:
 writer=csv.DictWriter(f,fieldnames=list(rows[0]),lineterminator='\n');writer.writeheader();writer.writerows(rows)
print(json.dumps({'cases':sum(1 for r in rows if r['burst']==0),'bursts':len(rows),'verified_bytes':sum(r['verified_bytes'] for r in rows)},indent=2))
for r in rows:print(f"{r['case']} burst {r['burst']}: p95 {r['control_p95_ms']:.2f} ms, max {r['control_max_ms']:.2f} ms, {r['verified_MiB_s']:.2f} MiB/s, new/full/resumed {r['new_connections']}/{r['full_handshakes']}/{r['resumed_new_connections']}")
