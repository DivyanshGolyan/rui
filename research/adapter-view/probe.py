#!/usr/bin/env python3
"""Run with python3 research/adapter-view/probe.py; no live provider calls."""
import hashlib
import json
import platform
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path
from core import Core, Unavailable, ResourceExceeded
from adapter import request, value

HERE = Path(__file__).resolve().parent


def rejected(fn, error):
    try:
        fn()
    except error:
        return
    raise AssertionError('expected rejection')


def render(path, operation, rules='normal'):
    return json.loads(subprocess.check_output([sys.executable,__file__,'child',str(path),str(operation),rules]))


def run():
    passed = []
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory)/'core.db'
        core = Core(path)
        settings = {'model':'synthetic-codex','instructions':'Review carefully'}
        user = {'role':'user','content':'Review the file'}
        core.fact('settings',settings)
        core.fact('user',user)
        first = core.admit()
        first_expected = {'settings':settings,'input':[user]}
        assert request(core.view(first)) == first_expected
        passed.append('ordinary chat independent expected request')

        fixtures = json.loads((HERE.parent/'provider-wire/fixtures.json').read_text())
        items = fixtures['response']['output']
        second_call = {'type':'function_call','call_id':'call2','name':'Bash','arguments':'{}'}
        result = core.accept(first,items+[second_call])
        tool1 = {'type':'function_call_output','call_id':'call1','output':'one'}
        tool2 = {'type':'function_call_output','call_id':'call2','output':'two'}
        core.tool('call2',tool2)
        between = core.admit()
        core.tool('call1',tool1)
        second = core.admit()
        expected = {'settings':settings,'input':[user]+fixtures['expected_replay']+[second_call,tool1,tool2]}
        assert request(core.view(second)) == expected
        passed.append('opaque objects and unknown fields match existing independent golden')
        passed.append('tool completion order differs from provider call order')
        assert core.view(between).tool_result('call1') is None
        rejected(lambda: request(core.view(between)),Unavailable)
        passed.append('late tool result cannot enter earlier view')

        core.fact('settings',{'model':'changed','instructions':'Changed'})
        core.fact('user',{'role':'user','content':'Also check security'})
        assert render(path,first) == first_expected
        assert render(path,second) == expected
        passed.append('fresh process preserves historical settings and inputs after later writes')
        changed = render(path,second,'omit-visible-summary')
        assert changed != expected and changed['input'][1]['encrypted_content'] == 'synthetic-private'
        passed.append('intentional adapter rule change changes request without changing history')
        assert render(path,second,'explicit-reset') == first_expected
        passed.append('explicit synthetic reset retains host input; not Codex wire qualification')

        compaction_op = core.admit()
        compact = {'type':'compaction','encrypted_content':'synthetic-compacted','extension':{'x':1}}
        trailing = {'type':'message','role':'assistant','content':[{'type':'output_text','text':'after anchor'}]}
        core.accept(compaction_op,[{'type':'reasoning','encrypted_content':'before-anchor'},compact,trailing],
            kind='compaction',anchor=1)
        later = {'role':'user','content':'Continue'}
        core.fact('user',later)
        third = core.admit()
        compact_expected = {'settings':{'model':'changed','instructions':'Changed'},
            'input':[user,{'role':'user','content':'Also check security'},compact,trailing,later]}
        assert render(path,third) == compact_expected
        assert request(core.view(second)) == expected
        passed.append('compaction retains host inputs, anchored output including trailing items, and later suffix')
        passed.append('later compaction cannot rewrite old view')

        public = core.view(second,private=False)
        output_ref = next(ref for kind,ref in public.history() if kind=='response')
        private = next(public.model_output(output_ref))
        rejected(lambda: value(public,private),Unavailable)
        passed.append('generic reader cannot open provider output')
        view = core.view(second)
        ref = view.settings()
        rejected(lambda: value(core.view(second),ref),AssertionError)
        view.close()
        rejected(lambda: value(view,ref),AssertionError)
        passed.append('foreign and expired handles reject')

        # Use writer-side fault injection; the adapter receives only its view.
        victim = core.db.execute('SELECT body FROM item WHERE result=? ORDER BY ordinal LIMIT 1',(result,)).fetchone()[0]
        saved = core.db.execute('SELECT body FROM payload WHERE id=?',(victim,)).fetchone()[0]
        with core.db:
            core.db.execute('UPDATE payload SET body=? WHERE id=?',(b'{}',victim))
        rejected(lambda: request(core.view(second)),Unavailable)
        with core.db:
            core.db.execute('UPDATE payload SET body=? WHERE id=?',(saved,victim))
        passed.append('corruption fails without visible-text fallback')
        with core.db:
            core.db.execute('DELETE FROM payload WHERE id=?',(victim,))
        rejected(lambda: request(core.view(second)),Unavailable)
        with core.db:
            core.db.execute('INSERT INTO payload(id,body,digest) VALUES (?,?,?)',
                (victim,saved,hashlib.sha256(saved).hexdigest()))
        passed.append('missing private payload fails without older-base or text fallback')

        # Large payload exercises reader transfer, not the small JSON adapter.
        large = b'x'*(4*1024*1024+17)
        core.fact('user',large)
        large_op = core.admit()
        view = core.view(large_op)
        last = None
        for kind,ref in view.history():
            if kind=='user': last = ref
        digest = hashlib.sha256()
        for chunk in view.chunks(last): digest.update(chunk)
        assert digest.digest() == hashlib.sha256(large).digest() and view.max_chunk == 4096
        stream = view.chunks(last)
        next(stream)
        rejected(lambda: next(view.chunks(last)),ResourceExceeded)
        stream.close()
        assert not view._reading
        rejected(lambda: value(view,last),ResourceExceeded)
        assert not view._reading
        view.close()
        passed.append('large payload transfer bounded to 4096-byte chunks with complete digest')
        passed.append('overlapping readers and fixture decode exhaustion release resources')

        # Counterexample oracles: an originating-operation cutoff leaks late output;
        # a latest-settings reader rewrites an old operation.
        # first's result is accepted AFTER first admission, so must be absent there.
        assert core.db.execute('SELECT pos FROM result WHERE operation<=?',(first,)).fetchone()
        assert not any(kind=='response' for kind,_ in core.view(first).history())
        assert core.db.execute("SELECT body FROM fact WHERE kind='settings' ORDER BY pos DESC LIMIT 1").fetchone()[0] != core.view(first).settings().key
        passed.append('negative controls detect admission-order leakage and latest-settings lookup')
        core.db.close()
    return {'passed':passed,'count':len(passed),'python':platform.python_version(),
        'sqlite':sqlite3.sqlite_version,'platform':platform.platform(),
        'source_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in HERE.glob('*.py')},
        'limits':['Synthetic one-Session schema; no production integration or live provider calls.',
          'Fresh process reopen is not abrupt-crash or power-loss qualification.',
          'Core chunk transfer tested; JSON adapter limits each decoded object to 64 KiB and accumulates small expected requests.',
          'Provider validation, pending input applicability, full compaction lineage and permission settlement assumed upstream.',
          'Python privacy and handle checks model API discipline, not adversarial isolation.',
          'Explicit reset is a synthetic policy and establishes no Codex reset compatibility.']}


if __name__ == '__main__':
    if len(sys.argv)>1 and sys.argv[1]=='child':
        core = Core(sys.argv[2])
        print(json.dumps(request(core.view(int(sys.argv[3])),sys.argv[4])))
        core.db.close()
    else:
        result = run()
        (HERE/'results.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps(result,indent=2))
