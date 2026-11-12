"""Candidate relational model checks; not the production evaluator or crash harness."""
import json, sqlite3, tempfile
from pathlib import Path

checks = []
views = {}
with tempfile.TemporaryDirectory(prefix='rui-generation-model-') as root:
    path = str(Path(root) / 'model.db')
    db = sqlite3.connect(path)
    db.executescript('''
      PRAGMA foreign_keys=ON;
      CREATE TABLE run(id INTEGER PRIMARY KEY, active INTEGER, published INTEGER, cancelled INTEGER NOT NULL DEFAULT 0, terminal INTEGER NOT NULL DEFAULT 0);
      INSERT INTO run(id) VALUES(1);
      CREATE TABLE generation(n INTEGER PRIMARY KEY);
      CREATE TABLE result_owner(id TEXT PRIMARY KEY, result_json TEXT);
      CREATE TABLE call_binding(key TEXT PRIMARY KEY, kind TEXT NOT NULL, input TEXT NOT NULL,
        owner TEXT NOT NULL REFERENCES result_owner(id));
      CREATE TABLE pending(key TEXT PRIMARY KEY REFERENCES call_binding(key));
    ''')
    def owner(name, result=None):
        db.execute('INSERT INTO result_owner VALUES(?,?)', (name,result)); db.commit()
    def bind(key, kind, payload, target):
        active,cancelled=db.execute('SELECT active,cancelled FROM run').fetchone()
        assert active is not None and not cancelled
        row=db.execute('SELECT kind,input,owner FROM call_binding WHERE key=?',(key,)).fetchone()
        if row is not None:
            assert row == (kind,payload,target), 'binding conflict'
            return
        db.execute('INSERT INTO call_binding VALUES(?,?,?,?)',(key,kind,payload,target));db.commit()
    def finish(name, result):
        old=db.execute('SELECT result_json FROM result_owner WHERE id=?',(name,)).fetchone()[0]
        assert old is None or old == result, 'immutable result conflict'
        db.execute('UPDATE result_owner SET result_json=? WHERE id=?',(result,name));db.commit()
    def visible(g):
        return views[g]
    def admit(fail=False, recovering=False):
        db.execute('BEGIN')
        try:
            active,cancelled,terminal=db.execute('SELECT active,cancelled,terminal FROM run').fetchone()
            assert not cancelled and not terminal
            assert (recovering and active is not None) or (active is None and eligible())
            g=db.execute('SELECT coalesce(max(n),0)+1 FROM generation').fetchone()[0]
            db.execute('INSERT INTO generation VALUES(?)',(g,))
            view=dict(db.execute("SELECT c.key,r.result_json FROM call_binding c JOIN result_owner r ON r.id=c.owner WHERE r.result_json IS NOT NULL"))
            db.execute('UPDATE run SET active=?',(g,))
            if fail: raise RuntimeError('injected rollback')
            db.commit();views[g]=view;return g
        except BaseException:
            db.rollback();raise
    def publish(g, pending):
        db.execute('BEGIN')
        try:
            assert db.execute('SELECT active,cancelled FROM run').fetchone() == (g,0)
            assert not set(pending).intersection(visible(g)), 'pending must reflect admitted view'
            db.execute('DELETE FROM pending')
            db.executemany('INSERT INTO pending VALUES(?)',((key,) for key in pending))
            db.execute('UPDATE run SET published=?,active=NULL',(g,));db.commit()
        except BaseException:
            db.rollback();raise
    def eligible():
        return db.execute('''SELECT NOT cancelled AND NOT terminal AND active IS NULL AND
          (published IS NULL OR EXISTS(SELECT 1 FROM pending p JOIN call_binding c ON c.key=p.key
           JOIN result_owner r ON r.id=c.owner WHERE r.result_json IS NOT NULL)) FROM run''').fetchone()[0] == 1

    owner('A'); owner('B');assert eligible();g1=admit();assert not visible(g1)
    bind('A','message','scan A','A');bind('B','message','scan B','B')
    publish(g1,['A','B']);assert not eligible()
    finish('A','{"findings":[1,2]}');assert eligible();g2=admit();assert set(visible(g2))=={'A'}
    checks.append('new result enables a generation without waiting for unrelated B')
    owner('V');bind('V','message','verify finding 1','V');finish('B','"B answer"');finish('V','null')
    owner('created-session','"session-C"');bind('create-C','create','baseline','created-session')
    bind('second-A','message','second input bound to A','A')
    assert set(visible(g2))=={'A'}
    checks.append('live view remains fixed despite concurrent completions and new call bindings')
    db.close();views.clear();db=sqlite3.connect(path);db.execute('PRAGMA foreign_keys=ON')
    try: admit(fail=True,recovering=True)
    except RuntimeError: pass
    assert db.execute('SELECT active FROM run').fetchone()[0]==g2
    checks.append('replacement rollback leaves interrupted generation discoverable')
    g3=admit(recovering=True)
    assert set(visible(g3))=={'A','B','V','create-C','second-A'}
    assert visible(g3)['V']=='null'
    checks.append('fresh connection recovery captures newer results without historical visibility markers')
    bind('V','message','verify finding 1','V')
    assert db.execute("SELECT count(*) FROM call_binding WHERE key='V'").fetchone()[0]==1
    try: bind('V','message','changed input','V')
    except AssertionError: pass
    else: raise AssertionError('changed binding accepted')
    checks.append('partially admitted equal keyed operation is reused; changed input conflicts')
    try: publish(g2,[])
    except AssertionError: pass
    else: raise AssertionError('abandoned generation published')
    checks.append('replacement generation fences abandoned publication')
    owner('failure');bind('F','message','failing work','failure')
    finish('failure','{"failure":"cancelled"}')
    assert 'F' not in visible(g3)
    publish(g3,['F']);assert eligible()
    g4=admit();assert 'F' in visible(g4);publish(g4,[]);assert not eligible()
    checks.append('publication catches concurrently finished dependencies; considered results do not retrigger')
    checks.append('successful null, stable failure and missing result are distinct')
    # Simulate an interrupted generation with only unresolved work and no new result.
    db.execute('UPDATE run SET published=NULL');db.commit()
    g5=admit();owner('waiting');bind('W','message','waiting','waiting')
    db.close();views.clear();db=sqlite3.connect(path);db.execute('PRAGMA foreign_keys=ON')
    g6=admit(recovering=True);assert g6>g5 and 'W' not in visible(g6)
    checks.append('interruption permits fresh evaluation without a newly completed dependency')
    db.execute('UPDATE run SET cancelled=1');db.commit();assert not eligible()
    try: admit(recovering=True)
    except AssertionError: pass
    else: raise AssertionError('cancelled Run admitted')
    try: publish(g6,['W'])
    except AssertionError: pass
    else: raise AssertionError('cancelled Run published')
    db.execute('UPDATE run SET cancelled=0,terminal=1');db.commit();assert not eligible()
    try: admit(recovering=True)
    except AssertionError: pass
    else: raise AssertionError('terminal Run admitted')
    checks.append('cancellation and terminality fence replacement admission')
    db.close()
print(json.dumps({'scope':'abstract relational model, not production JS or crash qualification',
                  'sqlite':sqlite3.sqlite_version,'passed':checks},indent=2))
