// THROWAWAY Storage Owner + service driver, not OnePage production integration.
#include "common.h"
#include <libproc.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
static sqlite3 *db;
static int generation,created,reused,serviced_at,service_enabled;
static const char *action;
static double control_requested,control_ack,settlement_ack,longest_admission;
static int ready_control,ready_settlement;
static uint64_t sampled_parent_peak,sampled_child_peak,sampled_combined_peak,samples;
static volatile sig_atomic_t live_child;
static void terminated(int signal_number){if(live_child>0)kill(live_child,SIGKILL);_exit(128+signal_number);}
static uint64_t footprint(pid_t pid){struct rusage_info_v4 info;if(proc_pid_rusage(pid,RUSAGE_INFO_V4,(rusage_info_t*)&info))return 0;return info.ri_phys_footprint;}
static void sample(pid_t child){uint64_t p=footprint(getpid()),c=child?footprint(child):0;if(p>sampled_parent_peak)sampled_parent_peak=p;if(c>sampled_child_peak)sampled_child_peak=c;if(p+c>sampled_combined_peak)sampled_combined_peak=p+c;if(c)samples++;}
static int permitted(void){sqlite3_stmt*s=prepare(db,"SELECT generation=?,cancelled=0 AND outcome IS NULL FROM run");sqlite3_bind_int(s,1,generation);assert(sqlite3_step(s)==SQLITE_ROW);int okay=sqlite3_column_int(s,0)&&sqlite3_column_int(s,1);sqlite3_finalize(s);return okay;}
static void service(void){
 assert(sqlite3_get_autocommit(db));
 if(ready_control){sql(db,"BEGIN IMMEDIATE; UPDATE controls SET acknowledged=1; COMMIT;");control_ack=monotonic_ms()-control_requested;serviced_at=created;ready_control=0;}
 if(ready_settlement){sql(db,"BEGIN IMMEDIATE; UPDATE unrelated SET result='settled' WHERE result IS NULL; COMMIT;");settlement_ack=monotonic_ms()-control_requested;ready_settlement=0;}
}
static void checkpoint(void){
 if(created==4&&control_requested==0){control_requested=monotonic_ms();ready_control=ready_settlement=1;}
 if(service_enabled)service();
 if(created==4&&!strcmp(action,"crash")){assert(!ready_control&&!ready_settlement);fprintf(stdout,"{\"checkpoint\":\"before_publication\",\"created\":4,\"control_ack_ms\":%.3f,\"settlement_ack_ms\":%.3f}\n",control_ack,settlement_ack);fflush(stdout);kill(getpid(),SIGKILL);}
 if(created==4&&!strcmp(action,"cancel")){sql(db,"BEGIN IMMEDIATE; UPDATE run SET cancelled=1; COMMIT;");}
 if(created==4&&!strcmp(action,"supersede")){sql(db,"BEGIN IMMEDIATE; UPDATE run SET generation=generation+1; COMMIT;");}
}
static void seed_call(const char *key,const char *input,const char *result,int tag){sqlite3_stmt*s=prepare(db,"INSERT INTO calls(key,kind,input,result,tag) VALUES(?,'message',?,?,?)");sqlite3_bind_text(s,1,key,-1,SQLITE_TRANSIENT);sqlite3_bind_text(s,2,input,-1,SQLITE_TRANSIENT);if(result)sqlite3_bind_text(s,3,result,-1,SQLITE_TRANSIENT);else sqlite3_bind_null(s,3);sqlite3_bind_int(s,4,tag);complete(s);}
static char *make_answer(int bytes,int findings){size_t size=(size_t)findings*(bytes+32)+32;char *answer=malloc(size);assert(answer);char*p=answer;*p++='[';for(int i=0;i<findings;i++){if(i)*p++=',';p+=sprintf(p,"{\"text\":\"");memset(p,'x',bytes);p+=bytes;p+=sprintf(p,"\"}");}*p++=']';*p=0;return answer;}
static void set_result(const char *key,const char *answer){sqlite3_stmt*s=prepare(db,"UPDATE calls SET result=? WHERE key=? AND result IS NULL");sqlite3_bind_text(s,1,answer,-1,SQLITE_TRANSIENT);sqlite3_bind_text(s,2,key,-1,SQLITE_TRANSIENT);complete(s);}
static void populate(int n,int bytes,int findings,const char *flow,const char *availability,int fresh){
 char *answer=make_answer(bytes,findings);
 if(fresh){sql(db,"BEGIN IMMEDIATE");
  if(!strcmp(flow,"identity"))seed_call("repeat","same input","{\"text\":\"original\"}",1);
  else if(!strcmp(flow,"types")){seed_call("null","null input","null",1);seed_call("failure","failure input","{\"code\":\"saved failure\"}",2);}
  else if(!strcmp(flow,"keys")){char long_key[8193];memset(long_key,'x',8192);long_key[8192]=0;const char *keys[]={"","a","aa","\xc3\xa9","e\xcc\x81","\xe9\x8d\xb5",long_key};for(int i=0;i<7;i++){sqlite3_stmt*s=prepare(db,"SELECT json_object('key',?)");sqlite3_bind_text(s,1,keys[i],-1,SQLITE_TRANSIENT);assert(sqlite3_step(s)==SQLITE_ROW);seed_call(keys[i],keys[i],(const char*)sqlite3_column_text(s,0),1);sqlite3_finalize(s);}}
  else for(int i=0;i<n;i++){char key[64],input[64];snprintf(key,sizeof key,"scan/%d",i);snprintf(input,sizeof input,"scan %d",i);seed_call(key,input,NULL,1);}
  sql(db,"COMMIT");
 }
 if(strcmp(availability,"keep")){sql(db,"BEGIN IMMEDIATE");for(int i=0;i<n;i++){if(!strcmp(availability,"partial")&&i>0)continue;char key[64];snprintf(key,sizeof key,"scan/%d",i);set_result(key,answer);}if(!strcmp(availability,"final"))sql(db,"UPDATE calls SET result='1' WHERE key LIKE 'verify/%' AND result IS NULL");sql(db,"COMMIT");}
 if(!strcmp(action,"conflict")){sql(db,"BEGIN IMMEDIATE");seed_call("verify/0/1","wrong canonical input",NULL,1);sql(db,"COMMIT");}
 free(answer);
}
typedef struct {int write_fd,read_fd;} Scratch;
static Scratch scratch(const char *root){char path[1024];snprintf(path,sizeof path,"%s/snapshot-XXXXXX",root);int w=mkstemp(path);assert(w>=0);fcntl(w,F_SETFD,FD_CLOEXEC);int r=open(path,O_RDONLY|O_CLOEXEC);assert(r>=0);assert(!unlink(path));return (Scratch){w,r};}
static void capture(Scratch directory,Scratch data,int n,int bytes,int findings,const char *availability,double *membership_ms,double *materialize_ms,uint64_t *data_bytes,uint64_t *directory_bytes){
 double begin=monotonic_ms();sql(db,"BEGIN");uint64_t count=scalar(db,"SELECT count(*) FROM calls WHERE result IS NOT NULL");write_at(directory.write_fd,&count,8,0);uint64_t keys_at=8+count*sizeof(Entry),i=0;
 sqlite3_stmt*s=prepare(db,"SELECT rowid,key,length(CAST(result AS BLOB)),tag FROM calls WHERE result IS NOT NULL ORDER BY key COLLATE BINARY");int rc;
 while((rc=sqlite3_step(s))==SQLITE_ROW){int length=sqlite3_column_bytes(s,1);Entry e={keys_at,(uint64_t)length,0,(uint64_t)sqlite3_column_int64(s,2),(uint64_t)sqlite3_column_int64(s,0),(uint64_t)sqlite3_column_int(s,3)};write_at(directory.write_fd,&e,sizeof e,8+i*sizeof e);write_at(directory.write_fd,sqlite3_column_blob(s,1),length,keys_at);keys_at+=length;i++;}
 assert(rc==SQLITE_DONE&&i==count);sqlite3_finalize(s);sql(db,"COMMIT");*membership_ms=monotonic_ms()-begin;*directory_bytes=keys_at;
 // Result becomes available after membership capture, before body materialization.
 if(!strcmp(availability,"partial")&&n>1){char *answer=make_answer(bytes,findings);set_result("scan/1",answer);free(answer);}
 begin=monotonic_ms();uint64_t output_at=0;char window[WINDOW];
 for(i=0;i<count;i++){Entry e;read_at(directory.read_fd,&e,sizeof e,8+i*sizeof e);e.body_at=output_at;for(uint64_t at=0;at<e.body_len;){sqlite3_blob*b;assert(sqlite3_blob_open(db,"main","calls","result",e.rowid,0,&b)==SQLITE_OK);assert((uint64_t)sqlite3_blob_bytes(b)==e.body_len);int take=e.body_len-at<WINDOW?e.body_len-at:WINDOW;assert(sqlite3_blob_read(b,window,take,at)==SQLITE_OK);assert(sqlite3_blob_close(b)==SQLITE_OK);assert(sqlite3_get_autocommit(db));write_at(data.write_fd,window,take,output_at+at);at+=take;service();sample(0);}write_at(directory.write_fd,&e,sizeof e,8+i*sizeof e);output_at+=e.body_len;}
 *data_bytes=output_at;*materialize_ms=monotonic_ms()-begin;
 if(!strcmp(action,"truncated")&&output_at>0)assert(!ftruncate(data.write_fd,output_at-1));
 close(directory.write_fd);close(data.write_fd);
}
static int run_child(const char *exe,const char *source,const char *backend,int n,const char *flow,Scratch directory,Scratch data,int output_fd,double *elapsed,int *timed_out,int *signal_number){
 int input_pipe[2],streams[2][2];assert(!pipe(input_pipe)&&!pipe(streams[0])&&!pipe(streams[1]));FILE*f=fopen(source,"rb");assert(f);char code[4096];size_t size=fread(code,1,sizeof code,f);assert(size<sizeof code);fclose(f);write_all(input_pipe[1],code,size);close(input_pipe[1]);
 posix_spawn_file_actions_t fa;posix_spawnattr_t attr;assert(!posix_spawn_file_actions_init(&fa)&&!posix_spawnattr_init(&attr));assert(!posix_spawn_file_actions_adddup2(&fa,input_pipe[0],0));assert(!posix_spawn_file_actions_adddup2(&fa,streams[0][1],1));assert(!posix_spawn_file_actions_adddup2(&fa,streams[1][1],2));assert(!posix_spawn_file_actions_adddup2(&fa,directory.read_fd,3));assert(!posix_spawn_file_actions_adddup2(&fa,data.read_fd,4));assert(!posix_spawnattr_setflags(&attr,POSIX_SPAWN_CLOEXEC_DEFAULT));
 char number[32];snprintf(number,sizeof number,"%d",n);char *argv[]={(char*)exe,(char*)backend,number,(char*)flow,NULL},*env[]={NULL};pid_t child;double start=monotonic_ms();assert(!posix_spawn(&child,exe,&fa,&attr,argv,env));live_child=child;posix_spawn_file_actions_destroy(&fa);posix_spawnattr_destroy(&attr);close(input_pipe[0]);close(streams[0][1]);close(streams[1][1]);fcntl(streams[0][0],F_SETFL,O_NONBLOCK);fcntl(streams[1][0],F_SETFL,O_NONBLOCK);
 int reaped=0,opened=2,status=0;*timed_out=0;struct rusage usage;
 while(!reaped||opened){sample(reaped?0:child);if(!reaped&&!*timed_out&&monotonic_ms()-start>=5000){kill(child,SIGKILL);*timed_out=1;}
  struct pollfd p[2]={{streams[0][0],POLLIN,0},{streams[1][0],POLLIN,0}};int rc=poll(p,2,1);if(rc<0&&errno==EINTR)continue;assert(rc>=0);char window[WINDOW];for(int i=0;i<2;i++)if(p[i].fd>=0&&p[i].revents){ssize_t got=read(p[i].fd,window,sizeof window);if(!got){close(streams[i][0]);streams[i][0]=-1;opened--;}else if(got>0)write_all(i?2:output_fd,window,got);else assert(errno==EAGAIN||errno==EINTR);}
  service();if(!reaped){pid_t pid=wait4(child,&status,WNOHANG,&usage);if(pid==child){reaped=1;live_child=0;}else assert(pid==0||(pid<0&&errno==EINTR));}}
 *elapsed=monotonic_ms()-start;*signal_number=WIFSIGNALED(status)?WTERMSIG(status):0;return WIFEXITED(status)?WEXITSTATUS(status):-1;
}
static int validate(int output_fd){
 sql(db,"CREATE TEMP TABLE request(seq INTEGER PRIMARY KEY,key TEXT NOT NULL,kind TEXT NOT NULL,input TEXT NOT NULL); CREATE TEMP TABLE deps(key TEXT PRIMARY KEY); CREATE TEMP TABLE completion(value TEXT);");assert(lseek(output_fd,0,SEEK_SET)==0);FILE*f=fdopen(dup(output_fd),"r");assert(f);char*line=NULL;size_t capacity=0;
 while(getline(&line,&capacity,f)>=0){sqlite3_stmt*s=prepare(db,"SELECT json_extract(?,'$.type'),json_extract(?,'$.key'),json_extract(?,'$.kind'),json_extract(?,'$.input'),json_extract(?,'$.value'),json_quote(json_extract(?,'$.value'))");for(int i=1;i<=6;i++)sqlite3_bind_text(s,i,line,-1,SQLITE_TRANSIENT);assert(sqlite3_step(s)==SQLITE_ROW);const char*type=(const char*)sqlite3_column_text(s,0);assert(type);
  sqlite3_stmt*insert;
  if(!strcmp(type,"call")){insert=prepare(db,"INSERT INTO request(key,kind,input) VALUES(?,?,?)");for(int i=1;i<=3;i++)sqlite3_bind_text(insert,i,(const char*)sqlite3_column_text(s,i),sqlite3_column_bytes(s,i),SQLITE_TRANSIENT);}
  else if(!strcmp(type,"pending")){insert=prepare(db,"INSERT INTO deps VALUES(?) ON CONFLICT DO NOTHING");sqlite3_bind_text(insert,1,(const char*)sqlite3_column_text(s,1),sqlite3_column_bytes(s,1),SQLITE_TRANSIENT);}
  else {assert(!strcmp(type,"done"));insert=prepare(db,"INSERT INTO completion VALUES(?)");sqlite3_bind_text(insert,1,(const char*)sqlite3_column_text(s,5),sqlite3_column_bytes(s,5),SQLITE_TRANSIENT);}
  complete(insert);sqlite3_finalize(s);service();sample(0);
 }
 free(line);fclose(f);
 // All known binding conflicts are rejected before any command admission.
 if(scalar(db,"SELECT EXISTS(SELECT 1 FROM request r JOIN calls c USING(key) WHERE r.kind<>c.kind OR r.input<>c.input)"))return 0;
 if(scalar(db,"SELECT EXISTS(SELECT 1 FROM request a JOIN request b USING(key) WHERE a.kind<>b.kind OR a.input<>b.input)"))return 0;
 assert(scalar(db,"SELECT count(*) FROM completion")<=1);return 1;
}
static int equal_binding(sqlite3_stmt *lookup,const char *key,const char *kind,const char *input){sqlite3_reset(lookup);sqlite3_clear_bindings(lookup);sqlite3_bind_text(lookup,1,key,-1,SQLITE_TRANSIENT);int rc=sqlite3_step(lookup);if(rc==SQLITE_DONE){sqlite3_reset(lookup);sqlite3_clear_bindings(lookup);return 0;}assert(rc==SQLITE_ROW);int equal=!strcmp(kind,(const char*)sqlite3_column_text(lookup,0))&&!strcmp(input,(const char*)sqlite3_column_text(lookup,1));sqlite3_reset(lookup);sqlite3_clear_bindings(lookup);return equal?1:-1;}
static int admit(void){
 sqlite3_stmt *lookup=prepare(db,"SELECT kind,input FROM calls WHERE key=?"),*insert=prepare(db,"INSERT INTO calls(key,kind,input,tag) VALUES(?,?,?,1)");int position=0,okay=1;
 while(okay){if(!permitted()){okay=0;break;}sqlite3_stmt*s=prepare(db,"SELECT seq,key,kind,input FROM request WHERE seq>? ORDER BY seq LIMIT 1");sqlite3_bind_int(s,1,position);int rc=sqlite3_step(s);if(rc==SQLITE_DONE){sqlite3_finalize(s);break;}assert(rc==SQLITE_ROW);position=sqlite3_column_int(s,0);char *key=strdup((const char*)sqlite3_column_text(s,1)),*kind=strdup((const char*)sqlite3_column_text(s,2)),*input=strdup((const char*)sqlite3_column_text(s,3));assert(key&&kind&&input);sqlite3_finalize(s);
  int same=equal_binding(lookup,key,kind,input);if(same==1)reused++;else if(same<0)okay=0;else {double start=monotonic_ms();sql(db,"BEGIN IMMEDIATE");if(!permitted()){sql(db,"ROLLBACK");okay=0;}else {same=equal_binding(lookup,key,kind,input);if(same<0){sql(db,"ROLLBACK");okay=0;}else {if(!same){sqlite3_reset(insert);sqlite3_bind_text(insert,1,key,-1,SQLITE_TRANSIENT);sqlite3_bind_text(insert,2,kind,-1,SQLITE_TRANSIENT);sqlite3_bind_text(insert,3,input,-1,SQLITE_TRANSIENT);assert(sqlite3_step(insert)==SQLITE_DONE);sqlite3_reset(insert);sqlite3_clear_bindings(insert);}sql(db,"COMMIT");if(!same)created++;else reused++;}}double elapsed=monotonic_ms()-start;if(elapsed>longest_admission)longest_admission=elapsed;}
  free(key);free(kind);free(input);checkpoint();sample(0);
 }
 sqlite3_finalize(lookup);sqlite3_finalize(insert);service();return okay;
}
static int publish(void){sql(db,"BEGIN IMMEDIATE");if(!permitted()){sql(db,"ROLLBACK");return 0;}sql(db,"DELETE FROM pending; INSERT INTO pending SELECT key FROM deps; UPDATE run SET published=generation,outcome=(SELECT value FROM completion); COMMIT;");return 1;}
int main(int argc,char **argv){
 assert(argc==12);const char *root=argv[1],*child_exe=argv[2],*source=argv[3],*backend=argv[4],*flow=argv[5],*availability=argv[9];int n=atoi(argv[6]),bytes=atoi(argv[7]),findings=atoi(argv[8]);action=argv[10];service_enabled=atoi(argv[11]);signal(SIGTERM,terminated);signal(SIGINT,terminated);
 char path[1024];snprintf(path,sizeof path,"%s/store.db",root);int fresh=access(path,F_OK)!=0;assert(sqlite3_open(path,&db)==SQLITE_OK);sql(db,"PRAGMA journal_mode=DELETE; PRAGMA synchronous=EXTRA; PRAGMA mmap_size=0; PRAGMA cache_size=-256; PRAGMA temp_store=FILE; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=0;");
 if(fresh)sql(db,"CREATE TABLE calls(key TEXT PRIMARY KEY,kind TEXT NOT NULL,input TEXT NOT NULL,result TEXT,tag INTEGER NOT NULL); CREATE TABLE pending(key TEXT PRIMARY KEY REFERENCES calls(key)); CREATE TABLE run(generation INTEGER,published INTEGER,cancelled INTEGER,outcome TEXT); INSERT INTO run VALUES(0,0,0,NULL); CREATE TABLE controls(acknowledged INTEGER); INSERT INTO controls VALUES(0); CREATE TABLE unrelated(result TEXT); INSERT INTO unrelated VALUES(NULL);");
 populate(n,bytes,findings,flow,availability,fresh);
 if(scalar(db,"SELECT cancelled OR outcome IS NOT NULL FROM run")){printf("{\"already_terminal_or_cancelled\":true}\n");sqlite3_close(db);return 0;}
 sql(db,"BEGIN IMMEDIATE; UPDATE run SET generation=generation+1; COMMIT;");generation=scalar(db,"SELECT generation FROM run");
 Scratch directory=scratch(root),data=scratch(root),output=scratch(root);double membership,materialize,eval_ms,validation_ms=0,admission_ms=0,publication_ms=0;uint64_t data_bytes,directory_bytes;capture(directory,data,n,bytes,findings,availability,&membership,&materialize,&data_bytes,&directory_bytes);
 int before=scalar(db,"SELECT count(*) FROM calls"),before_pending=scalar(db,"SELECT count(*) FROM pending"),timed_out,signal_number;int child_exit=run_child(child_exe,source,backend,n,flow,directory,data,output.write_fd,&eval_ms,&timed_out,&signal_number);int validated=0,published=0;
 if(child_exit==0){double t=monotonic_ms();validated=validate(output.write_fd);validation_ms=monotonic_ms()-t;if(validated){t=monotonic_ms();int admitted=admit();admission_ms=monotonic_ms()-t;if(admitted){t=monotonic_ms();published=publish();publication_ms=monotonic_ms()-t;}}}
 if(child_exit!=0||!validated){assert(scalar(db,"SELECT count(*) FROM calls")==before);assert(scalar(db,"SELECT count(*) FROM pending")==before_pending);}
 int total_calls=scalar(db,"SELECT count(*) FROM calls"),pending=scalar(db,"SELECT count(*) FROM pending"),cancelled=scalar(db,"SELECT cancelled FROM run");
 sqlite3_stmt*s=prepare(db,"SELECT coalesce(outcome,'null') FROM run");assert(sqlite3_step(s)==SQLITE_ROW);char*outcome=strdup((const char*)sqlite3_column_text(s,0));sqlite3_finalize(s);struct stat st;assert(!fstat(output.write_fd,&st));
 printf("{\"membership_ms\":%.3f,\"materialize_ms\":%.3f,\"data_bytes\":%llu,\"directory_bytes\":%llu,\"output_bytes\":%lld,\"evaluation_ms\":%.3f,\"validation_ms\":%.3f,\"admission_ms\":%.3f,\"publication_ms\":%.3f,\"longest_admission_ms\":%.3f,\"created\":%d,\"reused\":%d,\"calls\":%d,\"pending\":%d,\"validated\":%d,\"published\":%d,\"cancelled\":%d,\"child_exit\":%d,\"child_signal\":%d,\"timed_out\":%d,\"control_ack_ms\":%.3f,\"settlement_ack_ms\":%.3f,\"serviced_after_new_calls\":%d,\"sampled_parent_peak\":%llu,\"sampled_child_peak\":%llu,\"sampled_combined_peak\":%llu,\"child_samples\":%llu,\"outcome\":%s}\n",membership,materialize,(unsigned long long)data_bytes,(unsigned long long)directory_bytes,(long long)st.st_size,eval_ms,validation_ms,admission_ms,publication_ms,longest_admission,created,reused,total_calls,pending,validated,published,cancelled,child_exit,signal_number,timed_out,control_ack,settlement_ack,serviced_at,(unsigned long long)sampled_parent_peak,(unsigned long long)sampled_child_peak,(unsigned long long)sampled_combined_peak,(unsigned long long)samples,outcome);
 free(outcome);close(directory.read_fd);close(data.read_fd);close(output.read_fd);close(output.write_fd);assert(sqlite3_close(db)==SQLITE_OK);return 0;
}
