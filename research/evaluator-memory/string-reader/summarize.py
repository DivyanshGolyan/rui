#!/usr/bin/env python3
"""Render selected rows without summing peaks from different instants."""
import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
x = json.loads((HERE/'results.json').read_text())
assert x['verified']
names = {0:'reader', 1:'staged reader', 2:'public chunks + join'}
lines = ['# UTF-8 reader measurements', '',
         'Release profile; all sizes in bytes. Decode overlap is the maximum simultaneous engine + native backing allocation, including allocation headers, allocator rounding and old/new blocks during forced-moving realloc. It excludes fixed C stack, libc bookkeeping and OS memory; those are not heap-allocation counters.', '',
         '| Input | Method | Input bytes | Decode overlap peak | Native requested workspace | Native backing peak | Decode checkpoint CPU (µs) |',
         '| --- | --- | ---: | ---: | ---: | ---: | ---: |']
for r in x['runs']:
    if r['name'] not in ['ascii-4m','late-wide-4m','all-scalars','wide-key','items-1024']:
        continue
    last = r['records'][-1]
    point = next(m for m in r['records'] if m['phase']=='decoded_before_scratch_release')
    cpu = point['cpu_user_us'] + point['cpu_system_us']
    lines.append(f"| {r['name']} | {names[r['staged']]} | {r['input_bytes']:,} | {last['decode_overlap_peak']:,} | {point['native_requested']:,} | {last['decode_native_peak']:,} | {cpu:,} |")
lines += ['', '## Process memory and retained allocations', '',
          'These are separate from allocation counters. The physical column is a sampled macOS task footprint; maximum RSS is an OS high-water mark. Neither is a JS heap measure.', '',
          '| Input/method | Sampled physical peak | Maximum RSS | Engine live at released idle | Engine live after runtime free |',
          '| --- | ---: | ---: | ---: | ---: |']
for r in x['runs']:
    if r['name'] not in ['late-wide-4m','burst']:
        continue
    last = r['records'][-1]
    idle = next(m for m in r['records'] if m['phase']=='released_idle')
    lines.append(f"| {r['name']} / {names[r['staged']]} | {last['sampled_physical_peak']:,} | {last['maxrss_raw']:,} | {idle['engine_live']:,} | {last['engine_live']:,} |")
lines += ['', '## Identity and reads', '',
          '| Case / method | Invocations | File bytes read | Full lifecycle CPU (µs) |',
          '| --- | ---: | ---: | ---: |']
for r in x['runs']:
    if r['staged'] or r['name'] not in ['ascii-4m','late-wide-4m','separate','promise','retained','burst']:
        continue
    m = r['records'][-1]
    lines.append(f"| {r['name']} / reader | {m['decode_calls']:,} | {m['read_bytes']:,} | {m['cpu_user_us']+m['cpu_system_us']:,} |")
lines += ['', f"Release: {len(x['runs'])} cases, 16,777,216-byte QuickJS setting, 8,388,608-byte native requested-allocation ceiling, one-second soft CPU/two-second hard CPU and five-second parent timeout. Same workload and policy per compared method. The full lifecycle CPU includes the independent content oracle; the earlier checkpoint includes startup and decoding.", '']
if (HERE/'sanitizer-results.json').exists():
    s = json.loads((HERE/'sanitizer-results.json').read_text())
    if s.get('verified'):
        injected = [r for r in s['runs'] if r.get('engine_fail')]
        counts = {method:max(r['engine_fail'] for r in injected if r['staged']==method) for method in [0,1]}
        lines += [f"Diagnostics: {len(s['runs'])} ASan/UBSan cases; every one of {counts[0]} reader and {counts[1]} staged-reader backing allocation points in the nested fixture was fault-injected. Small-block arenas are disabled via the pin's sanitizer macro so individual allocations reach the instrumented allocator. Diagnostic CPU/lifetime limits are 10/30 seconds; these results do not qualify release timing.", '']
(HERE/'measurements.md').write_text('\n'.join(lines))
