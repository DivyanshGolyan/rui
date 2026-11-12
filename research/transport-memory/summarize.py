#!/usr/bin/env python3
"""Derive exact-byte tables and check terminal invariants from recorded raw JSONL."""
import csv,json,pathlib,statistics,hashlib,argparse
root=pathlib.Path(__file__).resolve().parent
parser=argparse.ArgumentParser();parser.add_argument('--groups',nargs='+',default=['results','followup-results','repeat-results','sanitizer-results']);parser.add_argument('--output',type=pathlib.Path,default=root/'summary.csv');args=parser.parse_args()
rows=[]
for folder in args.groups:
 directory=root/folder
 path=directory/'summary.jsonl'
 if not path.exists():raise FileNotFoundError(path)
 seen=set()
 meta=json.loads((directory/'metadata.json').read_text())
 for name,digest in meta['sources_sha256'].items():assert hashlib.sha256((directory/'sources'/name).read_bytes()).hexdigest()==digest
 for line in path.read_text().splitlines():
  d=json.loads(line);assert d['returncode']==0
  m={x['phase']:x for x in d['measurements'] if 'phase' in x}
  end=d['measurements'][-1];assert end['integrity'] and end['completed']==d['case'][1]
  assert end['errors']==(1 if d['case'][5]==4 else 0)
  clean=m['retained_idle'];assert clean['curl_live']==clean['tls_live']==clean['app_bytes']==clean['scratch_bytes']==0 and clean['fds']==3
  name=d['case'][0]
  assert name not in seen;seen.add(name)
  assert d['measurements']==[json.loads(line) for line in (directory/(name+'.jsonl')).read_text().splitlines()]
  server=json.loads((directory/(name+'-server.jsonl')).read_text().splitlines()[-1]);assert server['requests_integrity_checked']==d['case'][1]
  if d['case'][8]==2:assert server['connections']==1 and server['max_streams']==d['case'][1]
  rows.append({'group':folder,'case':name,'n':d['case'][1],'request_bytes':d['case'][2],'response_bytes':d['case'][3],'items':d['case'][4],'curl_peak':clean['curl_peak'],'tls_peak':clean['tls_peak'],'physical_peak':clean['max_physical'],'cold_physical':m['cold']['physical'],'retained_idle_physical':clean['physical'],'loaded_physical':m.get('loaded',m['staged'])['physical'],'curl_after_transfer':m['completed_waiting_validation']['curl_live'],'curl_after_easy_cleanup':m['transport_released_capture_retained']['curl_live'],'curl_serviced_cache':m['serviced_cache_idle']['curl_live'],'tls_serviced_cache':m['serviced_cache_idle']['tls_live'],'cache_fds_including_captures':m['serviced_cache_idle']['fds'],'max_fds':clean['max_fds'],'application_record_bytes':m['staged']['app_bytes'],'completed_scratch_bytes':m['completed_waiting_validation']['scratch_bytes'],'transfer_seconds':m['completed_waiting_validation']['seconds']-m['staged']['seconds'],'connections_created':end['connections_created'],'max_socket_readable':clean['max_socket_readable']})
with open(args.output,'w') as f:
 w=csv.DictWriter(f,fieldnames=list(rows[0]),lineterminator="\n");w.writeheader();w.writerows(rows)
print(json.dumps({'passing_runs':len(rows),'by_group':{g:sum(x['group']==g for x in rows) for g in sorted({x['group'] for x in rows})}},indent=2))
for case in sorted({x['case'].rsplit('-rep',1)[0] for x in rows if x['group']=='repeat-results'}):
 r=[x for x in rows if x['group']=='repeat-results' and x['case'].rsplit('-rep',1)[0]==case]
 print(case,json.dumps({k:{'min':min(x[k] for x in r),'median':statistics.median(x[k] for x in r),'max':max(x[k] for x in r)} for k in ['curl_peak','physical_peak','transfer_seconds']}))
