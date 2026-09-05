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
    assert(width <= 1024); for(int i=0;i<width;i++) binding[i] = i%4==0 ? '\n' : i%4==1 ? '"' : i%4==2 ? '\\' : 'b'; binding[width] = 0;
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


// Synthetic single-owner workload; no server/protocol implementation.
static void pause_ms(double ms) {
    struct timespec t={(time_t)(ms/1000), (long)((ms/1000-(time_t)(ms/1000))*1e9)};
    while(nanosleep(&t,&t)!=0) {}
}
static long scalar(const char *s) {
    sqlite3_stmt *q=prepare(s); assert(sqlite3_step(q)==SQLITE_ROW);
    long value=(long)sqlite3_column_int64(q,0); assert(sqlite3_finalize(q)==SQLITE_OK); return value;
}
static void escaped(FILE *f,const unsigned char *s) {
    assert(fputc('"',f)!=EOF);
    for(;*s;s++) {
        if(*s=='"'||*s=='\\') {assert(fputc('\\',f)!=EOF);assert(fputc(*s,f)!=EOF);}
        else if(*s<32) assert(fprintf(f,"\\u%04x",*s)>0);
        else assert(fputc(*s,f)!=EOF);
    }
    assert(fputc('"',f)!=EOF);
}
static FILE *capture(long expected,int batch,double delay,double budget,long byte_budget,
                     double *elapsed,long *written,long *seen,int *aborted) {
    double start=now(); FILE *f=tmpfile(); assert(f);
    // stdio's fixed default buffer is independent of report size.
    sql("BEGIN"); long revision=scalar("SELECT revision FROM head");
    assert(fprintf(f,"{\"revision\":%ld}\n",revision)>0);
    long rows=0; *aborted=0;
    do {
        sqlite3_stmt *q=prepare("SELECT m.seq,t.status,m.digest,t.ref,m.binding FROM member m JOIN turn t ON t.id=m.turn_id WHERE m.run=1 AND m.seq>?1 ORDER BY m.seq LIMIT ?2");
        sqlite3_bind_int64(q,1,rows); sqlite3_bind_int(q,2,batch); int rc;
        while((rc=sqlite3_step(q))==SQLITE_ROW) {
            assert(sqlite3_column_int64(q,0)==rows+1);
            assert(fprintf(f,"{\"seq\":%ld,\"status\":",++rows)>0);
            escaped(f,sqlite3_column_text(q,1));
            assert(fputs(",\"digest\":",f)>=0);escaped(f,sqlite3_column_text(q,2));
            assert(fputs(",\"ref\":",f)>=0);escaped(f,sqlite3_column_text(q,3));
            assert(fputs(",\"binding\":",f)>=0);escaped(f,sqlite3_column_text(q,4));
            assert(fputs("}\n",f)>=0);
        }
        assert(rc==SQLITE_DONE);
        assert(sqlite3_stmt_status(q,SQLITE_STMTSTATUS_FULLSCAN_STEP,0)==0);
        assert(sqlite3_stmt_status(q,SQLITE_STMTSTATUS_SORT,0)==0);
        assert(sqlite3_finalize(q)==SQLITE_OK);
        assert(fflush(f)==0); if(delay)pause_ms(delay);
        if((budget>0 && (now()-start)*1000>=budget) || (byte_budget>0 && ftello(f)>=byte_budget)) {*aborted=1;break;}
    } while(rows<expected);
    assert(scalar("SELECT revision FROM head")==revision);
    if(*aborted) sql("ROLLBACK");
    else {assert(rows==expected);assert(fprintf(f,"{\"end\":true,\"revision\":%ld,\"count\":%ld}\n",revision,rows)>0);assert(fflush(f)==0);sql("COMMIT");}
    assert(sqlite3_get_autocommit(db) && sqlite3_next_stmt(db,NULL)==NULL);
    *written=ftello(f);*seen=rows;*elapsed=(now()-start)*1000;
    if(*aborted){assert(fclose(f)==0);return NULL;}
    return f;
}
int main(int argc,char **argv) {
    assert(argc==10);
    const char *path=argv[1],*mode=argv[2]; long rows=atol(argv[3]);int width=atoi(argv[4]),batch=atoi(argv[5]);
    double delay=atof(argv[6]),budget=atof(argv[7]); long bytes=atol(argv[8]);int fair=atoi(argv[9]);
    open_db(path);
    if(!strcmp(mode,"seed")){seed(rows,width);assert(sqlite3_close(db)==SQLITE_OK);return 0;}
    assert(!strcmp(mode,"run"));
    long heap0=sqlite3_memory_used();sqlite3_memory_highwater(1);
    double start=now(),settle_ms=0,control_ms=0,dispatch_ms=0;
    long total=0,peak_scratch=0;int complete=0,failed=0;
    FILE *held=NULL;long held_size=0;
    for(int i=0;i<8;i++) {
        double elapsed;long written,seen;int aborted;
        FILE *f=capture(rows,batch,delay,budget,bytes,&elapsed,&written,&seen,&aborted);
        // Two not-yet-delivered reports maximum; close previous only after new capture.
        if(held_size+written>peak_scratch)peak_scratch=held_size+written;
        if(held){assert(fclose(held)==0);held=NULL;held_size=0;}
        if(f){held=f;held_size=written;complete++;}else failed++;
        total+=written;
        // Both requests are ready at capture start (worst phase). No network delay.
        if(i==0) {
            sql("BEGIN IMMEDIATE; UPDATE head SET revision=revision+1; COMMIT");
            control_ms=(now()-start)*1000;
            // Synchronous stand-in for releasing post-commit interruption consequence.
            dispatch_ms=(now()-start)*1000;
        }
        if(i==0 && fair) {sql("BEGIN IMMEDIATE; UPDATE head SET revision=revision+1; COMMIT");settle_ms=(now()-start)*1000;}
        printf("{\"event\":\"capture\",\"ordinal\":%d,\"ms\":%.6f,\"bytes\":%ld,\"rows\":%ld,\"aborted\":%s}\n",i,elapsed,written,seen,aborted?"true":"false");
    }
    if(!fair){sql("BEGIN IMMEDIATE; UPDATE head SET revision=revision+1; COMMIT");settle_ms=(now()-start)*1000;}
    // Delivery occurs after both commits, with no connection resource retained.
    if(held) {
        assert(fseeko(held,0,SEEK_SET)==0);char buffer[4096];size_t n;long delivered=0,newlines=0;
        while((n=fread(buffer,1,sizeof(buffer),held))){assert(sqlite3_get_autocommit(db));delivered+=(long)n;for(size_t j=0;j<n;j++)newlines+=buffer[j]=='\n';}
        assert(!ferror(held) && delivered==held_size && newlines==rows+2);assert(fclose(held)==0);
    }
    assert(scalar("SELECT revision FROM head")==2);
    printf("{\"event\":\"summary\",\"control_ack_ms\":%.6f,\"dispatch_marker_ms\":%.6f,\"settlement_ack_ms\":%.6f,\"complete\":%d,\"failed\":%d,\"total_scratch_written\":%ld,\"peak_logical_scratch\":%ld,\"heap_baseline\":%ld,\"heap_peak\":%lld,\"footprint_after_churn\":%llu,\"sqlite\":\"%s\"}\n",control_ms,dispatch_ms,settle_ms,complete,failed,total,peak_scratch,heap0,sqlite3_memory_highwater(0),(unsigned long long)footprint(),sqlite3_libversion());
    assert(sqlite3_close(db)==SQLITE_OK);return 0;
}
