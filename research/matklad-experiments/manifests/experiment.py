#!/usr/bin/env python3
"""SQLite representation experiment; deliberately not a Rui implementation."""
import argparse, hashlib, json, os, sqlite3, subprocess, sys, tempfile, time
from pathlib import Path

WINDOW = 8
HOST = {'user', 'system', 'tool_result'}
SCHEMA = '''
PRAGMA page_size=4096;
PRAGMA journal_mode=WAL;
PRAGMA wal_autocheckpoint=0;
PRAGMA synchronous=FULL;
CREATE TABLE content(id INTEGER PRIMARY KEY, body BLOB NOT NULL, digest TEXT NOT NULL);
CREATE TABLE context_revisions(id INTEGER PRIMARY KEY, instruction INTEGER NOT NULL);
CREATE TABLE operations(id INTEGER PRIMARY KEY, kind TEXT NOT NULL, manifest INTEGER);
CREATE TABLE attempts(id INTEGER PRIMARY KEY, operation INTEGER NOT NULL);
CREATE TABLE completions(id INTEGER PRIMARY KEY, attempt INTEGER NOT NULL UNIQUE);
CREATE TABLE resolutions(id INTEGER PRIMARY KEY, operation INTEGER NOT NULL UNIQUE, completion INTEGER, outcome TEXT NOT NULL);
CREATE TABLE output_items(completion INTEGER NOT NULL, ordinal INTEGER NOT NULL, kind TEXT NOT NULL, content INTEGER NOT NULL, PRIMARY KEY(completion,ordinal));
CREATE TABLE conversation(seq INTEGER PRIMARY KEY, kind TEXT NOT NULL, content INTEGER, resolution INTEGER, item_ordinal INTEGER, tool_parent INTEGER, call_ordinal INTEGER);
CREATE INDEX projections ON conversation(resolution,seq);
CREATE TABLE user_messages(id INTEGER PRIMARY KEY, content INTEGER NOT NULL, projection INTEGER);
CREATE TABLE manifests(id INTEGER PRIMARY KEY, operation INTEGER, revision INTEGER NOT NULL, instruction INTEGER NOT NULL, base INTEGER, frontier INTEGER NOT NULL, item_count INTEGER NOT NULL, recipe_digest TEXT NOT NULL);
CREATE TABLE model_context_items(manifest INTEGER NOT NULL, ordinal INTEGER NOT NULL, kind TEXT NOT NULL, source INTEGER NOT NULL, PRIMARY KEY(manifest,ordinal));
'''

class Rejected(Exception): pass

def rows(db, query, args=()):
    cur = db.execute(query, args)
    while True:
        batch = cur.fetchmany(WINDOW)
        if not batch: return
        yield from batch

def content(db, body):
    if isinstance(body, str): body = body.encode()
    return db.execute('INSERT INTO content(body,digest) VALUES(?,?)', (body, hashlib.sha256(body).hexdigest())).lastrowid

def read_content(db, cid):
    row = db.execute('SELECT body,digest FROM content WHERE id=?', (cid,)).fetchone()
    if row is None or hashlib.sha256(row[0]).hexdigest() != row[1]: raise Rejected('content missing/corrupt')
    return row[0]

def host(db, kind, body, project=True, tool_parent=None, call_ordinal=None):
    cid = content(db, body)
    seq = db.execute('INSERT INTO conversation(kind,content,tool_parent,call_ordinal) VALUES(?,?,?,?)',(kind,cid,tool_parent,call_ordinal)).lastrowid if project else None
    if kind == 'user': db.execute('INSERT INTO user_messages(content,projection) VALUES(?,?)',(cid,seq))
    return seq

def result(db, op, items, outcome='accepted', project=True):
    aid = db.execute('INSERT INTO attempts(operation) VALUES(?)',(op,)).lastrowid
    cid = db.execute('INSERT INTO completions(attempt) VALUES(?)',(aid,)).lastrowid
    rid = db.execute('INSERT INTO resolutions(operation,completion,outcome) VALUES(?,?,?)',(op,cid,outcome)).lastrowid
    for i, (kind, body) in enumerate(items):
        body_id = content(db, body)
        db.execute('INSERT INTO output_items VALUES(?,?,?,?)',(cid,i,kind,body_id))
        if project and outcome == 'accepted' and kind in ('assistant','tool_call'):
            db.execute('INSERT INTO conversation(kind,content,resolution,item_ordinal) VALUES(?,?,?,?)',(kind,body_id,rid,i))
    return rid

def base_start(db, base):
    if base is None: return 0
    row = db.execute('SELECT o.kind,r.outcome,m.frontier FROM resolutions r JOIN operations o ON o.id=r.operation JOIN manifests m ON m.id=o.manifest WHERE r.id=?',(base,)).fetchone()
    if row is None or row[0] != 'compaction' or row[1] != 'accepted': raise Rejected('invalid selected base')
    return row[2]

def sources(db, base, frontier):
    """No new ordered log: use existing Conversation projections as round anchors."""
    lower = base_start(db,base)
    if lower > frontier: raise Rejected('base beyond frontier')
    if base is not None: yield ('base',base)
    previous = None
    for seq, kind, rid in rows(db,'SELECT seq,kind,resolution FROM conversation WHERE seq>? AND seq<=? ORDER BY seq',(lower,frontier)):
        if kind in HOST:
            if rid is not None: raise Rejected('host/provider ownership mismatch')
            previous = None
            yield ('host',seq)
        elif kind in ('assistant','tool_call') and rid is not None:
            lo, hi, count = db.execute('SELECT MIN(seq),MAX(seq),COUNT(*) FROM conversation WHERE resolution=?',(rid,)).fetchone()
            if lo <= lower or hi > frontier or hi-lo+1 != count: raise Rejected('split/disordered model round')
            if rid != previous: yield ('model',rid)
            previous = rid
        else: raise Rejected('unknown conversation kind')

def atom(db, kind, source):
    """Yield bounded output items, preserving opaque private bytes and item order."""
    if kind == 'host':
        r = db.execute('SELECT kind,content,resolution FROM conversation WHERE seq=?',(source,)).fetchone()
        if r is None or r[0] not in HOST or r[2] is not None: raise Rejected('invalid host reference')
        yield ('host',source,r[0],read_content(db,r[1]))
        return
    r = db.execute('SELECT o.kind,r.outcome,r.completion FROM resolutions r JOIN operations o ON o.id=r.operation WHERE r.id=?',(source,)).fetchone()
    if r is None or r[1] != 'accepted': raise Rejected('missing/unaccepted resolution')
    if (kind == 'base') != (r[0] == 'compaction'): raise Rejected('wrong protocol operation')
    semantic = []  # Bound by fixture's two-call output; production must bound catalog/output items.
    seen = 0
    for ordinal, item_kind, cid in rows(db,'SELECT ordinal,kind,content FROM output_items WHERE completion=? ORDER BY ordinal',(r[2],)):
        if ordinal != seen: raise Rejected('output ordinal hole')
        seen += 1
        if item_kind not in ('opaque','assistant','tool_call','compaction'): raise Rejected('unknown consequential output')
        if kind == 'base' and item_kind != 'compaction': raise Rejected('invalid compaction output')
        if kind == 'model' and item_kind == 'compaction': raise Rejected('unexpected compaction')
        if item_kind in ('assistant','tool_call'): semantic.append((ordinal,item_kind,cid))
        yield (kind,source,item_kind,read_content(db,cid))
    if not seen: raise Rejected('missing output')
    if kind == 'model':
        projections = list(rows(db,'SELECT item_ordinal,kind,content FROM conversation WHERE resolution=? ORDER BY seq',(source,)))
        if not semantic or projections != semantic: raise Rejected('missing/misordered semantic anchor')

def digest_part(d, record):
    kind, source, item_kind, body = record
    for b in (kind.encode(),str(source).encode(),item_kind.encode(),body):
        d.update(len(b).to_bytes(8,'big')); d.update(b)

def prepare(db, mode, base=None, operation_kind='model'):
    # No ordering position is invented for accepted ordinary output without a
    # semantic projection. The selected contract must guarantee this anchor.
    if db.execute("SELECT 1 FROM resolutions r JOIN operations o ON o.id=r.operation WHERE o.kind='model' AND r.outcome='accepted' AND NOT EXISTS (SELECT 1 FROM conversation c WHERE c.resolution=r.id) LIMIT 1").fetchone():
        raise Rejected('unanchored accepted model round')
    revision,instruction = db.execute('SELECT id,instruction FROM context_revisions ORDER BY id DESC LIMIT 1').fetchone()
    frontier = db.execute('SELECT COALESCE(MAX(seq),0) FROM conversation').fetchone()[0]
    for source_kind, source_id in sources(db,base,frontier):
        if source_kind == 'model':
            calls=db.execute("SELECT count(*) FROM output_items i JOIN resolutions r ON r.completion=i.completion WHERE r.id=? AND i.kind='tool_call'",(source_id,)).fetchone()[0]
            received=[x[0] for x in rows(db,'SELECT call_ordinal FROM conversation WHERE tool_parent=? AND seq<=? ORDER BY seq',(source_id,frontier))]
            if received != list(range(calls)): raise Rejected('pending/misordered tool results')
    op = db.execute('INSERT INTO operations(kind) VALUES(?)',(operation_kind,)).lastrowid
    mid = db.execute('INSERT INTO manifests(operation,revision,instruction,base,frontier,item_count,recipe_digest) VALUES(?,?,?,?,?,0,?)',(op,revision,instruction,base,frontier,'')).lastrowid
    db.execute('UPDATE operations SET manifest=? WHERE id=?',(mid,op))
    count,d = 0,hashlib.sha256()
    for kind, source in sources(db,base,frontier):
        for record in atom(db,kind,source): digest_part(d,record)
        if mode == 'enumerated': db.execute('INSERT INTO model_context_items VALUES(?,?,?,?)',(mid,count,kind,source))
        count += 1
    db.execute('UPDATE manifests SET item_count=?,recipe_digest=? WHERE id=?',(count,d.hexdigest(),mid))
    return op,mid

def replay(db, mode, mid):
    m = db.execute('SELECT instruction,base,frontier,item_count,recipe_digest FROM manifests WHERE id=?',(mid,)).fetchone()
    if m is None: raise Rejected('missing manifest')
    out,recipe,count = hashlib.sha256(),hashlib.sha256(),0
    out.update(read_content(db,m[0]))
    selected = ((kind,source) for ordinal,kind,source in rows(db,'SELECT ordinal,kind,source FROM model_context_items WHERE manifest=? ORDER BY ordinal',(mid,))) if mode == 'enumerated' else sources(db,m[1],m[2])
    for kind,source in selected:
        for record in atom(db,kind,source): digest_part(recipe,record); digest_part(out,record)
        count += 1
    if count != m[3] or recipe.hexdigest() != m[4]: raise Rejected('recipe count/order/content changed')
    return out.hexdigest()

def create(path):
    db = sqlite3.connect(path)
    db.executescript(SCHEMA)
    db.execute('INSERT INTO context_revisions(instruction) VALUES(?)',(content(db,'initial immutable system instructions'),))
    db.commit()
    return db

def op(db, kind='model'):
    return db.execute('INSERT INTO operations(kind) VALUES(?)',(kind,)).lastrowid

def fixture(path, mode):
    db = create(path)
    host(db,'user','first user')
    a,m1=prepare(db,mode)
    r1=result(db,a,[('opaque',b'\x00private-encrypted-\xff'),('tool_call','call0'),('tool_call','call1')])
    try:
        prepare(db,mode)
        raise AssertionError('admitted while tools pending')
    except Rejected as e:
        assert str(e)=='pending/misordered tool results'
    # Physical completion order reverses; Conversation order remains call order.
    a0,a1=op(db,'action'),op(db,'action')
    result(db,a1,[('assistant','second tool finished first')],project=False)
    result(db,a0,[('assistant','first tool finished second')],project=False)
    host(db,'tool_result','call0=result0',tool_parent=r1,call_ordinal=0); host(db,'tool_result','call1=result1',tool_parent=r1,call_ordinal=1)
    host(db,'user','pending during model',project=False)
    host(db,'system','appended instruction')
    assert list(sources(db,None,6)) == [('host',1),('model',r1),('host',4),('host',5),('host',6)]
    db.execute('UPDATE conversation SET call_ordinal=7 WHERE seq=4')
    try:
        prepare(db,mode)
        raise AssertionError('admitted with disordered tool results')
    except Rejected as e:
        assert str(e)=='pending/misordered tool results'
    db.execute('UPDATE conversation SET call_ordinal=0 WHERE seq=4')
    b,m2=prepare(db,mode)
    result(db,b,[('opaque','private round2'),('assistant','answer round2')])
    # Failed/interrupted/unresolved model effects supply no accepted replay round.
    result(db,op(db),[('opaque','failed bytes')],outcome='failed',project=False)
    db.execute('INSERT INTO resolutions(operation,outcome) VALUES(?,?)',(op(db),'interrupted'))
    db.execute('INSERT INTO attempts(operation) VALUES(?)',(op(db),))
    c,mc=prepare(db,mode,operation_kind='compaction')
    base=result(db,c,[('compaction','opaque compacted base')],project=False)
    host(db,'user','after compaction')
    d,m3=prepare(db,mode,base)
    result(db,d,[('opaque','new private bytes'),('assistant','postcompact answer')])
    db.commit()
    ids=[m1,m2,mc,m3]
    assert list(sources(db,base,8)) == [('base',base),('host',8)]
    before=[replay(db,mode,x) for x in ids]
    # Later ambient configuration/input/result must not alter old requests.
    db.execute('INSERT INTO context_revisions(instruction) VALUES(?)',(content(db,'changed future config'),))
    host(db,'system','later system'); host(db,'user','later input')
    e,m4=prepare(db,mode,base)
    result(db,e,[('assistant','future model response')])
    db.commit()
    after=[replay(db,mode,x) for x in ids]
    assert before == after
    db.execute('SAVEPOINT unanchored')
    result(db,op(db),[('opaque','unanchored private-only ordinary success')],project=False)
    try:
        prepare(db,mode,base)
        raise AssertionError('silently omitted unanchored success')
    except Rejected as e:
        assert str(e)=='unanchored accepted model round'
    db.execute('ROLLBACK TO unanchored'); db.execute('RELEASE unanchored')
    db.execute('PRAGMA wal_checkpoint(TRUNCATE)'); db.close()
    raw=subprocess.check_output([sys.executable,__file__,'--read',str(path),'--mode',mode,'--ids',','.join(map(str,ids))],text=True)
    reopened=json.loads(raw)
    assert reopened == before
    return {'ids':ids,'before':before,'after_later_changes':after,'fresh_process':reopened,'target_prebase':m2,'target_base':m3,'first_resolution':r1,'base':base,'admission_rejections':['pending tool results','misordered tool results','unanchored accepted ordinary output'],'asserted_exact_recipe_sources':True}

def adversarial(path,mode,meta):
    mutations={
      'host_hole':("DELETE FROM conversation WHERE seq=1",meta['target_prebase']),
      'host_order_content_swap':("UPDATE conversation SET content=(SELECT content FROM conversation WHERE seq=5) WHERE seq=4",meta['target_prebase']),
      'payload_corruption':("UPDATE content SET body=X'626164' WHERE id=(SELECT content FROM output_items WHERE kind='opaque' LIMIT 1)",meta['target_prebase']),
      'opaque_ordinal_hole':("DELETE FROM output_items WHERE kind='opaque' AND completion=(SELECT completion FROM resolutions WHERE id=1)",meta['target_prebase']),
      'unknown_output_kind':("UPDATE output_items SET kind='unknown' WHERE kind='opaque' AND completion=(SELECT completion FROM resolutions WHERE id=1)",meta['target_prebase']),
      'missing_resolution':("DELETE FROM resolutions WHERE id=1",meta['target_prebase']),
      'missing_semantic_projection':("DELETE FROM conversation WHERE seq=2",meta['target_prebase']),
      'reversed_tool_call_projections':("UPDATE conversation SET item_ordinal=9 WHERE seq=2",meta['target_prebase']),
      'invalid_selected_compaction':(f"UPDATE resolutions SET outcome='failed' WHERE id={meta['base']}",meta['target_base']),
      'selected_base_payload_corrupt':(f"UPDATE content SET body=X'626164' WHERE id=(SELECT content FROM output_items WHERE completion=(SELECT completion FROM resolutions WHERE id={meta['base']}))",meta['target_base']),
      'split_round_frontier':("UPDATE manifests SET frontier=2 WHERE id=2",meta['target_prebase']),
    }
    answers={}
    for name,(sql,mid) in mutations.items():
        db=sqlite3.connect(path)
        db.execute('BEGIN'); db.execute(sql)
        try:
            replay(db,mode,mid)
            answers[name]='accepted'
        except Rejected as e: answers[name]='rejected: '+str(e)
        finally: db.rollback(); db.close()
    # Enumerator does not consume frontier metadata; its exact explicit recipe
    # is unchanged by that mutation. Range must reject its selected split.
    assert all(v.startswith('rejected') for k,v in answers.items() if k!='split_round_frontier')
    assert mode != 'range' or answers['split_round_frontier'].startswith('rejected')
    return answers

def benchmark(path,mode,n,compact_every):
    db=create(path)
    base=None; admission_ns=0; final=None; max_atoms=0
    start=time.perf_counter_ns()
    for i in range(n):
        host(db,'user',f'user-{i:06d}')
        t=time.perf_counter_ns(); a,mid=prepare(db,mode,base); db.commit(); admission_ns+=time.perf_counter_ns()-t
        result(db,a,[('opaque',f'opaque-{i:06d}'),('assistant',f'answer-{i:06d}')]); db.commit()
        final=mid
        max_atoms=max(max_atoms,db.execute('SELECT item_count FROM manifests WHERE id=?',(mid,)).fetchone()[0])
        if compact_every and (i+1)%compact_every==0:
            t=time.perf_counter_ns(); c,cm=prepare(db,mode,base,'compaction'); db.commit(); admission_ns+=time.perf_counter_ns()-t
            base=result(db,c,[('compaction',f'compact-{i:06d}')],project=False); db.commit()
    build_ns=time.perf_counter_ns()-start
    wal=Path(str(path)+'-wal').stat().st_size
    context_rows=db.execute('SELECT count(*) FROM model_context_items').fetchone()[0]
    statements=[0]
    def trace(s): statements[0]+=1
    db.set_trace_callback(trace)
    t=time.perf_counter_ns(); digest=replay(db,mode,final); replay_ns=time.perf_counter_ns()-t
    db.set_trace_callback(None)
    pages=db.execute('PRAGMA page_count').fetchone()[0]
    db.execute('PRAGMA wal_checkpoint(TRUNCATE)'); db.close()
    return {'mode':mode,'n_requests':n,'compact_every':compact_every,'db_bytes':path.stat().st_size,'sqlite_pages':pages,'wal_bytes_before_checkpoint':wal,'wal_frame_write_proxy':max(0,(wal-32)//4120),'context_reference_rows':context_rows,'admission_ms':admission_ns/1e6,'build_ms':build_ns/1e6,'last_replay_ms':replay_ns/1e6,'last_replay_sql_statements':statements[0],'max_recipe_atoms':max_atoms,'cursor_batch_rows':WINDOW,'last_replay_digest':digest}

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--read'); ap.add_argument('--mode'); ap.add_argument('--ids'); ap.add_argument('--output',default='raw.json'); ap.add_argument('--semantics-only',action='store_true'); args=ap.parse_args()
    if args.read:
        db=sqlite3.connect(args.read); print(json.dumps([replay(db,args.mode,int(i)) for i in args.ids.split(',')])); return
    output={'description':'Exploratory Python/SQLite representation experiment; no production guarantee','sqlite_version':sqlite3.sqlite_version,'python':sys.version,'cursor_batch_rows':WINDOW,'semantics':{},'measurements':[]}
    with tempfile.TemporaryDirectory(prefix='rui-manifests-') as temp:
        temp=Path(temp)
        for mode in ('enumerated','range'):
            p=temp/(mode+'.sqlite'); meta=fixture(p,mode)
            output['semantics'][mode]={'fixture':meta,'adversarial':adversarial(p,mode,meta)}
        assert output['semantics']['enumerated']['fixture']['before']==output['semantics']['range']['fixture']['before']
        if not args.semantics_only:
            for compaction in (0,16):
                for n in (32,64,128,256):
                    for mode in ('enumerated','range'):
                        p=temp/f'{mode}-{n}-{compaction}.sqlite'
                        result_=benchmark(p,mode,n,compaction)
                        output['measurements'].append(result_)
                        print(json.dumps(result_),file=sys.stderr,flush=True)
                        p.unlink()
            for i in range(0,len(output['measurements']),2):
                assert output['measurements'][i]['last_replay_digest']==output['measurements'][i+1]['last_replay_digest']
    Path(args.output).write_text(json.dumps(output,indent=2)+'\n')

if __name__=='__main__': main()
