/* Throwaway protocol fixture, not Rui runtime code. SQLite owns durable
 * Attempt/Resolution facts; one process-local slot owns its child and pipes. */
#define _POSIX_C_SOURCE 200809L
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <errno.h>

typedef struct { int occupied, permit, live; int64_t attempt; unsigned generation; } Slot;
typedef struct { int64_t attempt; unsigned generation; } Event;
typedef struct { pid_t pid; int command, event; } Child;
static sqlite3 *db;
static const char *path;
static int broken;
static int observed_synchronous;
static char observed_journal_mode[16];
static void require(int ok, const char *message) {
    if (!ok) { fprintf(stderr, "ASSERTION: %s\n", message); exit(2); }
}
static void sql(const char *s) {
    char *error = NULL;
    int rc = sqlite3_exec(db, s, NULL, NULL, &error);
    if (rc != SQLITE_OK) {
        fprintf(stderr, "sqlite: %s (%s)\n", error, s);
        sqlite3_free(error); exit(3);
    }
}
static void open_db(void) {
    require(sqlite3_open(path, &db) == SQLITE_OK, "open database");
    sql("PRAGMA journal_mode=DELETE; PRAGMA synchronous=EXTRA;");
    sqlite3_stmt *q;
    require(sqlite3_prepare_v2(db, "PRAGMA journal_mode", -1, &q, NULL) == SQLITE_OK, "prepare journal mode");
    require(sqlite3_step(q) == SQLITE_ROW, "read journal mode");
    snprintf(observed_journal_mode, sizeof(observed_journal_mode), "%s", sqlite3_column_text(q, 0));
    require(!strcmp(observed_journal_mode, "delete"), "observed journal mode must be DELETE");
    require(sqlite3_finalize(q) == SQLITE_OK, "finalize journal mode");
    require(sqlite3_prepare_v2(db, "PRAGMA synchronous", -1, &q, NULL) == SQLITE_OK, "prepare synchronous mode");
    require(sqlite3_step(q) == SQLITE_ROW, "read synchronous mode");
    observed_synchronous = sqlite3_column_int(q, 0);
    require(observed_synchronous == 3, "observed synchronous mode must be EXTRA");
    require(sqlite3_finalize(q) == SQLITE_OK, "finalize synchronous mode");
    sql("CREATE TABLE IF NOT EXISTS attempts(id INTEGER PRIMARY KEY, kind TEXT NOT NULL);"
        "CREATE TABLE IF NOT EXISTS resolutions(attempt INTEGER PRIMARY KEY REFERENCES attempts(id), outcome TEXT NOT NULL);"
        "CREATE TABLE IF NOT EXISTS completions(attempt INTEGER PRIMARY KEY REFERENCES attempts(id));");
    sql("PRAGMA foreign_keys=ON;");
}
static void close_db(void) { require(sqlite3_close(db) == SQLITE_OK, "close database"); db = NULL; }
static int count(const char *table) {
    char s[100]; snprintf(s, sizeof(s), "SELECT count(*) FROM %s", table);
    sqlite3_stmt *q; require(sqlite3_prepare_v2(db, s, -1, &q, NULL) == SQLITE_OK, "prepare count");
    require(sqlite3_step(q) == SQLITE_ROW, "read count");
    int n = sqlite3_column_int(q, 0); sqlite3_finalize(q); return n;
}
static void add_attempt(int id, const char *kind) {
    char s[150]; snprintf(s, sizeof(s), "BEGIN IMMEDIATE; INSERT INTO attempts VALUES(%d,'%s'); COMMIT;", id, kind); sql(s);
}
static int reserve(Slot *s, int64_t attempt) {
    if (s->occupied) return 0;
    s->occupied = 1; s->attempt = attempt; s->generation++; s->permit = 0; return 1;
}
static void release(Slot *s) {
    require(!s->live, "slot release requires local child/pipe cleanup");
    s->occupied = 0; s->permit = 0;
}
static void write_all(int fd, const void *p, size_t n) {
    const char *b = p;
    while (n) { ssize_t r = write(fd, b, n); if (r < 0 && errno == EINTR) continue;
        require(r > 0, "write pipe"); b += r; n -= (size_t)r; }
}
static void read_all(int fd, void *p, size_t n) {
    char *b = p;
    while (n) { ssize_t r = read(fd, b, n); if (r < 0 && errno == EINTR) continue;
        require(r > 0, "read pipe"); b += r; n -= (size_t)r; }
}
static void join(pid_t pid) {
    int status; require(waitpid(pid, &status, 0) == pid, "wait child");
    require(WIFEXITED(status) && WEXITSTATUS(status) == 0, "child ended successfully");
}
static Child launch(Slot *s) {
    require(s->occupied && s->permit && !s->live, "dispatch requires live one-shot permit");
    s->permit = 0;
    int command[2], event[2]; require(pipe(command) == 0 && pipe(event) == 0, "create child pipes");
    pid_t pid = fork(); require(pid >= 0, "fork executor");
    if (pid == 0) {
        close(command[1]); close(event[0]);
        char c; read_all(command[0], &c, 1);
        Event e = { s->attempt, s->generation };
        write_all(event[1], &e, sizeof(e));
        read_all(command[0], &c, 1); /* Explicit cleanup gate. */
        close(command[0]); close(event[1]); _exit(0);
    }
    close(command[0]); close(event[1]); s->live = 1;
    Child child = {pid, command[1], event[0]}; return child;
}
static Event receive(Child c) {
    Event e; write_all(c.command, "E", 1); read_all(c.event, &e, sizeof(e)); return e;
}
static void cleanup(Slot *s, Child c) {
    write_all(c.command, "C", 1); close(c.command); close(c.event); join(c.pid); s->live = 0;
}
static int settle(Slot *s, Event e) {
    if (!s->occupied) return 0;
    if (!broken && (s->attempt != e.attempt || s->generation != e.generation)) return 0;
    /* The intentionally broken variant trusts only slot position. */
    char query[300];
    snprintf(query, sizeof(query), "INSERT INTO completions SELECT %lld WHERE NOT EXISTS(SELECT 1 FROM resolutions WHERE attempt=%lld) ON CONFLICT DO NOTHING;",
             (long long)s->attempt, (long long)s->attempt);
    sql(query); return sqlite3_changes(db);
}
static void rollback_case(void) {
    Slot s = {0}; require(reserve(&s, 1), "reserve first slot");
    sql("BEGIN IMMEDIATE; INSERT INTO attempts VALUES(1,'bash'); ROLLBACK;");
    release(&s); close_db(); open_db();
    require(count("attempts") == 0, "rollback leaves no admitted Attempt");
    require(!s.permit && !s.occupied, "rollback restores capacity without dispatch authority");
    require(reserve(&s, 2), "capacity reusable after rollback"); release(&s);
}
static void crash_case(int dispatched) {
    close_db(); int marker[2]; require(pipe(marker) == 0, "create launch witness");
    pid_t pid = fork(); require(pid >= 0, "fork admission owner");
    if (pid == 0) {
        close(marker[0]); open_db(); Slot s = {0}; require(reserve(&s, 1), "reserve crash slot");
        add_attempt(1, "bash"); s.permit = 1;
        if (dispatched) { s.permit = 0; write_all(marker[1], "X", 1); }
        /* abrupt process exit with open SQLite connection: no runtime cleanup */
        _exit(0);
    }
    close(marker[1]); join(pid);
    char x; ssize_t effects = read(marker[0], &x, 1); close(marker[0]);
    require(effects == dispatched, "external launch witness matches crash point");
    open_db(); Slot reconstructed = {0};
    require(count("attempts") == 1 && count("completions") == 0, "committed unresolved Attempt survives reopen");
    if (broken) {
        if (dispatched) add_attempt(2, "bash"); /* blind retry of an uncertain Bash */
        else { reserve(&reconstructed, 1); reconstructed.permit = 1; }
    }
    require(!reconstructed.permit, "recovery must not fabricate a Dispatch Permit");
    require(count("attempts") == 1, "uncertain Bash must not get a blind replacement Attempt");
}
static void cancellation_case(void) {
    Slot s = {0}; require(reserve(&s, 1), "reserve cancellation slot"); add_attempt(1, "model"); s.permit = 1;
    /* Do not let a forked executor inherit a live SQLite connection. */
    close_db(); Child c = launch(&s); open_db(); Event e = receive(c);
    sql("BEGIN IMMEDIATE; INSERT INTO resolutions VALUES(1,'interrupted'); COMMIT;");
    require(count("completions") == 0, "interruption invents no Attempt Completion");
    require(settle(&s, e) == 0, "late output cannot override interruption");
    if (broken) s.occupied = 0; /* bug: durable interruption frees live custody */
    int reused_early = reserve(&s, 2);
    cleanup(&s, c); /* even negative controls clean up before failing */
    require(!reused_early, "cannot reserve slot while old executor retains pipes/resources");
    release(&s); require(reserve(&s, 2), "slot reusable after local cleanup"); release(&s);
}
static void stale_case(void) {
    Slot s = {0}; require(reserve(&s, 1), "reserve old slot"); add_attempt(1, "model"); s.permit = 1;
    close_db(); Child c = launch(&s); open_db(); Event stale = receive(c);
    cleanup(&s, c); release(&s);
    require(reserve(&s, 2), "reuse slot for next Attempt"); add_attempt(2, "bash");
    int accepted = settle(&s, stale);
    require(!accepted && count("completions") == 0, "delayed old callback must not settle newer Attempt");
    Event current = {s.attempt, s.generation};
    require(settle(&s, current) == 1, "exact current callback settles once");
    require(settle(&s, current) == 0 && count("completions") == 1, "duplicate callback cannot add Completion");
    release(&s);
}
int main(int argc, char **argv) {
    require(argc == 4, "usage: custody CASE DATABASE BROKEN(0|1)");
    path = argv[2]; broken = atoi(argv[3]); open_db();
    printf("{\"journal_mode\":\"%s\",\"synchronous\":%d}\n", observed_journal_mode, observed_synchronous);
    require(fflush(stdout) == 0, "flush observed SQLite configuration before fork");
    if (!strcmp(argv[1], "rollback")) rollback_case();
    else if (!strcmp(argv[1], "commit-before-dispatch")) crash_case(0);
    else if (!strcmp(argv[1], "uncertain-external")) crash_case(1);
    else if (!strcmp(argv[1], "cancel-before-cleanup")) cancellation_case();
    else if (!strcmp(argv[1], "stale-callback")) stale_case();
    else require(0, "unknown scenario");
    close_db(); printf("PASS %s\n", argv[1]); return 0;
}
