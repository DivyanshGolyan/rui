// Throwaway query-shape evidence, not OnePage's schema, classifier or wire API.
// All unadmitted unresolved fixture Operations are executable sibling Actions
// unless waiting on their exact Permission Request. Broader sequencing is absent.
#include "sqlite3.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static sqlite3 *db;
static void sql(const char *s) {
    char *error = NULL;
    if (sqlite3_exec(db, s, NULL, NULL, &error) != SQLITE_OK) {
        fprintf(stderr, "%s: %s\n", s, error); exit(2);
    }
}
static sqlite3_stmt *prepare(const char *s) {
    sqlite3_stmt *q = NULL;
    if (sqlite3_prepare_v2(db, s, -1, &q, NULL) != SQLITE_OK) {
        fprintf(stderr, "%s: %s\n", s, sqlite3_errmsg(db)); exit(2);
    }
    return q;
}
static double now(void) {
    struct timespec t; assert(clock_gettime(CLOCK_MONOTONIC, &t) == 0);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static void open_db(const char *path) {
    assert(sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE |
        SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_PRIVATECACHE, NULL) == SQLITE_OK);
    sql("PRAGMA page_size=4096; PRAGMA journal_mode=DELETE; PRAGMA synchronous=EXTRA;"
        "PRAGMA foreign_keys=ON; PRAGMA busy_timeout=0; PRAGMA mmap_size=0;"
        "PRAGMA temp_store=FILE; PRAGMA trusted_schema=OFF; PRAGMA cache_size=-64;"
        "PRAGMA cache_spill=ON;");
}
static void done(sqlite3_stmt *q) {
    assert(sqlite3_step(q) == SQLITE_DONE);
    assert(sqlite3_reset(q) == SQLITE_OK);
    assert(sqlite3_clear_bindings(q) == SQLITE_OK);
}
static const char *conditions[] = {"runnable", "waiting_for_permission", "in_flight",
    "completed", "failed", "cancelled", "in_flight", "runnable", "runnable"};

static void seed(long members, long history, long unrelated, long fanout, int payload, int live_index) {
    sql("CREATE TABLE run(id INTEGER PRIMARY KEY,revision INTEGER NOT NULL);"
        "INSERT INTO run VALUES(1,0),(2,0);"
        "CREATE TABLE turn(id INTEGER PRIMARY KEY,session_id INTEGER NOT NULL,outcome TEXT,answer_ref INTEGER);"
        "CREATE TABLE member(run_id INTEGER NOT NULL REFERENCES run,turn_id INTEGER NOT NULL REFERENCES turn,"
        "PRIMARY KEY(run_id,turn_id)) WITHOUT ROWID;"
        "CREATE TABLE content(id INTEGER PRIMARY KEY,body BLOB NOT NULL);"
        "CREATE TABLE operation(id INTEGER PRIMARY KEY,turn_id INTEGER NOT NULL REFERENCES turn,"
        "resolution TEXT,attempt_id INTEGER,retry_due INTEGER,result_ref INTEGER REFERENCES content);"
        "CREATE INDEX operation_by_turn ON operation(turn_id,id);"
        "CREATE TABLE permission_request(id INTEGER PRIMARY KEY,operation_id INTEGER NOT NULL UNIQUE REFERENCES operation,"
        "descriptor_ref INTEGER NOT NULL);"
        "CREATE TABLE permission_decision(request_id INTEGER PRIMARY KEY REFERENCES permission_request,allow INTEGER NOT NULL);"
        "BEGIN IMMEDIATE;");
    sqlite3_stmt *t = prepare("INSERT INTO turn VALUES(?1,?1,?2,?3)");
    sqlite3_stmt *m = prepare("INSERT INTO member VALUES(?1,?2)");
    sqlite3_stmt *o = prepare("INSERT INTO operation VALUES(?1,?2,?3,?4,?5,?6)");
    sqlite3_stmt *c = prepare("INSERT INTO content VALUES(?1,zeroblob(?2))");
    sqlite3_stmt *p = prepare("INSERT INTO permission_request VALUES(?1,?1,?1)");
    sqlite3_stmt *d = prepare("INSERT INTO permission_decision VALUES(?1,?2)");
    long op = 0;
    for (long id = 1; id <= members + unrelated; id++) {
        int kind = (int)((id - 1) % 9);
        sqlite3_bind_int64(t, 1, id);
        if (kind >= 3 && kind <= 5) {
            sqlite3_bind_text(t, 2, conditions[kind], -1, SQLITE_STATIC);
            sqlite3_bind_int64(t, 3, id);
        }
        done(t);
        sqlite3_bind_int(m, 1, id <= members ? 1 : 2);
        sqlite3_bind_int64(m, 2, id); done(m);
        long old = id <= members ? history : 1;
        for (long h = 0; h < old; h++) {
            ++op;
            sqlite3_bind_int64(c, 1, op); sqlite3_bind_int(c, 2, payload); done(c);
            sqlite3_bind_int64(o, 1, op); sqlite3_bind_int64(o, 2, id);
            sqlite3_bind_text(o, 3, "done", -1, SQLITE_STATIC);
            // Final meaning must suppress even residual execution provenance.
            sqlite3_bind_int64(o, 4, op); sqlite3_bind_int64(o, 6, op); done(o);
            sqlite3_bind_int64(p, 1, op); done(p);
            sqlite3_bind_int64(d, 1, op); sqlite3_bind_int(d, 2, 1); done(d);
        }
        if (kind >= 3 && kind <= 5) continue;
        long current_count = (kind == 2 || kind == 6) ? 1 : fanout;
        for (long n = 0; n < current_count; n++) {
            ++op;
            sqlite3_bind_int64(o, 1, op); sqlite3_bind_int64(o, 2, id);
            // At most 100 fixture admissions; further in-flight categories use
            // durable retry waiting, which requires no physical Active Credit.
            if (kind == 2 && id <= 900) sqlite3_bind_int64(o, 4, op);
            if (kind == 6 || (kind == 2 && id > 900)) sqlite3_bind_int64(o, 5, 9999999999LL);
            done(o);
            if (kind == 1 || kind == 7 || kind == 8) {
                sqlite3_bind_int64(p, 1, op); done(p);
                if (kind == 8) {
                    sqlite3_bind_int64(d, 1, op); sqlite3_bind_int(d, 2, 1); done(d);
                }
            }
        }
        if (kind == 7) {
            // A sibling with no permission barrier makes the Turn runnable.
            ++op; sqlite3_bind_int64(o, 1, op); sqlite3_bind_int64(o, 2, id); done(o);
        }
    }
    sqlite3_finalize(t); sqlite3_finalize(m); sqlite3_finalize(o);
    sqlite3_finalize(c); sqlite3_finalize(p); sqlite3_finalize(d);
    sql("COMMIT;");
    if (live_index) sql("CREATE INDEX unresolved_by_turn ON operation(turn_id,id) WHERE resolution IS NULL;");
    sql("ANALYZE;");
}

// No persisted status, ready flag, historical Attempt table, or history replay.
static const char *summary_sql =
    "SELECT m.turn_id,t.session_id,t.outcome,t.answer_ref,"
    "CASE WHEN t.outcome IS NOT NULL THEN t.outcome "
    "WHEN EXISTS(SELECT 1 FROM operation o WHERE o.turn_id=t.id AND o.resolution IS NULL "
      "AND (o.attempt_id IS NOT NULL OR o.retry_due IS NOT NULL)) THEN 'in_flight' "
    "WHEN EXISTS(SELECT 1 FROM operation o JOIN permission_request p ON p.operation_id=o.id "
      "LEFT JOIN permission_decision d ON d.request_id=p.id "
      "WHERE o.turn_id=t.id AND o.resolution IS NULL AND d.request_id IS NULL) "
    "AND NOT EXISTS(SELECT 1 FROM operation o "
      "LEFT JOIN permission_request p ON p.operation_id=o.id "
      "LEFT JOIN permission_decision d ON d.request_id=p.id "
      "WHERE o.turn_id=t.id AND o.resolution IS NULL "
      "AND o.attempt_id IS NULL AND o.retry_due IS NULL "
      "AND (p.id IS NULL OR d.request_id IS NOT NULL)) "
    "THEN 'waiting_for_permission' ELSE 'runnable' END "
    "FROM member m JOIN turn t ON t.id=m.turn_id "
    "WHERE m.run_id=1 AND m.turn_id>?1 ORDER BY m.turn_id LIMIT ?2";
static const char *permission_sql =
    "SELECT p.id,o.id,p.descriptor_ref FROM operation o "
    "JOIN permission_request p ON p.operation_id=o.id "
    "LEFT JOIN permission_decision d ON d.request_id=p.id "
    "WHERE o.turn_id=?1 AND o.resolution IS NULL AND d.request_id IS NULL "
    "AND o.attempt_id IS NULL AND o.retry_due IS NULL ORDER BY o.id";

static long long vm, scans, sorts;
static void counters(sqlite3_stmt *q) {
    vm += sqlite3_stmt_status(q, SQLITE_STMTSTATUS_VM_STEP, 1);
    scans += sqlite3_stmt_status(q, SQLITE_STMTSTATUS_FULLSCAN_STEP, 1);
    sorts += sqlite3_stmt_status(q, SQLITE_STMTSTATUS_SORT, 1);
}
static void explain(const char *query) {
    char text[8192]; assert(snprintf(text, sizeof(text), "EXPLAIN QUERY PLAN %s", query) > 0);
    sqlite3_stmt *q = prepare(text);
    while (sqlite3_step(q) == SQLITE_ROW) puts((const char *)sqlite3_column_text(q, 3));
    sqlite3_finalize(q);
}

static char window[65536];
static size_t used;
static long long bytes;
static double query_time, encode_time, write_time;
static FILE *output;
static void flush(void) {
    if (!used) return;
    double start = now(); assert(fwrite(window, 1, used, output) == used);
    write_time += now() - start; used = 0;
}
static void append(const char *line, size_t length) {
    bytes += (long long)length;
    while (length) {
        size_t n = length < sizeof(window) - used ? length : sizeof(window) - used;
        memcpy(window + used, line, n); used += n; line += n; length -= n;
        if (used == sizeof(window)) flush();
    }
}
static int step(sqlite3_stmt *q) {
    double start = now(); int rc = sqlite3_step(q); query_time += now() - start;
    assert(rc == SQLITE_ROW || rc == SQLITE_DONE); return rc;
}
static void capture(long members, long fanout, int encode, int pass) {
    vm = scans = sorts = bytes = 0; used = 0;
    query_time = encode_time = write_time = 0;
    output = encode ? tmpfile() : NULL; if (encode) assert(output);
    double start = now();
    sql("BEGIN;");
    // Establish the read view before either collection is observed.
    sqlite3_stmt *head = prepare("SELECT revision FROM run WHERE id=1");
    assert(step(head) == SQLITE_ROW); sqlite3_int64 revision = sqlite3_column_int64(head, 0);
    sqlite3_finalize(head);
    sqlite3_stmt *q = prepare(summary_sql), *p = prepare(permission_sql);
    long rows = 0, permissions = 0;
    uint64_t checksum = 0;
    long batch_rows;
    do {
    batch_rows = 0;
    sqlite3_bind_int64(q, 1, rows); sqlite3_bind_int(q, 2, 100);
    while (step(q) == SQLITE_ROW) {
        batch_rows++;
        long id = (long)sqlite3_column_int64(q, 0);
        int kind = (int)((id - 1) % 9);
        const char *condition = (const char *)sqlite3_column_text(q, 4);
        assert(id == ++rows && strcmp(condition, conditions[kind]) == 0);
        checksum += (uint64_t)(id * 17 + kind);
        if (encode) {
            char line[256]; double e = now();
            int n = snprintf(line, sizeof(line), "{\"member\":%ld,\"session\":%lld,\"turn\":%ld,\"condition\":\"%s\",\"result_ref\":%lld}\n",
                id, (long long)sqlite3_column_int64(q, 1), id, condition,
                (long long)sqlite3_column_int64(q, 3));
            assert(n > 0 && n < (int)sizeof(line)); encode_time += now() - e;
            append(line, (size_t)n);
        }
        if (sqlite3_column_type(q, 2) != SQLITE_NULL) continue;
        sqlite3_bind_int64(p, 1, id);
        long count = 0;
        while (step(p) == SQLITE_ROW) {
            count++; permissions++;
            assert(kind == 1 || kind == 7);
            if (encode) {
                char line[256]; double e = now();
                int n = snprintf(line, sizeof(line), "{\"permission\":%lld,\"operation\":%lld,\"descriptor_ref\":%lld}\n",
                    (long long)sqlite3_column_int64(p, 0), (long long)sqlite3_column_int64(p, 1),
                    (long long)sqlite3_column_int64(p, 2));
                assert(n > 0 && n < (int)sizeof(line)); encode_time += now() - e;
                append(line, (size_t)n);
            }
        }
        assert(count == ((kind == 1 || kind == 7) ? fanout : 0));
        counters(p); assert(sqlite3_reset(p) == SQLITE_OK);
    }
    counters(q); assert(sqlite3_reset(q) == SQLITE_OK);
    } while (batch_rows != 0);
    assert(rows == members);
    if (encode) {
        char line[128]; int n = snprintf(line, sizeof(line), "{\"end\":true,\"revision\":%lld,\"members\":%ld,\"permissions\":%ld}\n",
            (long long)revision, rows, permissions);
        assert(n > 0 && n < (int)sizeof(line)); append(line, (size_t)n); flush();
        double w = now(); assert(fflush(output) == 0); write_time += now() - w;
    }
    sqlite3_finalize(q); sqlite3_finalize(p); sql("COMMIT;");
    double capture_ms = (now() - start) * 1000;
    assert(sqlite3_get_autocommit(db) && sqlite3_next_stmt(db, NULL) == NULL);
    // A control is modeled as ready at capture start. This is an owner-delay
    // marker, not server acknowledgement or physical interruption evidence.
    double control = now();
    sql("BEGIN IMMEDIATE; UPDATE run SET revision=revision+1 WHERE id=1; COMMIT;");
    double control_ms = (now() - control) * 1000;
    if (output) {
        assert(ftell(output) == bytes);
        if (pass == 0 && getenv("ONEPAGE_QUERY_REPORT")) {
            FILE *copy = fopen(getenv("ONEPAGE_QUERY_REPORT"), "wb"); assert(copy);
            rewind(output); size_t n;
            while ((n = fread(window, 1, sizeof(window), output))) assert(fwrite(window, 1, n, copy) == n);
            assert(fclose(copy) == 0);
        }
        assert(fclose(output) == 0);
    }
    printf("{\"pass\":%d,\"encoded\":%s,\"members\":%ld,\"permissions\":%ld,\"bytes\":%lld,"
        "\"vm_steps\":%lld,\"fullscan_steps\":%lld,\"sorts\":%lld,\"checksum\":%llu,"
        "\"query_ms\":%.6f,\"encode_ms\":%.6f,\"scratch_ms\":%.6f,\"capture_ms\":%.6f,"
        "\"control_commit_ms\":%.6f,\"modeled_control_wait_ms\":%.6f,\"sqlite_highwater\":%lld}\n",
        pass, encode ? "true" : "false", rows, permissions, bytes, vm, scans, sorts,
        (unsigned long long)checksum, query_time*1000, encode_time*1000, write_time*1000,
        capture_ms, control_ms, capture_ms+control_ms, (long long)sqlite3_memory_highwater(0));
}
int main(int argc, char **argv) {
    assert(argc == 10);
    open_db(argv[1]);
    long members=atol(argv[3]), history=atol(argv[4]), unrelated=atol(argv[5]), fanout=atol(argv[6]);
    int payload=atoi(argv[7]), live_index=atoi(argv[8]), encode=atoi(argv[9]);
    assert(members>0 && history>=0 && unrelated>=0 && fanout>0 && payload>=0);
    if (!strcmp(argv[2], "seed")) seed(members,history,unrelated,fanout,payload,live_index);
    else if (!strcmp(argv[2], "explain")) { explain(summary_sql); explain(permission_sql); }
    else { assert(!strcmp(argv[2], "run")); for (int pass=0;pass<3;pass++) capture(members,fanout,encode,pass); }
    assert(sqlite3_close(db) == SQLITE_OK);
    return 0;
}
