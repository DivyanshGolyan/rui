#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <mach/mach.h>
static sqlite3 *db;
static void die(int rc,const char *where){if(rc!=SQLITE_OK){fprintf(stderr,"%s: %d %s\n",where,rc,db?sqlite3_errmsg(db):"");exit(2);}}
static void sql(const char *s){die(sqlite3_exec(db,s,0,0,0),s);}
static void sample(const char *stage){
 task_vm_info_data_t vm={0};mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
 task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&vm,&count);
 struct rusage ru;getrusage(RUSAGE_SELF,&ru);
 sqlite3_int64 current=0,high=0;sqlite3_status64(SQLITE_STATUS_MEMORY_USED,&current,&high,0);
 sqlite3_int64 unused=0,biggest=0;sqlite3_status64(SQLITE_STATUS_MALLOC_SIZE,&unused,&biggest,0);
 int cache=0,h=0,spill=0; if(db){sqlite3_db_status(db,SQLITE_DBSTATUS_CACHE_USED,&cache,&h,0);sqlite3_db_status(db,SQLITE_DBSTATUS_CACHE_SPILL,&spill,&h,0);}
 printf("{\"stage\":\"%s\",\"rss\":%llu,\"footprint\":%llu,\"peak_rss\":%ld,\"sqlite_used\":%lld,\"sqlite_high\":%lld,\"largest_sqlite_alloc\":%lld,\"cache_bytes\":%d,\"cache_spills\":%d}\n",stage,(unsigned long long)vm.resident_size,(unsigned long long)vm.phys_footprint,ru.ru_maxrss,current,high,biggest,cache,spill);fflush(stdout);
}
int main(int argc,char**argv){
 if(argc!=6)return 1;
 int n=atoi(argv[2])*1024*1024;int returning=atoi(argv[3]);int hard=atoi(argv[4]);int spill_mode=atoi(argv[5]);
 // Apple disables memory accounting by default; explicitly enable before init.
 die(sqlite3_config(SQLITE_CONFIG_MEMSTATUS,1),"memstatus");

 printf("{\"version\":\"%s\",\"bytes\":%d,\"returning\":%d,\"hard_heap_mib\":%d}\n",sqlite3_libversion(),n,returning,hard);
 sample("startup");die(sqlite3_open(argv[1],&db),"open");
 if(hard){char pragma[80];snprintf(pragma,sizeof pragma,"PRAGMA hard_heap_limit=%d",hard*1024*1024);sql(pragma);}
 sql("PRAGMA page_size=4096;PRAGMA cache_size=-256;PRAGMA mmap_size=0;PRAGMA journal_mode=DELETE;PRAGMA synchronous=EXTRA;PRAGMA temp_store=FILE;PRAGMA trusted_schema=OFF;PRAGMA foreign_keys=ON;PRAGMA cell_size_check=ON;CREATE TABLE content(content_id INTEGER PRIMARY KEY,session_id BLOB,content_ref BLOB,byte_length INTEGER,digest BLOB,payload BLOB);");
 if(spill_mode>=0)sql(spill_mode?"PRAGMA cache_spill=ON":"PRAGMA cache_spill=OFF");
 const char *names[]={"cache_spill","cache_size","hard_heap_limit"};
 for(int i=0;i<3;i++){char query[80];snprintf(query,sizeof query,"PRAGMA %s",names[i]);sqlite3_stmt *q;die(sqlite3_prepare_v2(db,query,-1,&q,0),"pragma");int rc=sqlite3_step(q);printf("{\"pragma\":\"%s\",\"supported\":%s,\"value\":%lld}\n",names[i],rc==SQLITE_ROW?"true":"false",rc==SQLITE_ROW?sqlite3_column_int64(q,0):0);sqlite3_finalize(q);}
 sample("configured");sql("BEGIN IMMEDIATE");
 sqlite3_stmt *s;die(sqlite3_prepare_v2(db,returning?"INSERT INTO content(session_id,content_ref,byte_length,digest,payload) VALUES(zeroblob(8),zeroblob(8),?1,zeroblob(32),zeroblob(?1)) RETURNING content_id":"INSERT INTO content(session_id,content_ref,byte_length,digest,payload) VALUES(zeroblob(8),zeroblob(8),?1,zeroblob(32),zeroblob(?1))",-1,&s,0),"prepare");
 die(sqlite3_bind_int(s,1,n),"bind");sample("before_insert");int rc=sqlite3_step(s);sample("after_insert_step");
 if(returning){if(rc!=SQLITE_ROW)die(rc,"insert returning");rc=sqlite3_step(s);sample("after_insert_done");}
 if(rc!=SQLITE_DONE)die(rc,"insert");die(sqlite3_finalize(s),"finalize");sample("after_finalize");
 sqlite3_blob *blob;die(sqlite3_blob_open(db,"main","content","payload",sqlite3_last_insert_rowid(db),1,&blob),"blob open");sample("blob_open");
 unsigned char bytes[4096];memset(bytes,'x',sizeof bytes);
 for(int i=0;i<n;i+=sizeof bytes)die(sqlite3_blob_write(blob,bytes,sizeof bytes,i),"write");sample("written");
 die(sqlite3_blob_close(blob),"blob close");sql("COMMIT");sample("committed");die(sqlite3_close(db),"close");db=0;sample("closed");return 0;
}
