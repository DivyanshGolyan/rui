#!/usr/bin/env python3
import json, statistics
from pathlib import Path
p=Path(__file__).parent
r=json.loads((p/'two-pass-results.json').read_text())
rows=[]
for label in ['synthetic-65536','synthetic-1048576','synthetic-4194304','many-items-10','many-items-1000','many-items-10000']:
 for mode in ['stream','stream-two']:
  samples=[x for x in r['samples'] if x['label'].split('-repeat-')[0]==label and x['mode']==mode]
  rows.append(dict(fixture=label,mode=mode,repeats=len(samples),input_bytes=samples[0]['input_bytes'],index_bytes=samples[0]['index_scratch_bytes'],allocator_peak=max(x['allocator_peak'] for x in samples),sqlite_peak=max(x['sqlite_or_decoded_peak'] for x in samples),rss_median=statistics.median(x['peak_rss'] for x in samples),import_ms=statistics.median(x['import_ns']/1e6 for x in samples),validation_and_import_ms=statistics.median((x['import_ns']+x['validation_ns'])/1e6 for x in samples)))
(p/'two-pass-summary.json').write_text(json.dumps(rows,indent=2)+'\n')
print(json.dumps(rows,indent=2))
