#define _DARWIN_C_SOURCE
#include <sqlite3.h>
#include <CommonCrypto/CommonDigest.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <libproc.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
static sqlite3 *db;
static const char *path;
static size_t app_live, app_peak;
static unsigned char *a,*b;
static int source;
static long long footprint_peak;
static void check(int rc){if(rc!=SQLITE_OK){fprintf(stderr,"unexpected rc=%d %s\n",rc,db?sqlite3_errmsg(db):"");exit(2);}}
static int exec(const char*s){return sqlite3_exec(db,s,0,0,0);}
static long long scalar(const char*s){sqlite3_stmt*q=0;check(sqlite3_prepare_v2(db,s,-1,&q,0));int rc=sqlite3_step(q);long long v=rc==SQLITE_ROW?sqlite3_column_int64(q,0):-1;sqlite3_finalize(q);return v;}
static int fd_count(void){struct proc_fdinfo fds[256];int n=proc_pidinfo(getpid(),PROC_PIDLISTFDS,0,fds,sizeof fds);assert(n>0 && n<(int)sizeof fds);return n/(int)sizeof fds[0];}
static void sample(const char *stage){
 task_vm_info_data_t v={0};mach_msg_type_number_t n=TASK_VM_INFO_COUNT;check(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&v,&n));
 if((long long)v.phys_footprint>footprint_peak)footprint_peak=v.phys_footprint;
 sqlite3_int64 cur=0,hi=0,u=0,big=0;sqlite3_status64(SQLITE_STATUS_MEMORY_USED,&cur,&hi,0);sqlite3_status64(SQLITE_STATUS_MALLOC_SIZE,&u,&big,0);
 int cache=0,spills=0,stmt=0,h=0; if(db){sqlite3_db_status(db,SQLITE_DBSTATUS_CACHE_USED,&cache,&h,0);sqlite3_db_status(db,SQLITE_DBSTATUS_CACHE_SPILL,&spills,&h,0);sqlite3_db_status(db,SQLITE_DBSTATUS_STMT_USED,&stmt,&h,0);}
 struct stat st={0},jt={0};stat(path,&st);char journal[1024];snprintf(journal,sizeof journal,"%s-journal",path);stat(journal,&jt);
 malloc_statistics_t ms={0};malloc_zone_statistics(NULL,&ms);struct rusage ru;getrusage(RUSAGE_SELF,&ru);
 printf("{\"stage\":\"%s\",\"sqlite_live\":%lld,\"sqlite_peak\":%lld,\"largest_alloc\":%lld,\"app_buffers_live\":%zu,\"app_buffers_peak\":%zu,\"malloc_in_use\":%zu,\"malloc_reserved\":%zu,\"rss\":%llu,\"footprint\":%llu,\"sampled_footprint_peak\":%lld,\"peak_rss\":%ld,\"cache\":%d,\"statements\":%d,\"spills\":%d,\"db_bytes\":%lld,\"db_blocks_bytes\":%lld,\"journal_bytes\":%lld,\"fd_count\":%d}\n",stage,cur,hi,big,app_live,app_peak,ms.size_in_use,ms.size_allocated,(unsigned long long)v.resident_size,(unsigned long long)v.phys_footprint,footprint_peak,ru.ru_maxrss,cache,stmt,spills,st.st_size,(long long)st.st_blocks*512,jt.st_size,fd_count());fflush(stdout);
}
static void digest_source(int size,unsigned char digest[32]){CC_SHA256_CTX c;CC_SHA256_Init(&c);CC_SHA256_Update(&c,"onepage-probe-content-v1",24);for(int off=0;off<size;off+=4096){int n=size-off<4096?size-off:4096;assert(pread(source,a,n,off)==n);CC_SHA256_Update(&c,a,n);}CC_SHA256_Final(digest,&c);}
static int import(int size,int id,int returning,const unsigned char digest[32]){
 sqlite3_stmt*s=0;sqlite3_blob*blob=0;int rc=sqlite3_prepare_v2(db,returning?"INSERT INTO content(session_id,content_ref,byte_length,digest,payload) VALUES(zeroblob(8),?1,?2,?3,zeroblob(?2)) RETURNING content_id":"INSERT INTO content(session_id,content_ref,byte_length,digest,payload) VALUES(zeroblob(8),?1,?2,?3,zeroblob(?2))",-1,&s,0);
 if(rc!=SQLITE_OK)return rc;
 unsigned char key[8]={0};memcpy(key,&id,sizeof id);check(sqlite3_bind_blob(s,1,key,8,SQLITE_STATIC));check(sqlite3_bind_int(s,2,size));check(sqlite3_bind_blob(s,3,digest,32,SQLITE_STATIC));rc=sqlite3_step(s);
 if(returning&&rc==SQLITE_ROW)rc=sqlite3_step(s);
 if(id==1||rc!=SQLITE_DONE)sample("insert_step");
 sqlite3_int64 row=sqlite3_last_insert_rowid(db);sqlite3_finalize(s);if(rc!=SQLITE_DONE)return rc;
 rc=sqlite3_blob_open(db,"main","content","payload",row,1,&blob);if(rc!=SQLITE_OK)return rc;
 CC_SHA256_CTX c;CC_SHA256_Init(&c);CC_SHA256_Update(&c,"onepage-probe-content-v1",24);
 for(int off=0;off<size;off+=4096){int n=size-off<4096?size-off:4096;ssize_t got=pread(source,a,n,off);if(got!=n){rc=1001;break;}CC_SHA256_Update(&c,a,n);rc=sqlite3_blob_write(blob,a,n,off);if(rc!=SQLITE_OK)break;if(id==1&&off&&off%(4*1024*1024)==0)sample("importing");}
 unsigned char actual[32];CC_SHA256_Final(actual,&c);if(rc==SQLITE_OK&&memcmp(actual,digest,32))rc=1002;
 int close_rc=sqlite3_blob_close(blob);if(rc==SQLITE_OK)rc=close_rc;
 if(rc==SQLITE_OK){sqlite3_stmt*r;check(sqlite3_prepare_v2(db,"INSERT INTO accepted VALUES(?1,?1)",-1,&r,0));check(sqlite3_bind_int64(r,1,row));rc=sqlite3_step(r);sqlite3_finalize(r);if(rc==SQLITE_DONE)rc=SQLITE_OK;}
 return rc;
}
static int compare(int size,int rows,int mutate){
 if(mutate){unsigned char x;assert(pread(source,&x,1,size-1)==1);x^=1;assert(pwrite(source,&x,1,size-1)==1);}
 for(int id=1;id<=rows;id++){sqlite3_blob*blob=0;check(sqlite3_blob_open(db,"main","content","payload",id,0,&blob));assert(sqlite3_blob_bytes(blob)==size);
 for(int off=0;off<size;off+=4096){int n=size-off<4096?size-off:4096;assert(pread(source,a,n,off)==n);check(sqlite3_blob_read(blob,b,n,off));if(memcmp(a,b,n)){check(sqlite3_blob_close(blob));return 0;}}
 check(sqlite3_blob_close(blob));}
 return 1;
}
int main(int argc,char**argv){
 if(argc!=7)return 2;path=argv[1];int size=atoi(argv[2]),rows=atoi(argv[3]),returning=atoi(argv[4]),spill=atoi(argv[5]);const char*mode=argv[6];
 if(!strcmp(mode,"recover")){check(sqlite3_open(path,&db));assert(scalar("SELECT count(*) FROM content")==0);assert(scalar("SELECT count(*) FROM accepted")==0);assert(scalar("SELECT count(*) FROM witness WHERE value='prior-commit'")==1);check(sqlite3_close(db));printf("{\"crash_recovery_atomic\":true}\n");return 0;}
 check(sqlite3_config(SQLITE_CONFIG_MEMSTATUS,1));printf("{\"version\":\"%s\",\"threadsafe\":%d,\"size\":%d,\"rows\":%d,\"mode\":\"%s\"}\n",sqlite3_libversion(),sqlite3_threadsafe(),size,rows,mode);sample("cold");
 a=malloc(4096);b=malloc(4096);assert(a&&b);app_live=app_peak=8192;
 char src[1024];snprintf(src,sizeof src,"%s.source",path);source=open(src,O_CREAT|O_EXCL|O_RDWR,0600);assert(source>=0);
 for(int off=0;off<size;off+=4096){int n=size-off<4096?size-off:4096;for(int k=0;k<n;k++)a[k]=(unsigned char)(((off+k)*131ULL+((off+k)>>13))%251);assert(write(source,a,n)==n);}assert(fsync(source)==0);
 unsigned char digest[32];digest_source(size,digest);
 check(sqlite3_open(path,&db));check(sqlite3_db_config(db,SQLITE_DBCONFIG_DEFENSIVE,1,0));check(exec("PRAGMA page_size=4096;PRAGMA journal_mode=DELETE;PRAGMA synchronous=EXTRA;PRAGMA fullfsync=ON;PRAGMA foreign_keys=ON;PRAGMA busy_timeout=0;PRAGMA mmap_size=0;PRAGMA temp_store=FILE;PRAGMA trusted_schema=OFF;PRAGMA cache_size=-256;CREATE TABLE session(session_id BLOB PRIMARY KEY) STRICT;INSERT INTO session VALUES(zeroblob(8));"));check(exec(CONTENT_SCHEMA));check(exec("CREATE TABLE witness(value TEXT);INSERT INTO witness VALUES('prior-commit');CREATE TABLE accepted(id INTEGER PRIMARY KEY,content_id INTEGER NOT NULL REFERENCES content(content_id)) STRICT"));
 if(spill!=2)check(exec(spill?"PRAGMA cache_spill=ON;PRAGMA cache_spill=1":"PRAGMA cache_spill=OFF"));
 sqlite3_hard_heap_limit64(4*1024*1024);
 printf("{\"hard_limit\":%lld,\"mmap\":%lld,\"cache_spill\":%lld,\"cache_size\":%lld,\"sync\":%lld,\"fullfsync\":%lld,\"temp_store\":%lld}\n",sqlite3_hard_heap_limit64(-1),scalar("PRAGMA mmap_size"),scalar("PRAGMA cache_spill"),scalar("PRAGMA cache_size"),scalar("PRAGMA synchronous"),scalar("PRAGMA fullfsync"),scalar("PRAGMA temp_store"));sample("configured");
 if(!strcmp(mode,"heap")){void*p=sqlite3_malloc64(4*1024*1024);assert(p==NULL);printf("{\"hard_allocation_rejected\":true}\n");}
 if(!strcmp(mode,"full"))check(exec("PRAGMA max_page_count=64"));
 check(exec("BEGIN IMMEDIATE"));int rc=SQLITE_OK;for(int id=1;id<=rows&&rc==SQLITE_OK;id++){
 if(id==rows&&!strcmp(mode,"short"))assert(ftruncate(source,size-1)==0);
 unsigned char expected[32];memcpy(expected,digest,32);if(id==rows&&!strcmp(mode,"digest"))expected[31]^=1;
 rc=import(size,id,returning,expected);}
 if(!strcmp(mode,"crash")){assert(rc==SQLITE_OK);sample("before_crash");_exit(77);}
 sample("loaded");if(rc==SQLITE_OK)rc=exec("COMMIT");
 if(rc!=SQLITE_OK){if(!sqlite3_get_autocommit(db))check(exec("ROLLBACK"));assert(sqlite3_get_autocommit(db));assert(scalar("SELECT count(*) FROM content")==0);assert(scalar("SELECT count(*) FROM accepted")==0);assert(scalar("SELECT count(*) FROM witness WHERE value='prior-commit'")==1);printf("{\"failure_rc\":%d,\"atomic_empty\":true}\n",rc);}
 else {assert(scalar("SELECT count(*) FROM accepted")==rows);assert(compare(size,rows,0));sample("exact_reread");assert(!compare(size,rows,1));assert(compare(size,rows,1));printf("{\"equal\":true,\"last_byte_conflict_detected\":true}\n");
 if(!strcmp(mode,"select")){sqlite3_stmt*q=0;check(sqlite3_prepare_v2(db,"SELECT payload FROM content WHERE content_id=1",-1,&q,0));int r=sqlite3_step(q);if(r==SQLITE_ROW){const void*p=sqlite3_column_blob(q,0);(void)p;r=sqlite3_errcode(db);}sample("whole_select");printf("{\"whole_select_rc\":%d}\n",r);sqlite3_finalize(q);}}
 sample("retained_idle");check(sqlite3_db_release_memory(db));sample("released_cache");check(sqlite3_close(db));db=0;sample("closed");
 // Reopen verifies transactional publication across connection lifetime, not process crash or power loss.
 check(sqlite3_open(path,&db));assert(scalar("SELECT count(*) FROM witness WHERE value='prior-commit'")==1);assert(scalar("SELECT count(*) FROM content")==(rc==SQLITE_OK?rows:0));assert(scalar("SELECT count(*) FROM accepted")==(rc==SQLITE_OK?rows:0));check(sqlite3_close(db));db=0;
 close(source);unlink(src);free(a);free(b);app_live=0;sqlite3_shutdown();sample("cleanup");return 0;
}
