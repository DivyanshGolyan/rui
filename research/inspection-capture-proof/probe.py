"""Synthetic SQLite isolation proof; not a OnePage performance benchmark."""
import json
import pathlib
import sqlite3
import tempfile
import time

ROWS = 10000
BATCH = 100

with tempfile.TemporaryDirectory(prefix="onepage-inspect-") as root:
    db = pathlib.Path(root) / "probe.db"
    w = sqlite3.connect(db, isolation_level=None)
    assert w.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
    w.execute("PRAGMA synchronous=FULL")
    w.execute("CREATE TABLE head(revision INTEGER NOT NULL)")
    w.execute("INSERT INTO head VALUES(0)")
    w.execute("CREATE TABLE members(id INTEGER PRIMARY KEY, generation INTEGER NOT NULL)")
    w.execute("BEGIN")
    w.executemany("INSERT INTO members VALUES(?,0)", ((i,) for i in range(1,ROWS+1)))
    w.execute("COMMIT")
    r = sqlite3.connect(f"file:{db}?mode=ro", uri=True, isolation_level=None)

    def reset():
        assert not r.in_transaction
        w.execute("BEGIN")
        w.execute("UPDATE members SET generation=0")
        w.execute("UPDATE head SET revision=0")
        w.execute("COMMIT")
        assert w.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone() == (0,0,0)

    def mutate(start):
        w.execute("BEGIN")
        w.execute("UPDATE members SET generation=1 WHERE id BETWEEN ? AND ?", (start,start+BATCH-1))
        w.execute("UPDATE head SET revision=revision+1")
        w.execute("COMMIT")

    results = {"sqlite_version": sqlite3.sqlite_version, "rows": ROWS, "batch": BATCH,
               "process_threads_used": 1, "sqlite_connections": 2}

    reset()
    invalidated = 0
    for _ in range(20):
        rev = r.execute("SELECT revision FROM head").fetchone()[0]
        first = r.execute("SELECT id,generation FROM members ORDER BY id LIMIT ?", (BATCH,)).fetchall()
        assert len(first) == BATCH
        mutate(BATCH+1)
        if r.execute("SELECT revision FROM head").fetchone()[0] != rev:
            invalidated += 1
    assert invalidated == 20
    results["guarded_scans"] = {"attempts": 20, "invalidated": invalidated,
        "workload": "one deliberate concurrent commit between first and second scan batches"}

    reset()
    seen = set()
    for last in range(0, ROWS, BATCH):
        batch = r.execute("SELECT id,generation FROM members WHERE id>? ORDER BY id LIMIT ?", (last,BATCH)).fetchall()
        seen.update(row[1] for row in batch)
        mutate(last+BATCH+1)
    assert seen == {0,1}
    results["unguarded_scan"] = {"observed_generations": sorted(seen), "consistent": False}

    reset()
    with tempfile.TemporaryFile() as report:
        started = time.monotonic()
        r.execute("BEGIN")
        rev = r.execute("SELECT revision FROM head").fetchone()[0]
        assert rev == 0
        report.write(json.dumps({"type":"start", "revision":str(rev)}).encode()+b"\n")
        rows = 0
        for last in range(0, ROWS, BATCH):
            batch = r.execute("SELECT id,generation FROM members WHERE id>? ORDER BY id LIMIT ?", (last,BATCH)).fetchall()
            for ident,generation in batch:
                assert generation == 0
                report.write(json.dumps({"type":"member", "id":str(ident), "generation":str(generation)}).encode()+b"\n")
                rows += 1
            mutate(last+BATCH+1)
        assert rows == ROWS
        assert r.execute("SELECT revision FROM head").fetchone()[0] == 0
        concurrent_commits = w.execute("SELECT revision FROM head").fetchone()[0]
        checkpoint_during = w.execute("PRAGMA wal_checkpoint(PASSIVE)").fetchone()
        wal_bytes = pathlib.Path(str(db)+"-wal").stat().st_size
        r.execute("COMMIT")
        report.write(json.dumps({"type":"end", "revision":"0", "members":str(rows)}).encode()+b"\n")
        report.flush()
        capture_seconds = time.monotonic()-started
        checkpoint_after = w.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
        assert checkpoint_after == (0,0,0)
        report_size = report.tell()
        report.seek(0)
        drained = 0
        drain_commits = 0
        while chunk := report.read(8192):
            drained += len(chunk)
            mutate(1)
            assert not r.in_transaction
            assert w.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone() == (0,0,0)
            drain_commits += 1
            time.sleep(.002)  # Synthetic slow delivery; no actual HTTP socket.
        assert drained == report_size
        results["captured_scan"] = {
            "snapshot_revision":0, "members":rows, "all_generations":0,
            "writer_commits_during_capture":concurrent_commits,
            "capture_seconds_observed":capture_seconds, "report_bytes":report_size,
            "wal_bytes_during_capture":wal_bytes,
            "checkpoint_during_busy_log_checkpointed":checkpoint_during,
            "checkpoint_after_busy_log_checkpointed":checkpoint_after,
            "writer_commits_during_slow_drain":drain_commits,
            "every_drain_checkpoint_truncated":True,
            "database_transaction_during_slow_drain":False,
        }
    r.close(); w.close()
    print(json.dumps(results,indent=2))
