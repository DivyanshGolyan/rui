// Measurement fixture, not the proposed OnePage schema or server implementation.
// One owner thread, DELETE journal, bounded buffers, indexed relational lookup.
#include "sqlite3.h"
#include <assert.h>
#include <libproc.h>
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
    sqlite3_stmt *p = NULL;
    if (sqlite3_prepare_v2(db, s, -1, &p, NULL) != SQLITE_OK) {
        fprintf(stderr, "%s\n", sqlite3_errmsg(db)); exit(2);
    }
    return p;
}
static double now(void) {
    struct timespec ts; assert(clock_gettime(CLOCK_MONOTONIC, &ts) == 0);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}
static uint64_t footprint(void) {
    struct rusage_info_v4 usage = {0};
    assert(proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&usage) == 0);
    return usage.ri_phys_footprint;
}
static void open_db(const char *path) {
    assert(sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE |
           SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_PRIVATECACHE, NULL) == SQLITE_OK);
    sql("PRAGMA page_size=4096; PRAGMA journal_mode=DELETE; PRAGMA synchronous=EXTRA;"
        "PRAGMA foreign_keys=ON; PRAGMA busy_timeout=0; PRAGMA mmap_size=0;"
        "PRAGMA temp_store=FILE; PRAGMA trusted_schema=OFF; PRAGMA cell_size_check=ON;"
        "PRAGMA cache_size=-64;");
}
static void seed(long rows, int width) {
    sql("CREATE TABLE head(revision INTEGER NOT NULL); INSERT INTO head VALUES(0);"
        "CREATE TABLE turn(id INTEGER PRIMARY KEY, status TEXT NOT NULL, ref TEXT NOT NULL);"
        "CREATE TABLE member(run INTEGER NOT NULL, seq INTEGER NOT NULL, turn_id INTEGER NOT NULL,"
        " digest TEXT NOT NULL, binding TEXT NOT NULL, PRIMARY KEY(run,seq)) WITHOUT ROWID;"
        "BEGIN IMMEDIATE;");
    char binding[1025], digest[65];
    assert(width <= 1024); memset(binding, 'b', width); binding[width] = 0;
    memset(digest, 'a', 64); digest[64] = 0;
    sqlite3_stmt *t = prepare("INSERT INTO turn VALUES(?1,?2,?3)");
    sqlite3_stmt *m = prepare("INSERT INTO member VALUES(1,?1,?1,?2,?3)");
    const char *states[] = {"runnable", "waiting_for_permission", "in_flight", "completed", "failed", "cancelled"};
    for (long i = 1; i <= rows; i++) {
        sqlite3_bind_int64(t, 1, i); sqlite3_bind_text(t, 2, states[i % 6], -1, SQLITE_STATIC);
        sqlite3_bind_text(t, 3, digest, -1, SQLITE_STATIC);
        assert(sqlite3_step(t) == SQLITE_DONE); assert(sqlite3_reset(t) == SQLITE_OK);
        sqlite3_bind_int64(m, 1, i); sqlite3_bind_text(m, 2, digest, -1, SQLITE_STATIC);
        sqlite3_bind_text(m, 3, binding, -1, SQLITE_STATIC);
        assert(sqlite3_step(m) == SQLITE_DONE); assert(sqlite3_reset(m) == SQLITE_OK);
    }
    assert(sqlite3_finalize(t) == SQLITE_OK); assert(sqlite3_finalize(m) == SQLITE_OK);
    sql("COMMIT; ANALYZE;");
}

int main(int argc, char **argv) {
    assert(argc == 6); const char *path = argv[1], *mode = argv[2];
    long expected = strtol(argv[3], NULL, 10); int width = atoi(argv[4]);
    int batch = atoi(argv[5]);
    open_db(path);
    if (!strcmp(mode, "seed")) { seed(expected, width); assert(sqlite3_close(db) == SQLITE_OK); return 0; }
    assert(!strcmp(mode, "capture"));
    // 0: one cursor. 1/100: finalize and prepare each private keyset batch.
    char line[4096], output_buffer[8192], read_buffer[8192];
    memset(line, 0, sizeof(line)); memset(output_buffer, 0, sizeof(output_buffer));
    memset(read_buffer, 0, sizeof(read_buffer));
    sqlite3_int64 heap_baseline = sqlite3_memory_used(), ignored, reset_peak;
    sqlite3_status64(SQLITE_STATUS_MEMORY_USED, &ignored, &reset_peak, 1);
    uint64_t physical_baseline = footprint(), physical_peak = physical_baseline;
    double started = now(); // Includes scratch creation, all SQL, formatting, fflush and COMMIT.
    FILE *report = tmpfile(); assert(report);
    assert(setvbuf(report, output_buffer, _IOFBF, sizeof(output_buffer)) == 0);
    sql("BEGIN");
    sqlite3_stmt *h = prepare("SELECT revision FROM head");
    assert(sqlite3_step(h) == SQLITE_ROW && sqlite3_column_int64(h, 0) == 0);
    assert(sqlite3_finalize(h) == SQLITE_OK);
    assert(fputs("{\"type\":\"start\",\"revision\":\"0\"}\n", report) >= 0);
    long rows = 0, statements = 0; int fullscan = 0, sorts = 0;
    do {
        sqlite3_stmt *q = prepare(
            "SELECT m.seq,t.status,m.digest,t.ref,m.binding FROM member m "
            "JOIN turn t ON t.id=m.turn_id WHERE m.run=1 AND m.seq>?1 "
            "ORDER BY m.seq LIMIT ?2");
        statements++;
        sqlite3_bind_int64(q, 1, rows); sqlite3_bind_int(q, 2, batch ? batch : -1);
        int rc;
        while ((rc = sqlite3_step(q)) == SQLITE_ROW) {
            long seq = (long)sqlite3_column_int64(q, 0); assert(seq == rows + 1);
            int n = snprintf(line, sizeof(line),
                "{\"type\":\"membership\",\"turnId\":\"t%ld\",\"sessionId\":\"s%ld\","
                "\"status\":\"%s\",\"descriptorDigest\":\"%s\",\"contentRef\":\"%s\",\"binding\":\"%s\"}\n",
                seq, seq, sqlite3_column_text(q, 1), sqlite3_column_text(q, 2),
                sqlite3_column_text(q, 3), sqlite3_column_text(q, 4));
            assert(n > 0 && (size_t)n < sizeof(line));
            assert(fwrite(line, 1, n, report) == (size_t)n); rows++;
            if (rows % 4096 == 0) {
                uint64_t p = footprint(); if (p > physical_peak) physical_peak = p;
            }
        }
        assert(rc == SQLITE_DONE);
        fullscan += sqlite3_stmt_status(q, SQLITE_STMTSTATUS_FULLSCAN_STEP, 0);
        sorts += sqlite3_stmt_status(q, SQLITE_STMTSTATUS_SORT, 0);
        assert(sqlite3_finalize(q) == SQLITE_OK);
    } while (batch && rows < expected);
    assert(rows == expected && fullscan == 0 && sorts == 0);
    assert(fprintf(report, "{\"type\":\"end\",\"revision\":\"0\",\"recordCount\":\"%ld\"}\n", rows) > 0);
    assert(fflush(report) == 0); sql("COMMIT");
    double capture_ms = (now() - started) * 1000;
    assert(sqlite3_get_autocommit(db));
    uint64_t p = footprint(); if (p > physical_peak) physical_peak = p;
    sqlite3_int64 heap_current, heap_peak;
    sqlite3_status64(SQLITE_STATUS_MEMORY_USED, &heap_current, &heap_peak, 0);
    off_t bytes = ftello(report); assert(bytes > 0);
    // A command queued at capture start can now execute, before any report delivery.
    double command_started = now();
    sql("BEGIN IMMEDIATE; UPDATE head SET revision=1; COMMIT;");
    double command_ms = (now() - command_started) * 1000;
    assert(fseeko(report, 0, SEEK_SET) == 0);
    long lines = 0; off_t delivered = 0; size_t n;
    while ((n = fread(read_buffer, 1, sizeof(read_buffer), report))) {
        assert(sqlite3_get_autocommit(db)); delivered += n;
        for (size_t i = 0; i < n; i++) lines += read_buffer[i] == '\n';
    }
    assert(!ferror(report) && delivered == bytes && lines == rows + 2);
    assert(fclose(report) == 0);
    printf("{\"sqlite\":\"%s\",\"rows\":%ld,\"binding_bytes\":%d,\"batch\":%d,"
           "\"report_bytes\":%lld,\"capture_ms\":%.4f,\"command_after_capture_ms\":%.4f,"
           "\"sqlite_heap_baseline\":%lld,\"sqlite_heap_peak\":%lld,"
           "\"physical_baseline\":%llu,\"physical_peak_sampled\":%llu,"
           "\"statements\":%ld,\"fullscan_steps\":%d,\"sorts\":%d}\n",
           sqlite3_libversion(), rows, width, batch, (long long)bytes, capture_ms, command_ms,
           heap_baseline, heap_peak, (unsigned long long)physical_baseline,
           (unsigned long long)physical_peak, statements, fullscan, sorts);
    sql("UPDATE head SET revision=0;");
    assert(sqlite3_close(db) == SQLITE_OK);
    return 0;
}
