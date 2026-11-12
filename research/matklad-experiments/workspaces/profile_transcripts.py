#!/usr/bin/env python3
"""Read a bounded transcript snapshot; persist counts/sizes only, never payloads."""
import collections, datetime, hashlib, json, math, pathlib
root=pathlib.Path(__file__).resolve().parent
source=pathlib.Path('/Users/divyanshgolyan/.codex/sessions/2026/09/05')
limit=100_000_000
selected=[]; total=0
for p in sorted(source.glob('*.jsonl'),reverse=True):
    n=p.stat().st_size
    if n>limit-total: continue
    selected.append((p,n)); total+=n
    if len(selected)==20: break
counts=collections.Counter(); categories=collections.defaultdict(list); files=[]; invalid=0

def text_bytes(v):
    if isinstance(v,str): return len(v.encode('utf-8'))
    if isinstance(v,list): return sum(text_bytes(i.get('text','')) for i in v if isinstance(i,dict))
    return 0

for p,n in selected:
    with p.open('rb') as f: data=f.read(n)
    records=0
    for lineno,line in enumerate(data.splitlines(),1):
        try: obj=json.loads(line)
        except (ValueError,UnicodeDecodeError): invalid+=1; continue
        records+=1; outer=obj.get('type','unknown'); payload=obj.get('payload',{})
        subtype=payload.get('type','unknown') if isinstance(payload,dict) else 'unknown'
        counts[outer+'/'+subtype]+=1
        if outer!='response_item' or not isinstance(payload,dict): continue
        size=None; category=None
        if subtype=='message': category='message/'+payload.get('role','unknown'); size=text_bytes(payload.get('content'))
        elif subtype in ['function_call','custom_tool_call']:
            category=subtype+'/arguments'; size=text_bytes(payload.get('arguments',payload.get('input')))
        elif subtype in ['function_call_output','custom_tool_call_output']:
            category=subtype+'/output'; size=text_bytes(payload.get('output'))
        if category is not None:
            categories[category].append({'bytes':size,'source_id':p.name,'line':lineno,'record_bytes':len(line),'payload_json_bytes':len(json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode()),'payload_sha256':hashlib.sha256(json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode()).hexdigest()})
    files.append({'source_id':p.name,'snapshot_bytes':len(data),'snapshot_sha256':hashlib.sha256(data).hexdigest(),'record_count':records})

def percentile(xs,p):
    return sorted(xs)[max(0,math.ceil(len(xs)*p)-1)] if xs else None
stats={}
for category,rs in sorted(categories.items()):
    xs=[r['bytes'] for r in rs]
    stats[category]={'count':len(xs),'text_bytes_total':sum(xs),'text_bytes_p50':percentile(xs,.5),'text_bytes_p95':percentile(xs,.95),'text_bytes_max':max(xs),'payload_json_bytes_p95':percentile([r['payload_json_bytes'] for r in rs],.95)}
samples=[]
for category,p,label in [('message/assistant',.5,'assistant_median'),('message/assistant',.95,'assistant_p95'),('all_arguments',1,'largest_arguments'),('all_outputs',.95,'tool_output_p95'),('all_outputs',1,'largest_tool_output')]:
    if category.startswith('all_'):
        suffix='/arguments' if category=='all_arguments' else '/output'
        candidates=[dict(r,source_category=c) for c,rows in categories.items() if c.endswith(suffix) for r in rows]
    else: candidates=categories.get(category,[])
    rs=sorted(candidates,key=lambda r:r['bytes'])
    if rs: samples.append(dict(rs[max(0,math.ceil(len(rs)*p)-1)],category=category,selection=label))
report={'recorded_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'selection':'Up to 20 newest-started files in 2026/09/05 sorted by filename descending, whole-file snapshot sizes fitting an aggregate 100000000-byte cap. Active sessions may have grown afterward. No auth/config files.','source_format':'Codex semantic JSONL transcripts, not raw provider SSE; response_item records only for payload distributions. Event messages may duplicate semantic content and are excluded from payload stats. Text size counts decoded UTF-8 string bytes, not model tokens or in-memory parser representation.','files':files,'input_bytes':sum(r['snapshot_bytes'] for r in files),'invalid_or_partial_lines':invalid,'record_types':dict(sorted(counts.items())),'payload_statistics':stats,'selected_samples':samples,'privacy':'Metadata only; no transcript payload copied. Source identifiers, line numbers, sizes and hashes permit local re-extraction into temporary storage.'}
(root/'transcript-profile.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'files':len(files),'input_bytes':report['input_bytes'],'invalid_or_partial_lines':invalid,'statistics':stats,'selected_samples':samples},indent=2))
