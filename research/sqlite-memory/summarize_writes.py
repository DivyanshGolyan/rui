#!/usr/bin/env python3
"""Recompute follow-up report arithmetic from raw measurements."""
import json, pathlib, statistics
HERE=pathlib.Path(__file__).resolve().parent
runs=json.loads((HERE/'write-attribution-results.json').read_text())
granularity=json.loads((HERE/'write-granularity-results.json').read_text())
summary={'population':10000,'attribution':[],'granularity':[]}
for run in runs:
    f=next(r for r in run['records'] if r.get('sessions')==10000)
    t=next((r for r in run['records'] if r.get('write_probe_population')==10000),None)
    out={'kind':run['kind'],'cache_kib':run['cache_kib'],'process_bytes':f['process_disk_write_bytes'],'database_bytes':f['database_file_bytes'],'database_allocated':f['database_allocated_bytes'],'sqlite_page_writes':f['sqlite_page_writes'],'spills':f['sqlite_cache_spills'],'seconds':f['wall_ns']/1e9,'p95_ms':f['transaction_p95_ns']/1e6,'sqlite_live':f['sqlite_heap_current_bytes'],'sqlite_peak':f['sqlite_heap_highwater_bytes']}
    if t:
        d,j=t['files']['database'],t['files']['journal']
        out.update(database_vfs_bytes=d['write_bytes'],journal_vfs_bytes=j['write_bytes'],database_syncs=d['syncs'],journal_syncs=j['syncs'],journal_deletes=j['deletes'],commits=t['commits'],repeat_page_writes=t['repeated_main_page_writes_in_transaction'],os_during_database_sync=d['os_sync'],os_during_journal_sync=j['os_sync'])
        out['os_unattributed']=f['process_disk_write_bytes']-sum(v[k] for v in t['files'].values() for k in ['os_write','os_sync','os_truncate','os_delete']) if run['os_attribution'] else None
        out['vfs_bytes_per_session']=(d['write_bytes']+j['write_bytes'])/10000
        out['os_bytes_per_session']=f['process_disk_write_bytes']/10000
    summary['attribution'].append(out)
means={}
for cache in [64,128]:
    rows=[r for r in summary['attribution'] if r['kind']=='light' and r['cache_kib']==cache]
    assert len(rows)==2
    means[str(cache)]={k:statistics.mean(r[k] for r in rows) for k in ['process_bytes','seconds','journal_syncs','sqlite_live','database_vfs_bytes','journal_vfs_bytes']}
summary['light_means']=means
summary['light_128_vs_64_reduction_percent']={k:100*(1-means['128'][k]/means['64'][k]) for k in ['process_bytes','seconds','journal_syncs']}
for run in granularity['production']:
    t=next(r for r in run['records'] if r.get('write_probe_population')==10000)
    g=next(r for r in run['records'] if r.get('granularity_population')==10000)
    for kind in ['database','journal']:
        actual=t['files'][kind]['os_sync'];predicted=g[kind+'_clipped']
        summary['granularity'].append({'cache_kib':run['cache_kib'],'kind':kind,'system_page':g['unit_bytes'],'filesystem_fragment':g['block_bytes'],'vfs_bytes':t['files'][kind]['write_bytes'],'os_sync_bytes':actual,'raw_unit_prediction':g[kind+'_predicted'],'tail_clipped_prediction':predicted,'actual_minus_clipped':actual-predicted})
summary['calibration']=granularity['calibration']
(HERE/'write-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
