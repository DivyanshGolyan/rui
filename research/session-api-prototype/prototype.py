"""Throwaway protocol experiment. Only synthetic work; no model or tools execute."""
import json, os, sqlite3, subprocess, sys, tempfile
from pathlib import Path

def encode(value): return json.dumps(value, sort_keys=True, separators=(',', ':'))
def connect(path):
    db = sqlite3.connect(path)
    db.execute('PRAGMA synchronous=FULL')
    return db

def submit(path, key, inputs, crash=''):
    db = connect(path)
    db.execute('BEGIN IMMEDIATE')
    row = db.execute('SELECT inputs, answer FROM requests WHERE key=?', (key,)).fetchone()
    if row:
        db.rollback()
        return json.loads(row[1]) if row[0] == encode(inputs) else {'error': 'identity_conflict'}
    session = inputs['session']
    if not db.execute('SELECT 1 FROM sessions WHERE id=?', (session,)).fetchone():
        answer = {'rejected': 'session_missing'}
    else:
        work = db.execute("INSERT INTO work(session,state) VALUES(?,'pending')", (session,)).lastrowid
        answer = {'accepted': work, 'session': session}
    db.execute('INSERT INTO requests VALUES(?,?,?)', (key, encode(inputs), encode(answer)))
    if crash == 'before_commit': os._exit(70)
    db.commit()
    if crash == 'after_commit': os._exit(71)
    return answer

def stop(path, session):
    # Synthetic immediate completion; real stop must await effect-owned cleanup.
    with connect(path) as db:
        db.execute("UPDATE work SET state='stopped' WHERE session=? AND state='pending'", (session,))

def cancel(core, workflow, crash=''):
    with connect(workflow) as db: db.execute("UPDATE run SET state='cancelling'")
    with connect(workflow) as db: calls = db.execute('SELECT key, inputs, answer FROM calls ORDER BY key').fetchall()
    for key, inputs, saved in calls:
        answer = json.loads(saved) if saved else submit(core, key, json.loads(inputs))
        with connect(workflow) as db: db.execute('UPDATE calls SET answer=? WHERE key=?', (encode(answer), key))
        if 'accepted' in answer: stop(core, answer['session'])
    if crash == 'before_cancel_commit': os._exit(72)
    with connect(workflow) as db: db.execute("UPDATE run SET state='cancelled'")

def child(*args):
    return subprocess.run([sys.executable, __file__, *map(str,args)], capture_output=True, text=True)

def main():
    outcomes = []
    with tempfile.TemporaryDirectory(prefix='onepage-protocol-') as temp:
        core, workflow = Path(temp)/'core.sqlite', Path(temp)/'workflow.sqlite'
        with connect(core) as db:
            db.executescript('CREATE TABLE sessions(id TEXT PRIMARY KEY); CREATE TABLE requests(key TEXT PRIMARY KEY,inputs TEXT,answer TEXT); CREATE TABLE work(id INTEGER PRIMARY KEY,session TEXT,state TEXT); INSERT INTO sessions VALUES("A");')
        with connect(workflow) as db:
            db.executescript("CREATE TABLE calls(key TEXT PRIMARY KEY,inputs TEXT,answer TEXT); CREATE TABLE run(state TEXT); INSERT INTO run VALUES('running');")
        request = {'session':'A','message':'review'}
        assert child('submit',core,'rollback',encode(request),'before_commit').returncode == 70
        with connect(core) as db: assert db.execute('SELECT count(*) FROM work').fetchone()[0] == 0
        outcomes.append('Crash before commit: neither admission nor work survives.')
        assert child('submit',core,'direct',encode(request),'after_commit').returncode == 71
        first = json.loads(child('submit',core,'direct',encode(request),'').stdout)
        again = json.loads(child('submit',core,'direct',encode(request),'').stdout)
        assert first == again
        with connect(core) as db: assert db.execute('SELECT count(*) FROM work').fetchone()[0] == 1
        assert submit(core,'direct',dict(request,message='different')) == {'error':'identity_conflict'}
        outcomes.append('Lost committed reply: fresh-process retries return one original work reference; changed inputs conflict.')
        missing = {'session':'B','message':'review'}
        assert submit(core,'rejected',missing) == {'rejected':'session_missing'}
        with connect(core) as db: db.execute('INSERT INTO sessions VALUES("B")')
        assert submit(core,'rejected',missing) == {'rejected':'session_missing'}
        outcomes.append('Committed rejection survives the target becoming valid later.')
        for name in ('delivered','undelivered'):
            with connect(workflow) as db: db.execute('INSERT INTO calls VALUES(?,?,NULL)',(name,encode(request)))
        assert child('submit',core,'delivered',encode(request),'after_commit').returncode == 71
        assert child('cancel',core,workflow,'before_cancel_commit').returncode == 72
        assert child('cancel',core,workflow,'').returncode == 0
        with connect(workflow) as db:
            assert db.execute('SELECT state FROM run').fetchone()[0] == 'cancelled'
            assert db.execute('SELECT count(*) FROM calls WHERE answer IS NULL').fetchone()[0] == 0
        with connect(core) as db:
            assert db.execute('SELECT count(*) FROM work').fetchone()[0] == 3
            assert db.execute("SELECT count(*) FROM work WHERE state!='stopped'").fetchone()[0] == 0
        outcomes.append('Cancellation resolves delivered/lost-reply and never-delivered calls; restart after stops creates no duplicate work.')
        outcomes.append('Session-wide stop also stops direct work on that Session, matching the accepted shared-Session policy.')
    print(json.dumps({'checks':outcomes,'result':'passed','python':sys.version.split()[0],'sqlite':sqlite3.sqlite_version},indent=2))

if __name__ == '__main__':
    if len(sys.argv)==1: main()
    elif sys.argv[1]=='submit': print(encode(submit(sys.argv[2],sys.argv[3],json.loads(sys.argv[4]),sys.argv[5])))
    elif sys.argv[1]=='cancel': cancel(*sys.argv[2:])
