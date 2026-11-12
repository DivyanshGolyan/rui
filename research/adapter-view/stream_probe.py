#!/usr/bin/env python3
"""Streaming materialization evidence; synthetic wire and system SQLite only."""
import hashlib
import json
import platform
import sqlite3
import subprocess
import sys
import tempfile
import tracemalloc
from pathlib import Path
from core import Core, ResourceExceeded, Unavailable
from streaming import prepare
from probe import rejected

HERE = Path(__file__).resolve().parent


def digest_file(file):
    digest = hashlib.sha256()
    while chunk := file.read(4096): digest.update(chunk)
    return digest.hexdigest()


def expected_input(items):
    return {'model':'fixture','store':False,'stream':True,
        'include':['reasoning.encrypted_content'],'input':items}


def build_large(core,size):
    op = core.admit()
    result = core.accept(op,[b'{}'])
    key = core.db.execute('SELECT body FROM item WHERE result=?',(result,)).fetchone()[0]
    prefix = b'{"created_by":{"discard":[1,2]},"type":"reasoning","encrypted_content":"'
    suffix = b'","unknown":{"created_by":"retain nested","values":[true,null,1.2e-3]}}'
    piece = b'abc\\n\\u1234\\"\\\\xyz'
    count = size//len(piece)
    total = len(prefix)+len(suffix)+len(piece)*count
    with core.db:
        core.db.execute('UPDATE payload SET body=zeroblob(?) WHERE id=?',(total,key))
        blob = core.db.blobopen('payload','body',key)
        digest = hashlib.sha256()
        def put(chunk):
            blob.write(chunk)
            digest.update(chunk)
        put(prefix)
        # Fixture creation is also incremental, independently of measured reads.
        for _ in range(count): put(piece)
        put(suffix)
        blob.close()
        core.db.execute('UPDATE payload SET digest=? WHERE id=?',(digest.hexdigest(),key))
    target = core.admit()
    oracle = hashlib.sha256()
    oracle.update(b'{"model":"fixture","store":false,"stream":true,"include":["reasoning.encrypted_content"],"input":[{"type":"reasoning","encrypted_content":"')
    for _ in range(count): oracle.update(piece)
    oracle.update(suffix+b']}')
    return target,oracle.hexdigest(),total


def run():
    passed, measurements = [], []
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory)/'small.db'
        core = Core(path)
        core.fact('settings',{'model':'fixture'})
        user = {'role':'user','content':'Hello \"\\\n☃'}
        core.fact('user',user)
        op = core.admit()
        fixture = json.loads((HERE.parent/'provider-wire/fixtures.json').read_text())
        call2={'type':'function_call','call_id':'call2','name':'Bash','arguments':'{}'}
        core.accept(op,fixture['response']['output']+[call2])
        tool = {'type':'function_call_output','call_id':'call1','output':'ok'}
        tool2={'type':'function_call_output','call_id':'call2','output':'finished first'}
        core.tool('call2',tool2)
        core.tool('call1',tool)
        target = core.admit()
        with prepare(core.view(target)) as file:
            assert json.load(file)==expected_input([user]+fixture['expected_replay']+[call2,tool,tool2])
        passed.append('complete Responses envelope matches independent existing replay golden')
        passed.append('streamed tool results preserve call order despite reverse completion')
        with prepare(core.view(target),compacting=True) as file:
            assert json.load(file)==expected_input([user]+fixture['expected_replay']+[call2,tool,tool2,{'type':'compaction_trigger'}])
        passed.append('compaction request appends trigger after complete input')

        # Escaped property spelling and >window key size do not bypass omission
        # or cause whole-key allocation. Nested created_by must survive.
        raw = b'{"creat\\u0065d_by":1,"'+b'k'*5000+b'":{"created_by":2},"type":"message"}'
        special = core.admit()
        core.accept(special,[raw])
        target = core.admit()
        with prepare(core.view(target)) as file:
            last = json.load(file)['input'][-1]
            assert last=={'k'*5000:{'created_by':2},'type':'message'}
        passed.append('escaped omitted key, oversized unknown key, nested unknown field preserved')

        compact = {'type':'compaction','encrypted_content':'opaque'}
        trailing = {'type':'message','content':[{'type':'output_text','text':'tail'}]}
        op = core.admit()
        during = {'role':'user','content':'Arrived during compaction'}
        core.fact('user',during)
        core.accept(op,[{'type':'reasoning'},compact,trailing],kind='compaction',anchor=1)
        later = {'role':'user','content':'Next'}
        core.fact('user',later)
        target = core.admit()
        with prepare(core.view(target)) as file:
            assert json.load(file)==expected_input([user,compact,trailing,during,later])
        passed.append('complete request compaction slice includes trailing object and later suffix')
        passed.append('message arriving during compaction follows base using admission cutoff')

        # All failures must close scratch and return no dispatchable file.
        files = []
        def factory(**kwargs):
            file = tempfile.TemporaryFile(**kwargs)
            files.append(file)
            return file
        view = core.view(target)
        rejected(lambda: prepare(view,allowance=30,file_factory=factory),ResourceExceeded)
        assert files[-1].closed and not view._reading
        passed.append('scratch exhaustion closes incomplete request and releases reader')
        core.db.close()

        for size in (128*1024,4*1024*1024):
            path = Path(directory)/f'large-{size}.db'
            core = Core(path)
            core.fact('settings',{'model':'fixture'})
            target,oracle,total = build_large(core,size)
            child = json.loads(subprocess.check_output([sys.executable,__file__,'child',str(path),str(target)]))
            assert child['sha256']==oracle and child['max_chunk']==4096
            child['input_bytes']=total
            measurements.append(child)
            view = core.view(target)
            original = view.chunks
            def faulty(ref,size=4096):
                reader = original(ref,size)
                try:
                    for index,chunk in enumerate(reader):
                        if index==2: raise OSError('injected source read failure')
                        yield chunk
                finally:
                    reader.close()
            view.chunks = faulty
            rejected(lambda: prepare(view,file_factory=factory),OSError)
            assert files[-1].closed and not view._reading
            # Failure after the entire payload has been copied must also stop dispatch.
            core.db.execute("UPDATE payload SET digest='wrong' WHERE length(body)>100000")
            core.db.commit()
            rejected(lambda: prepare(core.view(target),file_factory=factory),Unavailable)
            assert files[-1].closed
            core.db.close()
        assert measurements[1]['peak_python_bytes'] < measurements[0]['peak_python_bytes']+256*1024
        passed.extend(['large opaque request matches independently streamed byte digest after process reopen',
            '32x payload growth does not grow Python allocation peak by 256 KiB',
            'mid-read and final-integrity failures expose no complete request'])

        class BrokenFile:
            def __init__(self):
                self.file=tempfile.TemporaryFile(mode='w+b')
            def __getattr__(self,name): return getattr(self.file,name)
            def write(self,data): raise OSError('injected scratch write failure')
        broken=BrokenFile()
        core=Core(Path(directory)/'write.db')
        core.fact('settings',{'model':'fixture'})
        target=core.admit()
        rejected(lambda: prepare(core.view(target),file_factory=lambda **kw:broken),OSError)
        assert broken.closed
        core.db.close()
        passed.append('scratch write failure closes incomplete request')
    return {'passed':passed,'measurements':measurements,'platform':platform.platform(),
        'python':platform.python_version(),'sqlite':sqlite3.sqlite_version,
        'source_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in HERE.glob('*.py')},
        'limits':['Synthetic Responses envelope; no network, live encryption or production provider integration.',
        'Lexical copier trusts already-validated canonical JSON; it is not an input validator.',
        'tracemalloc measures Python allocations, not SQLite native allocations, RSS or whole-Host bounds.',
        'One Session, prior applicability and compaction coverage assumed; no crash/power-loss claim.',
        'Prepare returns sealed-by-convention scratch; real dispatch permit/cancellation/cleanup integration remains unqualified.']}


if __name__=='__main__':
    if len(sys.argv)>1 and sys.argv[1]=='child':
        core=Core(sys.argv[2])
        view=core.view(int(sys.argv[3]))
        tracemalloc.start()
        with prepare(view) as file:
            digest=digest_file(file)
        _,peak=tracemalloc.get_traced_memory()
        tracemalloc.stop()
        print(json.dumps({'sha256':digest,'peak_python_bytes':peak,'max_chunk':view.max_chunk}))
    else:
        results=run()
        (HERE/'stream-results.json').write_text(json.dumps(results,indent=2)+'\n')
        print(json.dumps(results,indent=2))
