// THROWAWAY: pinned SQLite capture -> temporary input -> pinned QuickJS -> publication.
#include "quickjs.h"
#include "sqlite3.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1000.0+t.tv_nsec/1e6;}
static void sql(sqlite3*d,const char*s){char*e=0;int r=sqlite3_exec(d,s,0,0,&e);if(r){fprintf(stderr,"SQL %s: %s\n",s,e);exit(2);}}
static sqlite3_stmt* stmt(sqlite3*d,const char*s){sqlite3_stmt*p;assert(sqlite3_prepare_v2(d,s,-1,&p,0)==SQLITE_OK);return p;}
static void step(sqlite3_stmt*p){int rc=sqlite3_step(p);if(rc!=SQLITE_DONE){fprintf(stderr,"step: %s\n",sqlite3_errmsg(sqlite3_db_handle(p)));exit(2);}sqlite3_finalize(p);}
static FILE*out;
static double longest_admission_ms;
static JSValue emit(JSContext*c,JSValueConst self,int argc,JSValueConst*argv){(void)self;(void)argc;JSValue v=JS_JSONStringify(c,argv[0],JS_UNDEFINED,JS_UNDEFINED);if(JS_IsException(v))return v;const char*s=JS_ToCString(c,v);if(!s){JS_FreeValue(c,v);return JS_EXCEPTION;}fprintf(out,"%s\n",s);JS_FreeCString(c,s);JS_FreeValue(c,v);return JS_UNDEFINED;}
static int good(JSContext*c,JSValue v){if(JS_IsException(v)){JSValue e=JS_GetException(c);const char*s=JS_ToCString(c,e);fprintf(stderr,"QuickJS: %s\n",s?s:"allocation failure");if(s)JS_FreeCString(c,s);JS_FreeValue(c,e);return 0;}JS_FreeValue(c,v);return 1;}
static int child(const char*input,const char*output,const char*source,int branches){
 JSRuntime*r=JS_NewRuntime();JS_SetMemoryLimit(r,16*1024*1024);JSContext*c=JS_NewContext(r);assert(c);out=fopen(output,"w");assert(out);
 JSValue global=JS_GetGlobalObject(c);JS_SetPropertyStr(c,global,"emit",JS_NewCFunction(c,emit,"emit",1));
 FILE*f=fopen(source,"rb");assert(f);char code[8192];size_t n=fread(code,1,sizeof(code),f);assert(n<sizeof(code));code[n]=0;fclose(f);
 int loaded=0;int ok=good(c,JS_Eval(c,code,n,"fixture.js",JS_EVAL_TYPE_GLOBAL));
 f=fopen(input,"r");assert(f);char*line=NULL;size_t cap=0;ssize_t len;JSValue load=JS_GetPropertyStr(c,global,"load");
 while(ok&&(len=getline(&line,&cap,f))>=0){JSValue row=JS_ParseJSON(c,line,len,"input");if(JS_IsException(row)){ok=good(c,row);break;}JSValue v=JS_Call(c,load,JS_UNDEFINED,1,&row);JS_FreeValue(c,row);ok=good(c,v);if(ok)loaded++;}free(line);fclose(f);JS_FreeValue(c,load);
 if(ok){JSValue start=JS_GetPropertyStr(c,global,"start"),arg=JS_NewInt32(c,branches);ok=good(c,JS_Call(c,start,JS_UNDEFINED,1,&arg));JS_FreeValue(c,start);}
 JSContext*job;int jobs=0;while(ok){int s=JS_ExecutePendingJob(r,&job);if(s==0)break;if(s<0){ok=good(job,JS_EXCEPTION);break;}jobs++;}
 JSValue failure=JS_GetPropertyStr(c,global,"failure");if(!JS_IsUndefined(failure)){ok=0;fprintf(stderr,"workflow rejected\n");}JS_FreeValue(c,failure);
 JSMemoryUsage usage;JS_ComputeMemoryUsage(r,&usage);fprintf(stderr,"engine_live=%lld engine_allocated=%lld loaded=%d jobs=%d\n",(long long)usage.memory_used_size,(long long)usage.malloc_size,loaded,jobs);
 JS_FreeValue(c,global);JS_FreeContext(c);JS_FreeRuntime(r);assert(fclose(out)==0);return ok?0:20;
}
static void result(sqlite3*d,const char*key,const char*json){sqlite3_stmt*p=stmt(d,"UPDATE calls SET result=? WHERE key=? AND result IS NULL");sqlite3_bind_text(p,1,json,-1,SQLITE_TRANSIENT);sqlite3_bind_text(p,2,key,-1,SQLITE_TRANSIENT);step(p);}
static void capture(sqlite3*d,const char*path,long*bytes){FILE*f=fopen(path,"wb");assert(f);sql(d,"BEGIN");sqlite3_stmt*p=stmt(d,"SELECT json_object('key',key,'value',json(result)) FROM calls WHERE result IS NOT NULL ORDER BY key");int rc;*bytes=0;while((rc=sqlite3_step(p))==SQLITE_ROW){int n=sqlite3_column_bytes(p,0);assert(fwrite(sqlite3_column_text(p,0),1,n,f)==(size_t)n);fputc('\n',f);*bytes+=n+1;}assert(rc==SQLITE_DONE);sqlite3_finalize(p);assert(fclose(f)==0);sql(d,"COMMIT");}
static int count(sqlite3*d,const char*q){sqlite3_stmt*p=stmt(d,q);assert(sqlite3_step(p)==SQLITE_ROW);int n=sqlite3_column_int(p,0);sqlite3_finalize(p);return n;}
// Validate the complete child output into scratch SQLite before any canonical admission.
static void validate(sqlite3*d,const char*path){sql(d,"DROP TABLE IF EXISTS temp.frame; CREATE TEMP TABLE frame(line TEXT NOT NULL)");FILE*f=fopen(path,"r");assert(f);char*l=0;size_t cap=0;while(getline(&l,&cap,f)>=0){sqlite3_stmt*p=stmt(d,"INSERT INTO frame SELECT ? WHERE json_valid(?) AND json_extract(?,'$.type') IN ('call','pending','done')");for(int i=1;i<=3;i++)sqlite3_bind_text(p,i,l,-1,SQLITE_TRANSIENT);step(p);assert(sqlite3_changes(d)==1);}free(l);fclose(f);}
static void admit(sqlite3*d){longest_admission_ms=0;sqlite3_stmt*rows=stmt(d,"SELECT json_extract(line,'$.key'),json_extract(line,'$.input') FROM frame WHERE json_extract(line,'$.type')='call'");while(sqlite3_step(rows)==SQLITE_ROW){double began=now();const char*k=(const char*)sqlite3_column_text(rows,0),*in=(const char*)sqlite3_column_text(rows,1);sql(d,"BEGIN");sqlite3_stmt*p=stmt(d,"INSERT INTO calls(key,input) VALUES(?,?) ON CONFLICT(key) DO NOTHING");sqlite3_bind_text(p,1,k,-1,SQLITE_TRANSIENT);sqlite3_bind_text(p,2,in,-1,SQLITE_TRANSIENT);step(p);p=stmt(d,"SELECT input=? FROM calls WHERE key=?");sqlite3_bind_text(p,1,in,-1,SQLITE_TRANSIENT);sqlite3_bind_text(p,2,k,-1,SQLITE_TRANSIENT);assert(sqlite3_step(p)==SQLITE_ROW&&sqlite3_column_int(p,0));sqlite3_finalize(p);sql(d,"COMMIT");double elapsed=now()-began;if(elapsed>longest_admission_ms)longest_admission_ms=elapsed;}sqlite3_finalize(rows);}
static void publish(sqlite3*d){sql(d,"BEGIN; DELETE FROM pending; INSERT INTO pending SELECT DISTINCT json_extract(line,'$.key') FROM frame WHERE json_extract(line,'$.type')='pending'; UPDATE run SET outcome=(SELECT json_extract(line,'$.value') FROM frame WHERE json_extract(line,'$.type')='done'); COMMIT;");}
int main(int argc,char**argv){if(argc>1&&!strcmp(argv[1],"child"))return child(argv[2],argv[3],argv[4],atoi(argv[5]));assert(argc==6);int branches=atoi(argv[2]),bytes=atoi(argv[3]),findings=atoi(argv[4]);char dbpath[1024],input[1024],output[1024],source[1024];snprintf(dbpath,sizeof dbpath,"%s/store.db",argv[1]);snprintf(input,sizeof input,"%s/input",argv[1]);snprintf(output,sizeof output,"%s/output",argv[1]);snprintf(source,sizeof source,"%s",argv[5]);sqlite3*d;assert(sqlite3_open(dbpath,&d)==SQLITE_OK);
 sql(d,"PRAGMA journal_mode=DELETE; PRAGMA synchronous=EXTRA; PRAGMA mmap_size=0; PRAGMA cache_size=-256; PRAGMA temp_store=FILE; CREATE TABLE calls(key TEXT PRIMARY KEY,input TEXT NOT NULL,result TEXT); CREATE TABLE pending(key TEXT PRIMARY KEY REFERENCES calls(key)); CREATE TABLE run(outcome INTEGER); INSERT INTO run VALUES(NULL);");
 // Each scanner's immutable answer is a JSON array of findings; bytes is per finding.
 size_t size=(size_t)findings*(bytes+32)+32;char*answer=malloc(size);assert(answer);char*p=answer;*p++='[';for(int j=0;j<findings;j++){if(j)*p++=',';p+=sprintf(p,"{\"text\":\"");memset(p,'x',bytes);p+=bytes;p+=sprintf(p,"\"}");}*p++=']';*p=0;
 for(int phase=0;phase<4;phase++){
  if(phase==1||phase==2){sql(d,"BEGIN");for(int i=phase==1?0:1;i<(phase==1?1:branches);i++){char key[64];snprintf(key,sizeof key,"scan/%d",i);result(d,key,answer);}sql(d,"COMMIT");}
  if(phase==3){sql(d,"BEGIN; UPDATE calls SET result='1' WHERE key LIKE 'verify/%' AND result IS NULL; COMMIT;");}
  int before_calls=count(d,"SELECT count(*) FROM calls"),before_pending=count(d,"SELECT count(*) FROM pending");longest_admission_ms=0;
  long captured;double t=now();capture(d,input,&captured);double capture_ms=now()-t;
  // A finishes before capture; B finishes afterwards. This must not enter this input.
  if(phase==1&&branches>1){result(d,"scan/1",answer);}
  pid_t pid=fork();assert(pid>=0);t=now();if(!pid){char b[32];snprintf(b,sizeof b,"%d",branches);execl(argv[0],argv[0],"child",input,output,source,b,(char*)0);_exit(127);}int status;struct rusage usage;assert(wait4(pid,&status,0,&usage)==pid);double eval_ms=now()-t;int success=WIFEXITED(status)&&WEXITSTATUS(status)==0;
  double validation_ms=0,admit_ms=0,publish_ms=0;
  if(success){t=now();validate(d,output);validation_ms=now()-t;t=now();admit(d);admit_ms=now()-t;t=now();publish(d);publish_ms=now()-t;
   int expected=phase==0?branches:phase==1?branches-1+findings:phase==2?branches*findings:0;assert(count(d,"SELECT count(*) FROM pending")==expected);
   if(phase==1){assert(count(d,"SELECT count(*) FROM calls WHERE key LIKE 'verify/0/%'")==findings);assert(count(d,"SELECT count(*) FROM calls WHERE key LIKE 'verify/1/%'")==0);assert(count(d,"SELECT count(*) FROM pending p JOIN calls c USING(key) WHERE c.result IS NOT NULL")>=1);}
   if(phase==3){assert(count(d,"SELECT outcome FROM run")==branches*findings);assert(count(d,"SELECT count(*) FROM calls")==branches*(1+findings));}
  }
  if(!success){assert(count(d,"SELECT count(*) FROM calls")==before_calls);assert(count(d,"SELECT count(*) FROM pending")==before_pending);}
  struct rusage parent;getrusage(RUSAGE_SELF,&parent);
  printf("{\"phase\":%d,\"branches\":%d,\"bytes_per_finding\":%d,\"findings\":%d,\"capture_bytes\":%ld,\"capture_ms\":%.3f,\"eval_ms\":%.3f,\"validation_ms\":%.3f,\"admission_ms\":%.3f,\"longest_admission_ms\":%.3f,\"publication_ms\":%.3f,\"child_peak_rss_bytes\":%ld,\"parent_peak_rss_bytes\":%ld,\"child_exit\":%d,\"child_signal\":%d,\"success\":%s,\"calls\":%d,\"pending\":%d}\n",phase,branches,bytes,findings,captured,capture_ms,eval_ms,validation_ms,admit_ms,longest_admission_ms,publish_ms,usage.ru_maxrss,parent.ru_maxrss,WIFEXITED(status)?WEXITSTATUS(status):-1,WIFSIGNALED(status)?WTERMSIG(status):0,success?"true":"false",count(d,"SELECT count(*) FROM calls"),count(d,"SELECT count(*) FROM pending"));fflush(stdout);if(!success)break;
 }
 free(answer);sqlite3_close(d);unlink(input);unlink(output);return 0;
}
