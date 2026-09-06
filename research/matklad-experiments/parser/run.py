#!/usr/bin/env python3
"""Native post-seal feasibility probe. Real transcript content stays in temp files."""
import argparse, hashlib, json, pathlib, random, sqlite3, subprocess, tempfile, time, platform, re, tarfile

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[2]

def encoded(value):
    return json.dumps(value, ensure_ascii=True, separators=(',', ':')).encode()

def message(text):
    return {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': text}]}

def synthetic(n):
    return [message('x' * n), {'type': 'reasoning', 'encrypted_content': 'e' * n,
            'extension': {'deep': [{'number': 1e100, 'escaped': 'z' * n}]}},
            {'type': 'function_call', 'call_id': 'call', 'name': 'bash', 'arguments': '{"command":"true"}'}]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--smoke', action='store_true')
    ap.add_argument('--focus-large', action='store_true')
    ap.add_argument('--skip-transcripts', action='store_true')
    ap.add_argument('--output', type=pathlib.Path)
    opts = ap.parse_args()
    output = opts.output or HERE / ('smoke.json' if opts.smoke else 'results.json')
    rows, checks, transcript_metadata = [], [], []
    with tempfile.TemporaryDirectory(prefix='onepage-parser-') as tmp:
        temp = pathlib.Path(tmp); binary = temp/'probe'
        zon = (REPO/'build.zig.zon').read_text()
        pkg = re.search(r'\.sqlite = .*?\.hash = "([^"]+)"', zon, re.S)[1]
        env = subprocess.check_output(['zig','env'],text=True)
        cache = pathlib.Path(re.search(r'\.global_cache_dir = "([^"]+)"',env)[1])
        archive = cache/'p'/(pkg+'.tar.gz')
        if not archive.exists(): subprocess.run(['zig','build','--fetch=all'],cwd=REPO,check=True)
        with tarfile.open(archive) as package: package.extractall(temp/'sqlite',filter='data')
        source = next((temp/'sqlite').rglob('sqlite3.c'))
        config = (REPO/'build.zig').read_text().split('fn configureSqlite(',1)[1].split('\nfn ',1)[0]
        macros = ['-D'+k+'='+v for k,v in re.findall(r'addCMacro\("([^"]+)", "([^"]+)"\)',config)]
        build = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '-I',str(source.parent),
                 '-cflags','-std=c99','-fno-strict-aliasing',*macros,'--',str(source),
                 '-cflags','--',str(HERE/'metrics.c'),
                 '--dep', 'prod', '-Mroot='+str(HERE/'probe.zig'), '-Mprod='+str(REPO/'src/codex_provider.zig'), '-femit-bin='+str(binary)]
        subprocess.run(build, cwd=REPO, check=True)
        serial = 0
        def run_one(label, data, mode='stream', window=4096, expected=True, supported=True, sample=False):
            nonlocal serial
            serial += 1
            inp, db = temp/f'{serial}.input', temp/f'{serial}.sqlite'
            inp.write_bytes(data)
            start = time.perf_counter_ns()
            result = subprocess.run([str(binary), mode, str(inp), str(db), str(window)], capture_output=True, check=True, timeout=60)
            elapsed = time.perf_counter_ns()-start
            r = json.loads(result.stdout)
            timing=re.search(rb'import_ns=(\d+)',result.stderr)
            r['import_ns']=int(timing[1]) if timing else None
            validation=re.search(rb'validation_ns=(\d+)',result.stderr)
            r['validation_ns']=int(validation[1]) if validation else None
            r.update(label=label, mode=mode, window=window, process_elapsed_ns=elapsed, input_sha256=hashlib.sha256(data).hexdigest())
            assert r['valid'] is expected, (label, r)
            assert r['allocator_live_after'] == 0, (label, 'allocator leak', r)
            if mode.startswith('stream'):
                assert r['supported'] is supported, (label, r)
                with sqlite3.connect(db) as con:
                    blobs = [x[0] for x in con.execute('SELECT payload FROM items ORDER BY id')]
                if expected:
                    values = json.loads(data)
                    assert len(blobs)==len(values)
                    assert [json.loads(b) for b in blobs]==values
                    text = data.decode('utf-8'); offset = 1; expected_blobs = []
                    decoder = json.JSONDecoder()
                    while True:
                        while text[offset].isspace(): offset += 1
                        if text[offset] == ']': break
                        _, end = decoder.raw_decode(text, offset)
                        expected_blobs.append(text[offset:end].encode('utf-8'))
                        offset = end
                        while text[offset].isspace(): offset += 1
                        if text[offset] == ',': offset += 1
                    assert blobs == expected_blobs, 'ordinal raw-byte mismatch'
                    r['index_scratch_bytes'] = 0 if 'two' in mode else len(blobs)*16
                    r['preserved_item_bytes'] = sum(map(len, blobs))
                else:
                    assert not blobs, (label, 'partial publication')
                db.unlink()
            inp.unlink()
            (rows if sample else checks).append(r)
            return r

        def run(label, data, mode='stream', **kwargs):
            if mode.startswith('stream'):
                modes=[mode, mode.replace('stream','stream-two')]
                if sum(label.encode()) % 2: modes.reverse()
                results=[run_one(label,data,mode=m,**kwargs) for m in modes]
                return results[0]
            return run_one(label,data,mode=mode,**kwargs)

        base=encoded(synthetic(64))
        for window in [1, 7, 127, 4096]:
            run('fragmentation', base, window=window)
            run('unicode-escaped-key', b'[{"t\\u0079pe":"message","role":"assistant","content":[{"type":"output_text","text":"A\\n\\\"\\ud83d\\ude00"}],"'+b'k'*200+b'":{"any":[true,null,1.0]}}]', window=window)
        run('equivalent-items-distinct-spelling', b'[{"type":"reasoning","encrypted_content":"a"},{"type":"reasoning","encrypted_content":"\\u0061"}]',window=1)
        bads = {
            'truncated': base[:-1],
            'duplicate-type': b'[{"type":"reasoning","t\\u0079pe":"reasoning"}]',
            'duplicate-text': b'[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"a","text":"b"}]}]',
            'missing-type': b'[{"text":"x"}]',
            'missing-text': b'[{"type":"message","role":"assistant","content":[{"type":"output_text"}]}]',
            'wrong-shape': b'[{"type":"message","role":"assistant","content":42}]',
            'bad-surrogate': b'[{"type":"reasoning","encrypted_content":"\\ud800"}]',
            'invalid-utf8': b'[{"type":"reasoning","encrypted_content":"\xff"}]',
            'trailing-garbage': base+b'false',
            'late-invalid-item': base[:-1]+b',{"type":"message"}]',
            'excess-depth': b'[{"type":"reasoning","ext":'+b'['*65+b'0'+b']'*65+b'}]',
        }
        for label, data in bads.items():
            run(label,data,window=7,expected=False)
        run('unknown-item-evidence-only',b'[{"type":"future_effect","opaque":{"x":1}}]',supported=False)
        run('import-rollback',base,mode='stream-fail',expected=False)
        # Syntactic DOM parser is intentionally an invalid semantic oracle.
        r=run('negative-control-dom-accepts-missing-type',bads['missing-type'],mode='dom')
        assert r['valid']

        sizes=[64*1024] if opts.smoke else [64*1024, 1024*1024, 4*1024*1024]
        repeats=1 if opts.smoke else 5
        if opts.focus_large: sizes=[4*1024*1024]; repeats=10
        jobs=[(n,mode,i) for n in sizes for mode in ['stream','dom'] for i in range(repeats)]
        random.Random(419).shuffle(jobs)
        for n, mode, i in jobs:
            run(f'synthetic-{n}-repeat-{i}',encoded(synthetic(n)),mode=mode,sample=True)
        # The historical production Capture is fed its real SSE grammar. It is
        # intentionally not compared as a semantic equivalent of the new prototype.
        for n in ([1024] if opts.smoke else [1024,8192,32768,65536]):
            data=b'data: '+encoded({'type':'response.output_item.done','item':message('x'*n)})+b'\n\ndata: {"type":"response.completed"}\n\n'
            run(f'production-text-{n}',data,mode='production',expected=n <= 20*1024-24,sample=True)

        if not opts.skip_transcripts:
            profile=json.loads((HERE.parent/'workspaces/transcript-profile.json').read_text())
            source=pathlib.Path.home()/'.codex/sessions/2026/09/05'
            for meta in profile['selected_samples']:
                with (source/meta['source_id']).open('rb') as f:
                    for lineno,line in enumerate(f,1):
                        if lineno==meta['line']: payload=json.loads(line)['payload']; break
                    else: raise RuntimeError('Missing selected transcript record')
                exact=json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode()
                assert hashlib.sha256(exact).hexdigest()==meta['payload_sha256'], 'Selected record changed'
                if payload['type']=='message':
                    text=''.join(x.get('text','') for x in payload.get('content',[]) if isinstance(x,dict))
                    items=[message(text)]
                elif payload['type'] in ('custom_tool_call','function_call'):
                    value=payload.get('arguments',payload.get('input',''))
                    items=[{'type':'function_call','call_id':'local_sample','name':'sample','arguments':value}]
                else:
                    value=payload.get('output','')
                    if not isinstance(value,str): value=json.dumps(value,ensure_ascii=False)
                    # A tool result is not model output; this wrapper checks
                    # realistic string content only, not provider semantics.
                    items=[message(value)]
                label='local-'+meta['selection']
                for mode in ['stream','dom']: run(label,encoded(items),mode=mode,sample=True)
                transcript_metadata.append({'selection':meta['selection'],'source_id':meta['source_id'],'line':meta['line'],'payload_sha256':meta['payload_sha256'],'source_type':payload['type'],'fixture_bytes':len(encoded(items))})
        # Sequential post-seal burst, shared process parser workspace within each
        # array; output item population grows without retaining a resident item index.
        for count in ([] if opts.focus_large else ([10] if opts.smoke else [10,1000,10000])):
            for rep in range(repeats):
                run(f'many-items-{count}-repeat-{rep}',encoded([message('bounded') for _ in range(count)]),sample=True)
    report={'platform':platform.platform(),'zig':subprocess.check_output(['zig','version'],text=True).strip(),
            'method':'Fresh native processes; rotated synthetic cases; repository-pinned SQLite with build.zig macros, 256KiB cache; 4KiB windows; counted Zig allocations; actual production Capture separately measured. No live provider.',
            'limitations':['Prototype accepts sealed JSON output-item arrays, not full SSE streams. Narrow consumed-field validation only; no schema or complete provider policy.','DOM is an allocation positive control, not the current production architecture.','Local transcript text is rewrapped, not raw provider wire or opaque continuation. Payloads existed only in private temporary files, cleaned on normal completion and handled failures; abrupt process death can leave them behind.','Elapsed time includes startup; shared machine; cache not flushed; no release latency claim.'],
            'sqlite_package':pkg,'sqlite_macros':macros,'checks':checks,'samples':rows,'transcript_samples':transcript_metadata}
    output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'checks':len(checks),'samples':len(rows),'transcript_samples':len(transcript_metadata),'output':str(output)}))

if __name__=='__main__': main()
