"""Read local logs; write only aggregate usage statistics, never conversation text."""
from pathlib import Path
from datetime import datetime,timezone,timedelta
import sys,json,math,hashlib,collections
sys.path.insert(0,str(Path.home()/'.claude/skills/cclog'))
from cclog.parser import parse_jsonl_raw
now=datetime.now(timezone.utc);cut=now-timedelta(days=30)
metrics=collections.Counter();claude={};codex={};legacy={};dates=[]
def recent(t):
 try:
  d=datetime.fromisoformat(t.replace('Z','+00:00'))
  if d.tzinfo is None:d=d.replace(tzinfo=timezone.utc)
  return cut<=d<=now
 except (TypeError,ValueError,AttributeError):return False
def usage_key(u):return tuple(u.get(k,0) for k in ('input_tokens','cached_input_tokens','cache_write_input_tokens','output_tokens','reasoning_output_tokens','total_tokens'))
def normalized(u,kind):
 if kind=='claude': return (u.get('input_tokens',0)+u.get('cache_creation_input_tokens',0)+u.get('cache_read_input_tokens',0),u.get('output_tokens',0),u.get('cache_read_input_tokens',0))
 return (u.get('input_tokens',0),u.get('output_tokens',0),u.get('cached_input_tokens',0))
def keep(store,key,value):
 if key in store:
  metrics['duplicate_usage_records']+=1
  if store[key]!=value:metrics['duplicate_usage_values_differ']+=1
  store[key]=max(store[key],value)
 else:store[key]=value
for kind,base in [('claude',Path.home()/'.claude/projects'),('codex',Path.home()/'.codex/sessions')]:
 files=[p for p in base.rglob('*.jsonl') if p.stat().st_mtime>=cut.timestamp()]
 metrics[kind+'_candidate_files']=len(files)
 for p in files:
  metrics[kind+'_scanned_bytes']+=p.stat().st_size
  turn=None;sid=str(p); file_new=[];file_legacy=[];matched_new=set();contributes=False
  try:
   for o in parse_jsonl_raw(p):
    t=o.get('type');pl=o.get('payload',{})
    if kind=='codex':
     if t=='session_meta':sid=pl.get('id') or pl.get('session_id') or sid
     if t=='turn_context':turn=pl.get('turn_id') or turn
     if t=='event_msg' and pl.get('type')=='task_started':turn=pl.get('turn_id') or turn
    if not recent(o.get('timestamp')):continue
    if kind=='claude' and t=='assistant':
     m=o.get('message',{});u=m.get('usage');key=m.get('id') or o.get('requestId')
     if not isinstance(u,dict) or not key:metrics['claude_missing_usage_or_id']+=1;continue
     value=normalized(u,kind)
     if value[0]<=0:metrics['claude_zero_input']+=1;continue
     keep(claude,key,value);contributes=True
    elif kind=='codex' and t=='token_usage_record':
     u=pl.get('usage');rid=pl.get('response_id');tid=pl.get('turn_id') or turn
     if not isinstance(u,dict):continue
     totals=pl.get('thread_token_usage') or {}
     match=(tid,usage_key(u),usage_key(totals));matched_new.add(match)
     key=rid or ('fallback',sid,tid,usage_key(totals),usage_key(u))
     value=normalized(u,kind)
     if value[0]>0:keep(codex,key,value);file_new.append(value);contributes=True
    elif kind=='codex' and t=='event_msg' and pl.get('type')=='token_count':
     info=pl.get('info') or {};u=info.get('last_token_usage');total=info.get('total_token_usage') or {}
     if not isinstance(u,dict):continue
     value=normalized(u,kind)
     if value[0]>0 and total:file_legacy.append((turn,usage_key(u),usage_key(total),value))
   # Newer logs contain both forms. Use canonical response records for those files;
   # older logs use deduplicated cumulative-counter snapshots as a proxy.
   if kind=='codex':
    if file_new:metrics['codex_shadow_legacy_excluded']+=len(file_legacy)
    else:
     for tid,u,total,value in file_legacy:
      key=(sid,tid,total)
      keep(legacy,key,value);contributes=True
   if contributes:metrics[kind+'_contributing_files']+=1
  except Exception as e:metrics[kind+'_parse_errors_'+type(e).__name__]+=1
 print(kind,'done',flush=True)
def quant(xs,q):
 xs=sorted(xs);return xs[max(0,math.ceil(q*len(xs))-1)] if xs else None
def summary(values):
 values=list(values);inputs=[x[0] for x in values];outputs=[x[1] for x in values]
 return {'observations':len(values),'input_tokens':{k:quant(inputs,q) for k,q in [('p10',.1),('p50',.5),('p90',.9),('p95',.95),('p99',.99),('max',1)]},'output_tokens':{k:quant(outputs,q) for k,q in [('p50',.5),('p95',.95),('p99',.99)]},'input_buckets':{f'le_{n}':sum(v<=n for v in inputs) for n in [1000,4000,16000,64000,128000,256000,1000000]},'cached_input_fraction':sum(v[2] for v in values)/sum(inputs) if sum(inputs) else None}
out={'generated_at':now.isoformat(),'from':cut.isoformat(),'to':now.isoformat(),'analysis_source_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'metrics':dict(metrics),'claude':summary(claude.values()),'codex_canonical':summary(codex.values()),'codex_legacy_proxy':summary(legacy.values())}
Path('/tmp/onepage-transcript-usage.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2))
