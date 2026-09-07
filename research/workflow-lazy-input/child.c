// THROWAWAY native lookup. No SQLite calls or JS-visible files/handles.
#include "common.h"
#include <malloc/malloc.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/stat.h>
static size_t engine_now,engine_peak,native_now,native_peak;
static uint64_t decoded,decoded_bytes,probes,count,directory_size,data_size;
static int error_code;
static double cpu_start;
static int lazy;
static JSValue cached_fn;
static void account_alloc(void *p) { if(p){engine_now+=malloc_size(p);if(engine_now>engine_peak)engine_peak=engine_now;} }
static void *tracked_malloc(void *o,size_t size) {(void)o;void *p=malloc(size);account_alloc(p);return p;}
static void *tracked_calloc(void *o,size_t n,size_t size) {(void)o;void *p=calloc(n,size);account_alloc(p);return p;}
static void tracked_free(void *o,void *p) {(void)o;if(p)engine_now-=malloc_size(p);free(p);}
static void *tracked_realloc(void *o,void *p,size_t size) {(void)o;size_t old=p?malloc_size(p):0;if(!size){tracked_free(o,p);return NULL;}void *q=realloc(p,size);if(q){engine_now-=old;account_alloc(q);}return q;}
static int budget(void) {if(process_ms()-cpu_start>=1000){error_code=21;return 0;}return 1;}
static int interrupt(JSRuntime *rt,void *opaque) {(void)rt;(void)opaque;return !budget();}
static int input_read(int fd,void *target,size_t size,uint64_t at,uint64_t total) {
 if(at>total||size>total-at){error_code=22;return 0;}
 char *p=target;
 while(size){if(!budget())return 0;size_t take=size<WINDOW?size:WINDOW;ssize_t n=pread(fd,p,take,at);if(n<0&&errno==EINTR)continue;if(n<=0){error_code=22;return 0;}p+=n;size-=n;at+=n;}
 return 1;
}
static int entry_at(uint64_t i,Entry *entry){if(i>=count){error_code=22;return 0;}return input_read(3,entry,sizeof(*entry),8+i*sizeof(*entry),directory_size);}
static int compare_key(Entry entry,const char *key,size_t len,int *order) {
 unsigned char window[WINDOW];uint64_t shared=entry.key_len<len?entry.key_len:len;
 for(uint64_t at=0;at<shared;){size_t take=shared-at<WINDOW?shared-at:WINDOW;if(!input_read(3,window,take,entry.key_at+at,directory_size))return 0;int c=memcmp(key+at,window,take);if(c){*order=c;return 1;}at+=take;}
 *order=len<entry.key_len?-1:len>entry.key_len?1:0;return 1;
}
static int find(const char *key,size_t len,Entry *entry) {
 uint64_t lo=0,hi=count;
 while(lo<hi){uint64_t mid=lo+(hi-lo)/2;int order;probes++;if(!entry_at(mid,entry)||!compare_key(*entry,key,len,&order))return -1;if(!order)return 1;if(order<0)hi=mid;else lo=mid+1;}
 return 0;
}
static JSValue decode(JSContext *ctx,Entry entry) {
 if(entry.body_len>SIZE_MAX-1){error_code=22;return JS_ThrowInternalError(ctx,"invalid input range");}
 // The prototype holds ONE encoded result contiguously for JS_ParseJSON.
 // Its native allocation is measured; arbitrary-size streaming conversion is not claimed.
 char *body=malloc(entry.body_len+1);if(!body){error_code=20;return JS_ThrowOutOfMemory(ctx);}native_now+=entry.body_len+1;if(native_now>native_peak)native_peak=native_now;
 if(!input_read(4,body,entry.body_len,entry.body_at,data_size)){free(body);native_now-=entry.body_len+1;return JS_ThrowInternalError(ctx,"input unavailable");}
 body[entry.body_len]=0;JSValue value=JS_ParseJSON(ctx,body,entry.body_len,"captured outcome");free(body);native_now-=entry.body_len+1;decoded++;decoded_bytes+=entry.body_len;
 if(!budget()){JS_FreeValue(ctx,value);return JS_ThrowInternalError(ctx,"CpuTime");}
 return value;
}
static JSValue lookup(JSContext *ctx,JSValueConst self,int argc,JSValueConst *args) {
 (void)self;(void)argc;
 if(!budget())return JS_ThrowInternalError(ctx,"CpuTime");
 if(!lazy)return JS_Call(ctx,cached_fn,JS_UNDEFINED,1,args);
 size_t len;const char *key=JS_ToCStringLen(ctx,&len,args[0]);if(!key)return JS_EXCEPTION;Entry entry;int found=find(key,len,&entry);JS_FreeCString(ctx,key);
 if(found<0)return JS_ThrowInternalError(ctx,"invalid snapshot");if(!found)return JS_UNDEFINED;
 if(entry.tag!=1&&entry.tag!=2){error_code=22;return JS_ThrowInternalError(ctx,"invalid outcome tag");}
 JSValue value=decode(ctx,entry);if(JS_IsException(value))return value;if(entry.tag==2)return JS_Throw(ctx,value);return value;
}
static JSValue emit(JSContext *ctx,JSValueConst self,int argc,JSValueConst *args) {
 (void)self;(void)argc;if(!budget())return JS_ThrowInternalError(ctx,"CpuTime");
 JSValue json=JS_JSONStringify(ctx,args[0],JS_UNDEFINED,JS_UNDEFINED);if(JS_IsException(json))return json;size_t len;const char *bytes=JS_ToCStringLen(ctx,&len,json);if(!bytes){JS_FreeValue(ctx,json);return JS_EXCEPTION;}
 int okay=1;for(size_t at=0;at<len;){if(!budget()){okay=0;break;}size_t take=len-at<WINDOW?len-at:WINDOW;write_all(1,bytes+at,take);at+=take;}
 if(okay)write_all(1,"\n",1);JS_FreeCString(ctx,bytes);JS_FreeValue(ctx,json);return okay?JS_UNDEFINED:JS_ThrowInternalError(ctx,"CpuTime");
}
static JSValue native_cpu(JSContext *ctx,JSValueConst self,int argc,JSValueConst *args){(void)self;(void)argc;(void)args;volatile uint64_t x=0;while(budget()){for(int i=0;i<4096;i++)x+=i;}return JS_ThrowInternalError(ctx,"CpuTime");}
static JSValue native_wall(JSContext *ctx,JSValueConst self,int argc,JSValueConst *args){(void)ctx;(void)self;(void)argc;(void)args;sleep(10);return JS_UNDEFINED;}
static int checked(JSContext *ctx,JSValue value) {
 if(!JS_IsException(value)){JS_FreeValue(ctx,value);return 1;}
 JSValue ex=JS_GetException(ctx);const char *text=JS_ToCString(ctx,ex);
 if(!error_code)error_code=text&&strstr(text,"out of memory")?20:23;
 fprintf(stderr,"exception: %s\n",text?text:"unavailable");if(text)JS_FreeCString(ctx,text);JS_FreeValue(ctx,ex);return 0;
}
int main(int argc,char **argv) {
 assert(argc==4);lazy=!strcmp(argv[1],"lazy");int branches=atoi(argv[2]);const char *flow=argv[3];cpu_start=process_ms();
 struct rlimit limit={1,2};assert(!setrlimit(RLIMIT_CPU,&limit));
 assert((fcntl(3,F_GETFL)&O_ACCMODE)==O_RDONLY&&(fcntl(4,F_GETFL)&O_ACCMODE)==O_RDONLY);
 struct stat st;assert(!fstat(3,&st));directory_size=st.st_size;assert(!fstat(4,&st));data_size=st.st_size;
 if(!input_read(3,&count,8,0,directory_size)||directory_size<8||count>(directory_size-8)/sizeof(Entry))return 22;
 JSMallocFunctions functions={tracked_calloc,tracked_malloc,tracked_free,tracked_realloc,malloc_size};
 JSRuntime *rt=JS_NewRuntime2(&functions,NULL);assert(rt);JS_SetMemoryLimit(rt,16*1024*1024);JS_SetInterruptHandler(rt,interrupt,NULL);JSContext *ctx=JS_NewContext(rt);assert(ctx);
 JSValue global=JS_GetGlobalObject(ctx);JS_SetPropertyStr(ctx,global,"readAnswer",JS_NewCFunction(ctx,lookup,"readAnswer",1));JS_SetPropertyStr(ctx,global,"emit",JS_NewCFunction(ctx,emit,"emit",1));JS_SetPropertyStr(ctx,global,"burnNative",JS_NewCFunction(ctx,native_cpu,"burnNative",0));JS_SetPropertyStr(ctx,global,"stallNative",JS_NewCFunction(ctx,native_wall,"stallNative",0));
 char source[8192];size_t used=0;ssize_t got;while((got=read(0,source+used,sizeof(source)-1-used))>0){used+=got;assert(used<sizeof(source)-1);}assert(got==0);source[used]=0;
 int okay=checked(ctx,JS_Eval(ctx,source,used,"workflow.js",JS_EVAL_TYPE_GLOBAL));cached_fn=JS_GetPropertyStr(ctx,global,"cached");
 if(okay&&!lazy){JSValue preload=JS_GetPropertyStr(ctx,global,"preload");for(uint64_t i=0;i<count&&okay;i++){Entry entry;if(!entry_at(i,&entry)){okay=0;break;}char *key=malloc(entry.key_len+1);assert(key);assert(input_read(3,key,entry.key_len,entry.key_at,directory_size));key[entry.key_len]=0;JSValue args[]={JS_NewStringLen(ctx,key,entry.key_len),decode(ctx,entry)};free(key);if(JS_IsException(args[0])||JS_IsException(args[1])){JS_FreeValue(ctx,args[0]);JS_FreeValue(ctx,args[1]);okay=checked(ctx,JS_EXCEPTION);break;}okay=checked(ctx,JS_Call(ctx,preload,JS_UNDEFINED,2,args));JS_FreeValue(ctx,args[0]);JS_FreeValue(ctx,args[1]);}JS_FreeValue(ctx,preload);}
 uint64_t preload_decoded=decoded;
 if(okay){JSValue start=JS_GetPropertyStr(ctx,global,"start");JSValue args[]={JS_NewInt32(ctx,branches),JS_NewString(ctx,flow)};okay=checked(ctx,JS_Call(ctx,start,JS_UNDEFINED,2,args));JS_FreeValue(ctx,args[1]);JS_FreeValue(ctx,start);}
 JSContext *job;int jobs=0;while(okay&&budget()){int rc=JS_ExecutePendingJob(rt,&job);if(rc==0)break;if(rc<0){okay=checked(job,JS_EXCEPTION);break;}jobs++;}
 JSValue failed=JS_GetPropertyStr(ctx,global,"failure");if(!JS_IsUndefined(failed)){const char *text=JS_ToCString(ctx,failed);if(!error_code)error_code=text&&strstr(text,"out of memory")?20:23;fprintf(stderr,"workflow rejected: %s\n",text?text:"unknown");if(text)JS_FreeCString(ctx,text);okay=0;}JS_FreeValue(ctx,failed);
 JSMemoryUsage usage;JS_ComputeMemoryUsage(rt,&usage);JS_FreeValue(ctx,cached_fn);JS_FreeValue(ctx,global);JS_FreeContext(ctx);JS_FreeRuntime(rt);if(!budget())okay=0;
 fprintf(stderr,"{\"engine_backing_peak\":%zu,\"engine_remaining_after_teardown\":%zu,\"engine_live_before_teardown\":%lld,\"native_body_peak\":%zu,\"decoded\":%llu,\"preload_decoded\":%llu,\"decoded_bytes\":%llu,\"directory_probes\":%llu,\"jobs\":%d,\"cpu_ms\":%.3f,\"error_code\":%d}\n",engine_peak,engine_now,(long long)usage.memory_used_size,native_peak,(unsigned long long)decoded,(unsigned long long)preload_decoded,(unsigned long long)decoded_bytes,(unsigned long long)probes,jobs,process_ms()-cpu_start,error_code);
 assert(engine_now==0);return error_code?error_code:okay?0:23;
}
