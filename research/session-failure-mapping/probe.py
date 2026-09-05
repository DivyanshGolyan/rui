#!/usr/bin/env python3
"""Prospective SQLite transaction proof; not OnePage's production schema."""
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile

SCHEMA = '''
PRAGMA foreign_keys = ON;
CREATE TABLE sessions(id INTEGER PRIMARY KEY);
CREATE TABLE turns(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL REFERENCES sessions);
CREATE TABLE user_messages(
 id INTEGER PRIMARY KEY, turn_id INTEGER NOT NULL REFERENCES turns,
 ordinal INTEGER NOT NULL, content TEXT NOT NULL, UNIQUE(turn_id, ordinal));
CREATE TABLE conversation_entries(
 ordinal INTEGER PRIMARY KEY, message_id INTEGER NOT NULL UNIQUE REFERENCES user_messages);
CREATE TABLE operations(
 id INTEGER PRIMARY KEY, turn_id INTEGER NOT NULL REFERENCES turns, UNIQUE(turn_id, id));
CREATE TABLE operation_resolutions(
 operation_id INTEGER PRIMARY KEY REFERENCES operations, code TEXT NOT NULL);
CREATE TABLE permission_requests(id INTEGER PRIMARY KEY, turn_id INTEGER NOT NULL REFERENCES turns);
CREATE TABLE permission_decisions(request_id INTEGER PRIMARY KEY REFERENCES permission_requests);
CREATE TABLE turn_outcomes(
 turn_id INTEGER PRIMARY KEY REFERENCES turns,
 kind TEXT NOT NULL CHECK(kind IN ('completed','failed')),
 code TEXT NOT NULL, source_operation_id INTEGER,
 FOREIGN KEY(turn_id, source_operation_id) REFERENCES operations(turn_id, id));
CREATE TRIGGER one_active BEFORE INSERT ON turns WHEN EXISTS(
 SELECT 1 FROM turns t WHERE t.session_id=NEW.session_id
 AND NOT EXISTS(SELECT 1 FROM turn_outcomes o WHERE o.turn_id=t.id))
 BEGIN SELECT RAISE(ABORT, 'session occupied'); END;
CREATE TRIGGER closed_message BEFORE INSERT ON user_messages WHEN EXISTS(
 SELECT 1 FROM turn_outcomes WHERE turn_id=NEW.turn_id)
 BEGIN SELECT RAISE(ABORT, 'turn terminal'); END;
CREATE TRIGGER closed_projection BEFORE INSERT ON conversation_entries WHEN EXISTS(
 SELECT 1 FROM user_messages m JOIN turn_outcomes o ON o.turn_id=m.turn_id
 WHERE m.id=NEW.message_id)
 BEGIN SELECT RAISE(ABORT, 'turn terminal'); END;
CREATE TRIGGER closed_operation BEFORE INSERT ON operations WHEN EXISTS(
 SELECT 1 FROM turn_outcomes WHERE turn_id=NEW.turn_id)
 BEGIN SELECT RAISE(ABORT, 'turn terminal'); END;
CREATE TRIGGER unresolved_operation BEFORE INSERT ON turn_outcomes WHEN EXISTS(
 SELECT 1 FROM operations p WHERE p.turn_id=NEW.turn_id AND NOT EXISTS(
 SELECT 1 FROM operation_resolutions r WHERE r.operation_id=p.id))
 BEGIN SELECT RAISE(ABORT, 'operation unresolved'); END;
CREATE TRIGGER actionable_permission BEFORE INSERT ON turn_outcomes WHEN EXISTS(
 SELECT 1 FROM permission_requests p WHERE p.turn_id=NEW.turn_id AND NOT EXISTS(
 SELECT 1 FROM permission_decisions d WHERE d.request_id=p.id))
 BEGIN SELECT RAISE(ABORT, 'permission actionable'); END;
CREATE TRIGGER successful_pending BEFORE INSERT ON turn_outcomes
 WHEN NEW.kind='completed' AND EXISTS(
 SELECT 1 FROM user_messages m WHERE m.turn_id=NEW.turn_id AND NOT EXISTS(
 SELECT 1 FROM conversation_entries c WHERE c.message_id=m.id))
 BEGIN SELECT RAISE(ABORT, 'pending input prevents success'); END;
'''

# Inspection derives the disposition; it stores no per-message status.
INSPECT = '''SELECT m.id, m.content,
 CASE WHEN c.message_id IS NOT NULL THEN 'applied'
      WHEN o.kind='failed' THEN 'not_applied' ELSE 'pending' END,
 CASE WHEN c.message_id IS NULL AND o.kind='failed' THEN o.code END
 FROM user_messages m
 LEFT JOIN conversation_entries c ON c.message_id=m.id
 LEFT JOIN turn_outcomes o ON o.turn_id=m.turn_id
 ORDER BY m.id'''


def open_db(path):
    db = sqlite3.connect(path, isolation_level=None)
    db.execute('PRAGMA foreign_keys=ON')
    return db


def initial(db):
    db.executescript(SCHEMA)
    db.executescript("INSERT INTO sessions VALUES(1); INSERT INTO turns VALUES(1,1);"
                     "INSERT INTO user_messages VALUES(1,1,1,'Review code');"
                     "INSERT INTO conversation_entries VALUES(1,1);")


def message(db, content):
    """Session-current admission; no caller Turn ID or idempotency key."""
    db.execute('BEGIN IMMEDIATE')
    try:
        row = db.execute('''SELECT t.id FROM turns t WHERE session_id=1
            AND NOT EXISTS(SELECT 1 FROM turn_outcomes o WHERE o.turn_id=t.id)''').fetchone()
        if row:
            turn = row[0]
        else:
            turn = db.execute('INSERT INTO turns(session_id) VALUES(1)').lastrowid
        ordinal = db.execute('SELECT COALESCE(MAX(ordinal),0)+1 FROM user_messages WHERE turn_id=?', (turn,)).fetchone()[0]
        mid = db.execute('INSERT INTO user_messages(turn_id,ordinal,content) VALUES(?,?,?)', (turn, ordinal, content)).lastrowid
        if not row:  # Initiating message is projected with new Turn admission.
            db.execute('INSERT INTO conversation_entries(message_id) VALUES(?)', (mid,))
        db.execute('COMMIT')
        return turn, mid
    except Exception:
        db.execute('ROLLBACK')
        raise


def fail(db, turn=1, code='ResourceExceeded', source=None, rollback=False):
    """One bounded semantic mutation; real classifiers validate richer facts."""
    db.execute('BEGIN IMMEDIATE')
    try:
        old = db.execute('SELECT kind,code,source_operation_id FROM turn_outcomes WHERE turn_id=?', (turn,)).fetchone()
        if old:
            if old != ('failed', code, source):
                raise ValueError('conflicting outcome')
            db.execute('COMMIT')
            return old
        if source is None:
            if code != 'ResourceExceeded':
                raise ValueError('unsupported pre-request cause in fixture')
            # Precondition: the caller's bounded preparation classifier has
            # established no fitting request under the bound Turn Contract.
        else:
            # Representative closed case, NOT "every Operation error is fatal".
            row = db.execute('''SELECT r.code FROM operation_resolutions r
                JOIN operations p ON p.id=r.operation_id
                WHERE p.id=? AND p.turn_id=?''', (source, turn)).fetchone()
            if row != ('unsupported_provider_output',) or code != row[0]:
                raise ValueError('resolution does not establish this terminal failure')
        db.execute('INSERT INTO turn_outcomes VALUES(?,?,?,?)', (turn, 'failed', code, source))
        db.execute('ROLLBACK' if rollback else 'COMMIT')
        return ('failed', code, source)
    except Exception:
        if db.in_transaction:
            db.execute('ROLLBACK')
        raise


def rejected(call):
    try:
        call()
    except (sqlite3.IntegrityError, ValueError):
        return
    raise AssertionError('mutation unexpectedly succeeded')


def pending_failure(db, path):
    rejected(lambda: db.execute('INSERT INTO turns VALUES(2,1)'))
    _, mid = message(db, 'Also check security')
    before = db.execute('SELECT * FROM user_messages').fetchall()
    fail(db)
    assert db.execute('SELECT * FROM user_messages').fetchall() == before
    assert db.execute(INSPECT).fetchall()[-1] == (mid, 'Also check security', 'not_applied', 'ResourceExceeded')
    assert db.execute('SELECT COUNT(*) FROM operations').fetchone()[0] == 0
    assert db.execute('SELECT COUNT(*) FROM operation_resolutions').fetchone()[0] == 0
    turn, newmid = message(db, 'Continue with a different task')
    assert turn == 2
    assert db.execute('SELECT message_id FROM conversation_entries ORDER BY ordinal').fetchall() == [(1,), (newmid,)]
    rejected(lambda: db.execute('INSERT INTO conversation_entries(message_id) VALUES(?)', (mid,)))
    rejected(lambda: db.execute("INSERT INTO user_messages(turn_id,ordinal,content) VALUES(1,3,'stale')"))
    rejected(lambda: db.execute('INSERT INTO operations VALUES(9,1)'))


def failure_wins(db, path):
    fail(db)
    turn, mid = message(db, 'Also check security')
    assert turn == 2
    assert db.execute(INSPECT).fetchall()[-1] == (mid, 'Also check security', 'applied', None)


def operation_obligation(db, path):
    message(db, 'Also check security')
    db.execute('INSERT INTO operations VALUES(1,1)')
    rejected(lambda: fail(db))
    assert db.execute(INSPECT).fetchall()[-1][2] == 'pending'
    db.execute("INSERT INTO operation_resolutions VALUES(1,'unsupported_provider_output')")
    fail(db, code='unsupported_provider_output', source=1)
    rejected(lambda: db.execute("INSERT INTO operation_resolutions VALUES(1,'success')"))


def nonterminal_errors(db, path):
    for op, code in [(1, 'tool_error'), (2, 'context_overflow')]:
        db.execute('INSERT INTO operations VALUES(?,1)', (op,))
        db.execute('INSERT INTO operation_resolutions VALUES(?,?)', (op, code))
        rejected(lambda: fail(db, code=code, source=op))
    assert db.execute('SELECT COUNT(*) FROM turn_outcomes').fetchone()[0] == 0


def permissions(db, path):
    message(db, 'Also check security')
    db.execute('INSERT INTO permission_requests VALUES(1,1)')
    rejected(lambda: fail(db))
    db.execute('INSERT INTO permission_decisions VALUES(1)')
    fail(db)


def rollback(db, path):
    message(db, 'Also check security')
    fail(db, rollback=True)
    assert db.execute(INSPECT).fetchall()[-1][2] == 'pending'
    other = open_db(path)
    try:
        assert other.execute('SELECT COUNT(*) FROM turn_outcomes').fetchone()[0] == 0
        assert other.execute(INSPECT).fetchall()[-1][2] == 'pending'
    finally:
        other.close()


def lost_ack(db, path):
    message(db, 'Also check security')
    fail(db)  # Commit succeeds; no response is delivered to the observer.
    other = open_db(path)
    try:
        assert fail(other) == ('failed', 'ResourceExceeded', None)
        assert other.execute('SELECT COUNT(*) FROM turn_outcomes').fetchone()[0] == 1
        assert other.execute(INSPECT).fetchall()[-1][2] == 'not_applied'
        rejected(lambda: fail(other, code='different'))
    finally:
        other.close()


def success_pending(db, path):
    message(db, 'Also check security')
    rejected(lambda: db.execute("INSERT INTO turn_outcomes VALUES(1,'completed','FinalAnswer',NULL)"))
    assert db.execute(INSPECT).fetchall()[-1][2] == 'pending'


def main():
    cases = [pending_failure, failure_wins, operation_obligation,
             nonterminal_errors, permissions, rollback, lost_ack, success_pending]
    result = {'sqlite_version': sqlite3.sqlite_version,
              'source_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'scope': 'prospective fixture; not production schema or power-loss test',
              'cases': []}
    for case in cases:
        with tempfile.TemporaryDirectory(prefix='onepage-failure-sql-') as tmp:
            path = Path(tmp) / 'store.sqlite'
            db = open_db(path)
            try:
                initial(db)
                case(db, path)
            finally:
                db.close()
        result['cases'].append({'name': case.__name__, 'passed': True})
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
