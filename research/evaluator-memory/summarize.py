#!/usr/bin/env python3
"""Derive the compact measurement tables from the retained raw records."""
import json,pathlib
here=pathlib.Path(__file__).resolve().parent
x=json.loads((here/'results.json').read_text())
lines=['# Recorded decoding measurements','','All numbers are bytes. `engine peak` is backing allocator usable bytes, including engine/native runtime allocations; `JS used` is QuickJS\'s structural estimate at the loaded marker. Neither is process physical footprint. Footprint peaks are sampled, not continuous maxima.','','| Case | Whole input staged | Engine peak | Native requested peak | Sampled physical peak | Retained-idle physical |','| --- | --- | ---: | ---: | ---: | ---: |']
for r in x['runs']:
 if r['case'] not in ['bytes-65536','bytes-1048576','bytes-4194304','items-1024','items-16384','selective','saved-1','saved-32','saved-1024','separate','promise','retained','burst','heap-exhaustion']:continue
 m=r['measurements'][-1];idle=r['measurements'][-2]
 lines.append(f"| {r['case']} | {r['buffered']} | {m['engine_allocator_peak']:,} | {m['native_peak']:,} | {m['sampled_footprint_peak']:,} | {idle['physical_footprint']:,} |")
lines+=['','## Engine accounting at the loaded marker','','| Direct case | Allocator live | QuickJS allocation accounting | JS used estimate |','| --- | ---: | ---: | ---: |']
for r in x['runs']:
 if r['buffered'] or r['case'] not in ['bytes-4194304','items-1','items-16384','retained','promise']:continue
 m=next(m for m in r['measurements'] if m['phase']=='loaded')
 lines.append(f"| {r['case']} | {m['engine_allocator_live']:,} | {m['engine_accounted']:,} | {m['js_memory_used']:,} |")
lines+=['','## Parent preparation and saved population','','| Saved results, each 65,536 payload bytes | Scratch logical | Scratch allocated | Python preparation peak | Parent prepared physical | Child bytes read |','| --- | ---: | ---: | ---: | ---: | ---: |']
for r in x['runs']:
 if r['buffered'] or not r['case'].startswith('saved-'):continue
 p=r['preparation'];m=r['measurements'][-1]
 lines.append(f"| {r['visible_results']:,} | {p['scratch_logical_bytes']:,} | {p['scratch_allocated_bytes']:,} | {p['parent_python_peak']:,} | {p['parent_prepared_physical_footprint']:,} | {m['read_bytes']:,} |")
lines+=['',f"Parent cold physical footprint after dependency build/loading: {x['parent_cold_physical_footprint']:,} bytes. Each native child receives one read-only prepared file plus three stdio streams. Preparation and integrity checking reuse bounded chunks; the child never reads unselected records. Global vm_stat snapshots in the saved-1024 rows are contextual system-wide cache/page counts, not attributable Rui memory.",'']
(here/'measurements.md').write_text('\n'.join(lines))
