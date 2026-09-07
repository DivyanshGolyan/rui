// THROWAWAY native-endian private input format, not a published protocol.
#pragma once
#include "quickjs.h"
#include "sqlite3.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#define WINDOW 4096
// Directory: count, Entry[count], then exact key bytes. Bodies are in fd 4.
// rowid is a captured prototype result locator used only by the parent builder.
typedef struct { uint64_t key_at, key_len, body_at, body_len, rowid, tag; } Entry;
static double monotonic_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec*1000.0+t.tv_nsec/1e6; }
static double process_ms(void) { struct timespec t; clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&t); return t.tv_sec*1000.0+t.tv_nsec/1e6; }
static void sql(sqlite3 *db, const char *text) { char *error=NULL; int rc=sqlite3_exec(db,text,NULL,NULL,&error); if(rc!=SQLITE_OK){fprintf(stderr,"SQL: %s: %s\n",text,error);exit(2);} }
static sqlite3_stmt *prepare(sqlite3 *db,const char *text) { sqlite3_stmt *s; int rc=sqlite3_prepare_v2(db,text,-1,&s,NULL); if(rc!=SQLITE_OK){fprintf(stderr,"prepare: %s\n",sqlite3_errmsg(db));exit(2);} return s; }
static void complete(sqlite3_stmt *s) { int rc=sqlite3_step(s); if(rc!=SQLITE_DONE){fprintf(stderr,"step: %s\n",sqlite3_errmsg(sqlite3_db_handle(s)));exit(2);} sqlite3_finalize(s); }
static int scalar(sqlite3 *db,const char *text) { sqlite3_stmt *s=prepare(db,text); assert(sqlite3_step(s)==SQLITE_ROW); int value=sqlite3_column_int(s,0); sqlite3_finalize(s);return value; }
static void write_all(int fd,const void *data,size_t size) { const char *p=data; while(size){ssize_t n=write(fd,p,size);if(n<0&&errno==EINTR)continue;assert(n>0);p+=n;size-=n;} }
static void write_at(int fd,const void *data,size_t size,uint64_t at) { const char *p=data; while(size){ssize_t n=pwrite(fd,p,size,at);if(n<0&&errno==EINTR)continue;assert(n>0);p+=n;size-=n;at+=n;} }
static void read_at(int fd,void *data,size_t size,uint64_t at) { char *p=data; while(size){ssize_t n=pread(fd,p,size,at);if(n<0&&errno==EINTR)continue;assert(n>0);p+=n;size-=n;at+=n;} }
