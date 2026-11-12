"""Disposable SQLite model of a core-owned historical reader, not production code."""
import hashlib
import json
import sqlite3
from dataclasses import dataclass


class Unavailable(Exception):
    pass


class ResourceExceeded(Exception):
    pass


@dataclass(frozen=True)
class Ref:
    scope: object
    key: int
    kind: str


class Core:
    def __init__(self, path):
        self.db = sqlite3.connect(path)
        self.db.executescript('''
          CREATE TABLE IF NOT EXISTS clock(n INTEGER NOT NULL);
          INSERT INTO clock SELECT 0 WHERE NOT EXISTS(SELECT 1 FROM clock);
          CREATE TABLE IF NOT EXISTS payload(id INTEGER PRIMARY KEY, body BLOB, digest TEXT);
          CREATE TABLE IF NOT EXISTS fact(pos INTEGER PRIMARY KEY, kind TEXT, body INTEGER);
          CREATE TABLE IF NOT EXISTS operation(pos INTEGER PRIMARY KEY);
          CREATE TABLE IF NOT EXISTS result(pos INTEGER PRIMARY KEY, operation INTEGER UNIQUE,
            kind TEXT, anchor INTEGER);
          CREATE TABLE IF NOT EXISTS item(id INTEGER PRIMARY KEY, result INTEGER,
            ordinal INTEGER, body INTEGER, UNIQUE(result, ordinal));
          CREATE TABLE IF NOT EXISTS tool(pos INTEGER PRIMARY KEY, call TEXT UNIQUE, body INTEGER);
          CREATE TABLE IF NOT EXISTS call(result INTEGER, ordinal INTEGER, name TEXT,
            PRIMARY KEY(result,ordinal));
          CREATE INDEX IF NOT EXISTS fact_kind_position ON fact(kind,pos);
        ''')

    def tick(self):
        self.db.execute('UPDATE clock SET n=n+1')
        return self.db.execute('SELECT n FROM clock').fetchone()[0]

    def payload(self, value):
        body = value if isinstance(value, bytes) else json.dumps(value).encode()
        return self.db.execute('INSERT INTO payload(body,digest) VALUES (?,?)',
            (body, hashlib.sha256(body).hexdigest())).lastrowid

    def fact(self, kind, value):
        assert kind in ('settings', 'user', 'instruction')
        with self.db:
            pos = self.tick()
            self.db.execute('INSERT INTO fact VALUES (?,?,?)', (pos, kind, self.payload(value)))
        return pos

    def admit(self):
        with self.db:
            pos = self.tick()
            self.db.execute('INSERT INTO operation VALUES (?)', (pos,))
        return pos

    def accept(self, operation, items, kind='response', anchor=None):
        assert kind in ('response', 'compaction')
        assert (kind == 'compaction') == (anchor is not None)
        assert anchor is None or 0 <= anchor < len(items)
        with self.db:
            assert self.db.execute('SELECT 1 FROM operation WHERE pos=?', (operation,)).fetchone()
            pos = self.tick()
            self.db.execute('INSERT INTO result VALUES (?,?,?,?)', (pos, operation, kind, anchor))
            for ordinal, value in enumerate(items):
                self.db.execute('INSERT INTO item(result,ordinal,body) VALUES (?,?,?)',
                    (pos, ordinal, self.payload(value)))
                if isinstance(value,dict) and value.get('type') == 'function_call':
                    self.db.execute('INSERT INTO call VALUES (?,?,?)',(pos,ordinal,value['call_id']))
        return pos

    def tool(self, call, value):
        with self.db:
            pos = self.tick()
            self.db.execute('INSERT INTO tool VALUES (?,?,?)', (pos, call, self.payload(value)))
        return pos

    def view(self, operation, private=True):
        assert self.db.execute('SELECT 1 FROM operation WHERE pos=?', (operation,)).fetchone()
        return View(self.db, operation, private)


class View:
    """Private DB member models an API boundary, not a Python security sandbox.

    One owner drives this view. Queries finish before yielding to the adapter.
    References expire on close. SQLite rows remain immutable during normal use.
    """
    def __init__(self, db, cutoff, private):
        self._db, self._cutoff, self._private = db, cutoff, private
        self._scope, self._closed, self._reading = object(), False, False
        self.max_chunk = 0

    def close(self):
        assert not self._reading
        self._closed = True

    def _check(self, ref=None):
        assert not self._closed, 'expired view'
        assert ref is None or ref.scope is self._scope, 'foreign view reference'

    def _ref(self, key, kind):
        return Ref(self._scope, key, kind)

    def settings(self):
        self._check()
        row = self._db.execute("SELECT body FROM fact WHERE kind='settings' AND pos<? ORDER BY pos DESC LIMIT 1",
            (self._cutoff,)).fetchone()
        if row is None:
            raise Unavailable('settings')
        return self._ref(row[0], 'public')

    def history(self, compaction=None, suffix=False):
        self._check(compaction)
        previous, cutoff = 0, self._cutoff
        if compaction is not None:
            assert compaction.kind == 'result'
            row = self._db.execute("SELECT operation FROM result WHERE pos=? AND pos<? AND kind='compaction'",
                (compaction.key,self._cutoff)).fetchone()
            if row is None: raise Unavailable('compaction')
            if suffix: previous = row[0]
            else: cutoff = row[0]
        while True:
            self._check()
            row = self._db.execute('''SELECT pos,kind,body FROM fact
                WHERE kind!='settings' AND pos>? AND pos<?
                UNION ALL SELECT pos,kind,pos FROM result WHERE pos>? AND pos<?
                ORDER BY pos LIMIT 1''', (previous,cutoff,previous,cutoff)).fetchone()
            if row is None:
                return
            previous, kind, key = row
            yield kind, self._ref(key, 'result' if kind in ('response','compaction') else 'public')

    def model_output(self, result, from_anchor=False):
        self._check(result)
        assert result.kind == 'result'
        row = self._db.execute('SELECT anchor FROM result WHERE pos=? AND pos<?',
            (result.key,self._cutoff)).fetchone()
        if row is None:
            raise Unavailable('result')
        start = row[0] if from_anchor else 0
        assert start is not None, 'not a compaction result'
        ordinal = start - 1
        while True:
            self._check(result)
            item = self._db.execute('SELECT ordinal,body FROM item WHERE result=? AND ordinal>? ORDER BY ordinal LIMIT 1',
                (result.key,ordinal)).fetchone()
            if item is None:
                return
            ordinal, payload = item
            yield self._ref(payload, 'private')

    def tool_result(self, call):
        self._check()
        row = self._db.execute('SELECT body FROM tool WHERE call=? AND pos<?', (call,self._cutoff)).fetchone()
        return None if row is None else self._ref(row[0], 'public')

    def tool_results(self, result, from_anchor=False):
        """Follow core-owned call relationships without decoding provider payloads."""
        self._check(result)
        assert result.kind == 'result'
        row = self._db.execute('SELECT anchor FROM result WHERE pos=? AND pos<?',
            (result.key,self._cutoff)).fetchone()
        if row is None:
            raise Unavailable('result')
        start = row[0] if from_anchor else 0
        assert start is not None
        ordinal = start-1
        while True:
            self._check(result)
            row = self._db.execute('''SELECT c.ordinal,t.body FROM call c LEFT JOIN tool t
                ON c.name=t.call AND t.pos<? WHERE c.result=? AND c.ordinal>?
                ORDER BY c.ordinal LIMIT 1''',(self._cutoff,result.key,ordinal)).fetchone()
            if row is None:
                return
            ordinal,body = row
            if body is None:
                raise Unavailable('tool result not visible')
            yield self._ref(body,'public')

    def chunks(self, ref, size=4096):
        self._check(ref)
        assert ref.kind in ('public','private')
        assert 0 < size <= 4096
        if ref.kind == 'private' and not self._private:
            raise Unavailable('private content')
        if self._reading:
            raise ResourceExceeded('one payload reader per view')
        self._reading = True
        try:
            row = self._db.execute('SELECT length(body),digest FROM payload WHERE id=?', (ref.key,)).fetchone()
            if row is None:
                raise Unavailable('missing content')
            length, expected = row
            digest = hashlib.sha256()
            for offset in range(0,length,size):
                self._check(ref)
                row = self._db.execute('SELECT substr(body,?,?) FROM payload WHERE id=?',
                    (offset+1,min(size,length-offset),ref.key)).fetchone()
                if row is None or len(row[0]) != min(size,length-offset):
                    raise Unavailable('short read')
                chunk = row[0]
                self.max_chunk = max(self.max_chunk,len(chunk))
                digest.update(chunk)
                yield chunk
            if digest.hexdigest() != expected:
                raise Unavailable('corrupt content')
        finally:
            self._reading = False
