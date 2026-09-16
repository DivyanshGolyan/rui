/* Measurement-only passthrough VFS for the existing production density fixture. */
#include <sqlite3.h>
#include <libproc.h>
#include <unistd.h>
#include <time.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

typedef struct {
  uint64_t opens, closes, reads, read_bytes, writes, write_bytes, syncs, full_syncs;
  uint64_t truncates, deletes, delete_dirsync, write_ns, sync_ns, truncate_ns, delete_ns;
  uint64_t os_write, os_sync, os_truncate, os_delete, failures;
} Metrics;
static Metrics metrics[4];
static const char *kinds[]={"database","journal","wal","other"};
static sqlite3_vfs *parent;
static sqlite3_vfs wrapper;
static sqlite3 *connection;
static uint64_t begins, commits, rollbacks, statements, inserts, selects, sql_profile_ns;
static uint64_t unique_main_pages, repeated_main_pages;
/* Measurement capacity: 262,144 4 KiB pages, matching this fixture's configured bound. */
static unsigned char written[262144/8];
static int heavy;
static uint64_t ns(void){struct timespec t;assert(clock_gettime(CLOCK_MONOTONIC,&t)==0);return (uint64_t)t.tv_sec*1000000000+t.tv_nsec;}
static uint64_t os_writes(void){struct rusage_info_v2 r;assert(proc_pid_rusage(getpid(),RUSAGE_INFO_V2,(rusage_info_t*)&r)==0);return r.ri_diskio_byteswritten;}
typedef struct {sqlite3_file base;int kind;max_align_t align;} File;
static sqlite3_file *real(sqlite3_file*f){return (sqlite3_file*)((char*)f+sizeof(File));}
static Metrics *m(sqlite3_file*f){return &metrics[((File*)f)->kind];}
static int close_file(sqlite3_file*f){int r=real(f)->pMethods->xClose(real(f));m(f)->closes++;m(f)->failures+=r!=SQLITE_OK;return r;}
static int read_file(sqlite3_file*f,void*b,int n,sqlite3_int64 o){m(f)->reads++;m(f)->read_bytes+=n;return real(f)->pMethods->xRead(real(f),b,n,o);}
static int write_file(sqlite3_file*f,const void*b,int n,sqlite3_int64 o){
 Metrics*s=m(f);uint64_t before=heavy?os_writes():0,start=ns();int r=real(f)->pMethods->xWrite(real(f),b,n,o);s->write_ns+=ns()-start;if(heavy)s->os_write+=os_writes()-before;
 s->writes++;if(r==SQLITE_OK)s->write_bytes+=n;else s->failures++;
 if(((File*)f)->kind==0&&r==SQLITE_OK){assert(n==4096&&o%4096==0);uint64_t page=o/4096;assert(page<262144);unsigned char mask=1u<<(page%8);if(written[page/8]&mask)repeated_main_pages++;else{unique_main_pages++;written[page/8]|=mask;}}
 return r;
}
static int truncate_file(sqlite3_file*f,sqlite3_int64 n){Metrics*s=m(f);uint64_t before=heavy?os_writes():0,start=ns();int r=real(f)->pMethods->xTruncate(real(f),n);s->truncate_ns+=ns()-start;if(heavy)s->os_truncate+=os_writes()-before;s->truncates++;s->failures+=r!=SQLITE_OK;return r;}
static int sync_file(sqlite3_file*f,int flags){Metrics*s=m(f);uint64_t before=heavy?os_writes():0,start=ns();int r=real(f)->pMethods->xSync(real(f),flags);s->sync_ns+=ns()-start;if(heavy)s->os_sync+=os_writes()-before;s->syncs++;s->full_syncs+=(flags&0xf)==SQLITE_SYNC_FULL;s->failures+=r!=SQLITE_OK;return r;}
static int size_file(sqlite3_file*f,sqlite3_int64*n){return real(f)->pMethods->xFileSize(real(f),n);}
static int lock_file(sqlite3_file*f,int n){return real(f)->pMethods->xLock(real(f),n);}
static int unlock_file(sqlite3_file*f,int n){return real(f)->pMethods->xUnlock(real(f),n);}
static int reserved_file(sqlite3_file*f,int*n){return real(f)->pMethods->xCheckReservedLock(real(f),n);}
static int control_file(sqlite3_file*f,int op,void*p){return real(f)->pMethods->xFileControl(real(f),op,p);}
static int sector_file(sqlite3_file*f){return real(f)->pMethods->xSectorSize(real(f));}
static int device_file(sqlite3_file*f){return real(f)->pMethods->xDeviceCharacteristics(real(f));}
static int map_file(sqlite3_file*f,int a,int b,int c,void volatile**p){return real(f)->pMethods->xShmMap(real(f),a,b,c,p);}
static int shm_lock(sqlite3_file*f,int a,int b,int c){return real(f)->pMethods->xShmLock(real(f),a,b,c);}
static void barrier_file(sqlite3_file*f){real(f)->pMethods->xShmBarrier(real(f));}
static int unmap_file(sqlite3_file*f,int a){return real(f)->pMethods->xShmUnmap(real(f),a);}
static int fetch_file(sqlite3_file*f,sqlite3_int64 o,int n,void**p){return real(f)->pMethods->xFetch(real(f),o,n,p);}
static int unfetch_file(sqlite3_file*f,sqlite3_int64 o,void*p){return real(f)->pMethods->xUnfetch(real(f),o,p);}
static const sqlite3_io_methods methods={3,close_file,read_file,write_file,truncate_file,sync_file,size_file,lock_file,unlock_file,reserved_file,control_file,sector_file,device_file,map_file,shm_lock,barrier_file,unmap_file,fetch_file,unfetch_file};
static int open_file(sqlite3_vfs*v,const char*name,sqlite3_file*f,int flags,int*out){
 (void)v;File*w=(File*)f;memset(w,0,sizeof(*w));w->kind=flags&SQLITE_OPEN_MAIN_DB?0:flags&SQLITE_OPEN_MAIN_JOURNAL?1:flags&SQLITE_OPEN_WAL?2:3;
 int rc=parent->xOpen(parent,name,real(f),flags,out);if(rc==SQLITE_OK){assert(real(f)->pMethods->iVersion>=3);f->pMethods=&methods;metrics[w->kind].opens++;}return rc;
}
static int delete_file(sqlite3_vfs*v,const char*name,int syncdir){(void)v;size_t n=strlen(name);int kind=n>=8&&!strcmp(name+n-8,"-journal")?1:n>=4&&!strcmp(name+n-4,"-wal")?2:3;Metrics*s=&metrics[kind];uint64_t before=heavy?os_writes():0,start=ns();int r=parent->xDelete(parent,name,syncdir);s->delete_ns+=ns()-start;if(heavy)s->os_delete+=os_writes()-before;s->deletes++;s->delete_dirsync+=!!syncdir;s->failures+=r!=SQLITE_OK;return r;}
static int trace(unsigned event,void*ctx,void*p,void*x){
 (void)ctx;if(event==SQLITE_TRACE_PROFILE){sql_profile_ns+=*(sqlite3_uint64*)x;return 0;}
 const char*s=sqlite3_sql((sqlite3_stmt*)p);if(!s)return 0;while(*s==' '||*s=='\n')s++;statements++;
 if(!strncmp(s,"BEGIN",5)){begins++;memset(written,0,sizeof written);}else if(!strncmp(s,"COMMIT",6))commits++;else if(!strncmp(s,"ROLLBACK",8))rollbacks++;else if(!strncmp(s,"INSERT",6))inserts++;else if(!strncmp(s,"SELECT",6))selects++;
 return 0;
}
static int attach(sqlite3*db,char**error,const sqlite3_api_routines*api){(void)error;(void)api;connection=db;return sqlite3_trace_v2(db,SQLITE_TRACE_STMT|SQLITE_TRACE_PROFILE,trace,0);}
int write_probe_install(void){parent=sqlite3_vfs_find(NULL);assert(parent);wrapper=*parent;wrapper.zName="rui-write-probe";wrapper.szOsFile=sizeof(File)+parent->szOsFile;wrapper.xOpen=open_file;wrapper.xDelete=delete_file;int rc=sqlite3_vfs_register(&wrapper,1);if(rc!=SQLITE_OK)return rc;return sqlite3_auto_extension((void(*)(void))attach);}
unsigned short write_probe_cache(void){const char*s=getenv("RUI_PROBE_CACHE_KIB");int n=s?atoi(s):64;assert(n==32||n==64||n==128);return n;}
static long long number(const char*sql){sqlite3_stmt*q;assert(sqlite3_prepare_v2(connection,sql,-1,&q,0)==SQLITE_OK);assert(sqlite3_step(q)==SQLITE_ROW);long long n=sqlite3_column_int64(q,0);assert(sqlite3_finalize(q)==SQLITE_OK);return n;}
void write_probe_reset(void){
 const char*e=getenv("RUI_PROBE_OS_ATTRIBUTION");heavy=e&&atoi(e);sqlite3_stmt*q;assert(sqlite3_prepare_v2(connection,"PRAGMA journal_mode",-1,&q,0)==SQLITE_OK);assert(sqlite3_step(q)==SQLITE_ROW);assert(!strcmp((const char*)sqlite3_column_text(q,0),"delete"));assert(sqlite3_finalize(q)==SQLITE_OK);
 printf("{\"probe_settings\":true,\"cache_kib\":%u,\"os_attribution\":%d,\"journal\":\"delete\",\"synchronous\":%lld,\"fullfsync\":%lld,\"mmap\":%lld,\"page_size\":%lld,\"cache_spill\":%lld}\n",write_probe_cache(),heavy,number("PRAGMA synchronous"),number("PRAGMA fullfsync"),number("PRAGMA mmap_size"),number("PRAGMA page_size"),number("PRAGMA cache_spill"));fflush(stdout);
 memset(metrics,0,sizeof metrics);memset(written,0,sizeof written);begins=commits=rollbacks=statements=inserts=selects=sql_profile_ns=unique_main_pages=repeated_main_pages=0;
}
void write_probe_report(unsigned long long population){
 // Capture counters before verification queries add read-only trace events.
 Metrics saved[4];memcpy(saved,metrics,sizeof saved);uint64_t st=statements,se=selects,prof=sql_profile_ns;
 long long sessions=number("SELECT count(*) FROM session"),content=number("SELECT count(*) FROM content"),entries=number("SELECT count(*) FROM conversation_entry"),transitions=number("SELECT count(*) FROM session_transition"),bytes=number("SELECT sum(byte_length) FROM content");
 assert(sessions==(long long)population&&content==sessions&&entries==sessions&&transitions==sessions&&bytes==sessions*36);
 printf("{\"write_probe_population\":%llu,\"begins\":%llu,\"commits\":%llu,\"rollbacks\":%llu,\"statements\":%llu,\"inserts\":%llu,\"selects\":%llu,\"sql_profile_ns\":%llu,\"unique_main_pages_per_transaction_sum\":%llu,\"repeated_main_page_writes_in_transaction\":%llu,\"verified_sessions\":%lld,\"verified_content_bytes\":%lld,\"files\":{",population,begins,commits,rollbacks,st,inserts,se,prof,unique_main_pages,repeated_main_pages,sessions,bytes);
 for(int i=0;i<4;i++){Metrics*s=&saved[i];printf("%s\"%s\":{\"opens\":%llu,\"closes\":%llu,\"reads\":%llu,\"read_bytes\":%llu,\"writes\":%llu,\"write_bytes\":%llu,\"syncs\":%llu,\"full_syncs\":%llu,\"truncates\":%llu,\"deletes\":%llu,\"delete_dirsync\":%llu,\"write_ns\":%llu,\"sync_ns\":%llu,\"truncate_ns\":%llu,\"delete_ns\":%llu,\"os_write\":%llu,\"os_sync\":%llu,\"os_truncate\":%llu,\"os_delete\":%llu,\"failures\":%llu}",i?",":"",kinds[i],s->opens,s->closes,s->reads,s->read_bytes,s->writes,s->write_bytes,s->syncs,s->full_syncs,s->truncates,s->deletes,s->delete_dirsync,s->write_ns,s->sync_ns,s->truncate_ns,s->delete_ns,s->os_write,s->os_sync,s->os_truncate,s->os_delete,s->failures);}
 printf("}}\n");fflush(stdout);
}
