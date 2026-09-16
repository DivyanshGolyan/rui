#!/usr/bin/env python3
"""Qualify a pinned, synchronous UTF-8 reader extension and thin data decoder."""
import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import platform
import struct
import subprocess
import tempfile
import time
import tracemalloc
import urllib.request
from fixtures import Text, Object, Raw, Hash, prepare

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
PIN = json.loads((HERE/'dependency.json').read_text())
parser = argparse.ArgumentParser()
parser.add_argument('--source', type=pathlib.Path)
parser.add_argument('--output', type=pathlib.Path)
parser.add_argument('--sanitize', action='store_true')
parser.add_argument('--smoke', action='store_true')
parser.add_argument('--negative-control', action='store_true')
parser.add_argument('--strict-cpu', action='store_true', help='Keep 1s/5s during sanitizer diagnostics to reproduce overhead exhaustion')
args = parser.parse_args()
diagnostic = args.sanitize and not args.strict_cpu
args.output = args.output or HERE/('negative-control.json' if args.negative_control else 'smoke.json' if args.smoke else 'sanitizer-results.json' if args.sanitize else 'results.json')


def program(expected, mode):
    oracle = (HERE/'oracle.js').read_text()
    check = f"if(fingerprint(value)!=={expected})throw Error('content');"
    if mode == 'prototype-hook':
        body = "let hits=0;const join=Array.prototype.join;Object.defineProperty(Array.prototype,'0',{get(){hits++;return 'poison'},set(){hits++},configurable:true});Array.prototype.join=()=>{throw Error('replaced join')};try{let value=await lookup();"+check+"if(hits)throw Error('prototype hook');mark('loaded');}finally{delete Array.prototype['0'];Array.prototype.join=join;}"
    elif mode == 'separate':
        body = "let value=await lookup();"+check+"for(let i=0;i<10;i++){let a=await lookup();a.a[0].value='changed';let b=await lookup();if(a===b||a.a===b.a||a.a[0]===b.a[0]||b.a[0].value==='changed')throw Error('alias');}mark('loaded');"
    elif mode == 'promise':
        body = "let p=lookup();let value=await p;"+check+"value.a[0].value='changed';for(let i=0;i<10000;i++){let a=await p;if(a!==value||a.a[0].value!=='changed')throw Error('identity');}mark('loaded');"
    elif mode == 'retained':
        body = "let held=[];for(let i=0;i<4;i++)held.push(await lookup());let value=held[0];mark('loaded');"+check+"value=null;held=null;"
    elif mode == 'heap':
        body = "let held=[];for(let i=0;i<5;i++)held.push(await lookup());throw Error('expected exhaustion');"
    elif mode == 'burst':
        body = "for(let j=0;j<3;j++){let held=[];for(let i=0;i<4;i++)held.push(await lookup());mark('burst_loaded');let value=held[0];"+check+"value=null;held=null;await 0;mark('burst_released');}"
    else:
        body = "let value=await lookup();mark('loaded');"+check
    return oracle+'\n(async()=>{'+body+'return 1;})()'


def build(source, scratch):
    for name, expected in PIN['source_sha256'].items():
        assert hashlib.sha256((source/name).read_bytes()).hexdigest() == expected, name
    translated = scratch/'quickjs-reader.c'
    translated.write_bytes((source/'quickjs.c').read_bytes()+b'\n#include "rui_string_reader.inc"\n')
    binary = scratch/'reader-probe'
    command = ['clang', '-O2', '-g', '-std=gnu11', '-funsigned-char', '-D_GNU_SOURCE', '-DQUICKJS_NG_BUILD=1',
               '-I', str(source), '-I', str(HERE), str(translated), str(HERE/'probe.c')]
    command += [str(source/name) for name in ['dtoa.c', 'libregexp.c', 'libunicode.c']]
    command += ['-lm', '-lpthread', '-o', str(binary)]
    if args.sanitize:
        command[1:1] = ['-fsanitize=address,undefined', '-fno-sanitize-recover=all', '-D__SANITIZE_ADDRESS__=1']
    if args.negative_control:
        command[1:1]=['-DOP_NEGATIVE_SET=1']
    subprocess.run(command, check=True, timeout=180)
    return binary, command


def cases():
    ordinary = Object([('a', [Object([('value','original'),('n',3.25)])]),('payload',Text(repeat=65536))])
    vectors = [
        ('empty',''), ('ascii',Text(repeat=1048576)),
        ('ascii-4m',Text(repeat=4194304)),
        ('latin1',Text('é',524288)),
        ('late-wide',Text(repeat=1048576,suffix='中')),
        ('late-wide-4m',Text(repeat=4194304,suffix='中')),
        ('late-astral',Text(repeat=1048576,suffix='😀')),
        ('all-scalars',Text(all_scalars=True)),
        ('objects-keys',Object([('__proto__',Object([('safe',True)])),('nul\0é😀',['x',False,None,-0.0,3.25]),('12','numeric'),('2','numeric2'),('é',1),('Ã©',2)])),
        ('long-key',Object([(Text(repeat=1048576), 'value')])),
        ('wide-key',Object([(Text(repeat=1048576,suffix='中'), 'value')])),
        ('items-1024',[Text('é中😀',1) for _ in range(1024)]),
        ('injection-oracle',Object([('keyé',[Object([('nested','😀中')]),True,42]),('x','value')]))]
    for staged in [0,1]:
        for name,value in vectors:
            yield dict(name=name,value=value,staged=staged,window=16384)
        for width in [1,2,3,7]:
            yield dict(name=f'window-{width}',value='\0\u007f\u0080éÿĀ中😀\U0010ffff',staged=staged,window=width)
        yield dict(name='prototype-hook',value=['original','😀'],staged=staged,window=16384,mode='prototype-hook')
        for mode in ['separate','promise']:
            yield dict(name=mode,value=ordinary,staged=staged,window=16384,mode=mode)
        yield dict(name='retained',value=Object([('payload',Text(repeat=1048576))]),staged=staged,window=16384,mode='retained')
        yield dict(name='burst',value=Object([('payload',Text(repeat=262144))]),staged=staged,window=16384,mode='burst')
        yield dict(name='heap-exhaustion',value=Text(repeat=4194304),staged=staged,window=16384,mode='heap',failure='engine_exhaustion')
        invalid = [b'\x80',b'\xc0\x80',b'\xc1\xbf',b'\xe0\x80\x80',b'\xed\xa0\x80',b'\xed\xbf\xbf',b'\xf0\x80\x80\x80',b'\xf4\x90\x80\x80',b'\xf5\x80\x80\x80',b'\xf0\x9f',b'\xe2x\xa1']
        for i,bad in enumerate(invalid):
            # Put invalid/truncated sequences across the input-window boundary.
            raw=b'x'*16383+bad
            yield dict(name=f'utf8-{i}',value=Raw(b'\4'+struct.pack('<Q',len(raw))+raw),staged=staged,window=16384,failure='invalid_utf8')
        yield dict(name='invalid-key',value=Raw(b'\6'+struct.pack('<I',1)+struct.pack('<Q',3)+b'\xed\xa0\x80'+b'\0'),staged=staged,window=1,failure='invalid_utf8')
        yield dict(name='duplicate-key',value=Object([('é',1),('é',2)]),staged=staged,window=1,failure='duplicate_key')
        yield dict(name='huge-length',value=Raw(b'\4'+struct.pack('<Q',2**64-1)),staged=staged,window=16384,failure='invalid_range')
        yield dict(name='invalid-tag',value=Raw(b'\xff'),staged=staged,window=16384,failure='invalid_tag')
        yield dict(name='nonfinite',value=Raw(b'\3'+struct.pack('<d',float('inf'))),staged=staged,window=16384,failure='invalid_number')
        yield dict(name='trailing',value=Raw(b'\0\0'),staged=staged,window=16384,failure='trailing_bytes')
        yield dict(name='short',value='😀中',staged=staged,window=1,truncate=True,failure='short_read')
        yield dict(name='changed-between-passes',value='xx',staged=staged,window=16384,mutate=1,failure='input_changed')
        yield dict(name='native-workspace',value='ok',staged=staged,window=16384,native_fail=1,failure='native_exhaustion')
        if staged:
            yield dict(name='native-staging',value='ok',staged=1,window=16384,native_fail=2,failure='native_exhaustion')
        for read_at in ([1,3,4] if not staged else [1,4,5]):
            yield dict(name=f'read-failure-{read_at}',value='abc',staged=staged,window=16384,read_fail=read_at,failure='injected_read_failure')


with open('/tmp/rui-memory-experiments.lock','a') as lock:
    print('Waiting for shared experiment lock',flush=True)
    fcntl.flock(lock,fcntl.LOCK_EX)
    with tempfile.TemporaryDirectory(prefix='rui-string-reader-') as tmp:
        scratch=pathlib.Path(tmp)
        source=args.source.resolve() if args.source else None
        if source is None:
            archive=scratch/'qjs.tar.gz'
            urllib.request.urlretrieve(f"https://github.com/quickjs-ng/quickjs/archive/{PIN['pin']}.tar.gz",archive)
            assert hashlib.sha256(archive.read_bytes()).hexdigest()==PIN['archive_sha256']
            subprocess.run(['tar','-xzf',str(archive),'-C',str(scratch)],check=True)
            source=scratch/f"quickjs-{PIN['pin']}"
        binary, command=build(source,scratch)
        output=dict(revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
                    recorded_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),
                    machine=platform.platform(),python=platform.python_version(),
                    compiler=subprocess.check_output(['clang','--version'],text=True),
                    limits={'engine_bytes':16777216,'native_requested_bytes':8388608,'cpu_soft_seconds':10 if diagnostic else 1,'cpu_hard_seconds':11 if diagnostic else 2,'parent_seconds':30 if diagnostic else 5},negative_control=args.negative_control,sanitized=args.sanitize,small_block_arenas=not args.sanitize,smoke=args.smoke,dependency=PIN,compile_command=command,
                    harness_sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in HERE.iterdir() if p.suffix in ['.h','.inc','.c','.py','.js']},runs=[])

        def save():
            args.output.parent.mkdir(parents=True,exist_ok=True)
            args.output.write_text(json.dumps(output,indent=2)+'\n')

        def execute(case):
            path=scratch/'input'
            tracemalloc.start()
            digest=prepare(path,case['value'])
            current,peak=tracemalloc.get_traced_memory()
            tracemalloc.stop()
            size=path.stat().st_size
            expected=0
            if not case.get('failure') or case.get('control'):
                oracle=Hash();oracle.walk(case['value']);expected=oracle.value
            if case.get('truncate'):
                os.truncate(path,size-1)
            fd=os.open(path,os.O_RDONLY)
            start=time.monotonic()
            try:
                result=subprocess.run([str(binary),str(fd),str(size),str(case['staged']),str(case['window']),
                    str(case.get('engine_fail',0)),str(case.get('native_fail',0)),str(case.get('read_fail',0)),str(case.get('mutate',0)),str(int(diagnostic)),program(expected,case.get('mode','once'))],
                    input='',pass_fds=(fd,),env={},capture_output=True,text=True,timeout=30 if diagnostic else 5)
            finally:
                os.close(fd)
                path.unlink()
            records=[json.loads(line) for line in result.stdout.splitlines()]
            row={k:v for k,v in case.items() if k!='value'}
            row.update(input_bytes=size,input_sha256=digest,expected_fingerprint=expected,
                parent_preparation_current=current,parent_preparation_peak=peak,
                returncode=result.returncode,stderr=result.stderr,elapsed_seconds=time.monotonic()-start,records=records)
            output['runs'].append(row)
            save()  # Keep failure evidence before validating the claimed outcome.
            assert result.stderr=='',(case['name'],result.stderr)
            expected_exit=10 if case.get('failure') else 0
            if case.get('allow_exhaustion'):
                assert result.returncode in [0,10],row
                assert records[-1]['failure']==('engine_exhaustion' if result.returncode else 'none'),row
            elif case.get('engine_fail'):
                assert result.returncode in [0,10],row
                assert records[-1]['engine_injected_failures']==1,row
                if result.returncode==10:assert records[-1]['failure']=='engine_exhaustion',row
            else:
                assert result.returncode==expected_exit,row
                assert records[-1]['failure']==case.get('failure','none'),row
            assert records[-1]['phase']=='runtime_freed',row
            assert records[-1]['engine_live']==0 and records[-1]['native_live']==0,row
            assert any(r['phase']==('failed' if result.returncode else 'completed') for r in records),row
            assert not result.returncode or not any(r['phase']=='completed' for r in records),row
            print(case['name'],case['staged'],result.returncode,flush=True)
            return row

        selected=list(cases())
        for case in list(selected):
            if case['staged']==0 and case['name'] in ['ascii','ascii-4m','latin1','late-wide','late-wide-4m','late-astral','all-scalars','objects-keys','long-key','wide-key','items-1024','prototype-hook','separate','promise','retained','burst']:
                selected.append(dict(case,staged=2,allow_exhaustion=True))
        if args.negative_control:
            selected=[dict(c,failure='js_oracle_or_job',control=True,allow_exhaustion=False) for c in selected if c['name']=='prototype-hook']
        if args.smoke:
            selected=[c for c in selected if c['name'] in ['empty','late-wide','all-scalars','objects-keys','window-1','injection-oracle','short','read-failure-4']]
        for case in selected:
            execute(case)
        if not args.smoke and not args.negative_control:
            # Exhaust every backing allocation in one nested object/key decode,
            # including Promise construction. Successful recovery must still
            # match the complete independent fingerprint.
            for staged in [0,1]:
                baseline=next(r for r in output['runs'] if r['name']=='injection-oracle' and r['staged']==staged)
                attempts=baseline['records'][-1]['decode_attempts']
                for allocation in range(1,attempts+1):
                    vector=Object([('keyé',[Object([('nested','😀中')]),True,42]),('x','value')])
                    execute(dict(name=f'engine-allocation-{allocation}',value=vector,staged=staged,window=16384,engine_fail=allocation))
        output['verified']=True
        save()
        print(args.output)
