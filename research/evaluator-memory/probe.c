/* Research-only translation unit: uses pinned engine internals to fill a final
 * string. No production bridge or dependency is modified. */
#include "quickjs.c"
#include <unistd.h>
#include <sys/resource.h>
#ifdef __APPLE__
#include <mach/mach.h>
#include <malloc/malloc.h>
#else
#include <malloc.h>
#endif
static size_t live, peak, native_live, native_peak, read_bytes, calls;
static uint64_t footprint_peak;
static int input_fd, buffered, native_fail;
static uint64_t result_size, result_count;
static const char *failure = "none";
static size_t usable(const void *p) {
#ifdef __APPLE__
 return p ? malloc_size(p) : 0;
#else
 return p ? malloc_usable_size((void*)p) : 0;
#endif
}
static void *am(void *o,size_t n) { (void)o; void *p=malloc(n); live+=usable(p); if(live>peak)peak=live; return p; }
static void af(void *o,void *p) { (void)o; live-=usable(p); free(p); }
static void *ac(void *o,size_t n,size_t s) { if(s && n>SIZE_MAX/s)return NULL; void*p=am(o,n*s);if(p)memset(p,0,n*s);return p; }
static void *ar(void *o,void*p,size_t n) { (void)o; if(!n){af(o,p);return NULL;} size_t old=usable(p);void*q=realloc(p,n);if(q){live=live-old+usable(q);if(live>peak)peak=live;}return q; }
static uint64_t footprint(void) {
#ifdef __APPLE__
 struct task_vm_info t; mach_msg_type_number_t n=TASK_VM_INFO_COUNT;
 if(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&t,&n)!=KERN_SUCCESS)abort();
 return t.phys_footprint;
#else
 return 0; /* Linux physical footprint is deliberately not conflated with RSS. */
#endif
}
static void sample(void){uint64_t p=footprint();if(p>footprint_peak)footprint_peak=p;}
static void report(JSRuntime *rt,const char*phase){JSMemoryUsage m={0};if(rt)JS_ComputeMemoryUsage(rt,&m);sample();struct rusage r;getrusage(RUSAGE_SELF,&r);
 printf("{\"phase\":\"%s\",\"engine_allocator_live\":%zu,\"engine_allocator_peak\":%zu,\"engine_accounted\":%lld,\"js_memory_used\":%lld,\"native_live\":%zu,\"native_peak\":%zu,\"physical_footprint\":%llu,\"sampled_footprint_peak\":%llu,\"maxrss_raw\":%ld,\"read_bytes\":%zu,\"decode_calls\":%zu,\"failure\":\"%s\"}\n",phase,live,peak,(long long)m.malloc_size,(long long)m.memory_used_size,native_live,native_peak,(unsigned long long)footprint(),(unsigned long long)footprint_peak,r.ru_maxrss,read_bytes,calls,failure);fflush(stdout);}
static int exact(void *p,size_t n,uint64_t off){while(n){ssize_t k=pread(input_fd,p,n,off);if(k<=0){failure="short_read";return -1;}read_bytes+=k;n-=k;off+=k;p=(char*)p+k;}return 0;}
/* Fixture integers are LE. Metadata has no resident per-result index. */
static uint32_t u32(const unsigned char*p){return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static JSValue lookup(JSContext*c,JSValueConst this_val,int argc,JSValueConst*argv){(void)this_val;int32_t index=0;calls++;
 if(argc && JS_ToInt32(c,&index,argv[0])<0)return JS_EXCEPTION;
 if(index<0 || (uint64_t)index>=result_count){failure="invalid_range";return JS_ThrowRangeError(c,"range");}
 size_t cap=buffered?result_size:16384;size_t native_limit=native_fail?8192:8*1024*1024;unsigned char*buf=cap>native_limit?NULL:malloc(cap);
 if(!buf){failure="native_exhaustion";return JS_ThrowOutOfMemory(c);}native_live=cap;if(cap>native_peak)native_peak=cap;
 uint64_t pos=(uint64_t)index*result_size,end=pos+result_size,base=pos;JSValue arr=JS_UNDEFINED;
 if(buffered && exact(buf,cap,pos))goto bad;
 unsigned char h[8];
 if(buffered)memcpy(h,buf,8);else if(exact(h,8,pos))goto bad;pos+=8;
 uint32_t count=u32(h),width=u32(h+4);if(width!=1&&width!=2){failure="malformed_width";goto bad;}
 arr=JS_NewArray(c);if(JS_IsException(arr))goto oom;
 for(uint32_t i=0;i<count;i++){
  if(end-pos<4){failure="invalid_range";goto bad;}if(buffered)memcpy(h,buf+pos-base,4);else if(exact(h,4,pos))goto bad;pos+=4;
  uint32_t len=u32(h);uint64_t bytes=(uint64_t)len*width;
  if(len>INT32_MAX || bytes>end-pos){failure="invalid_range";goto bad;}
  JSString*s=js_alloc_string(c,len,width==2);if(!s)goto oom;
  JSValue v=JS_MKPTR(JS_TAG_STRING,s);unsigned char*dest=width==2?(unsigned char*)str16(s):str8(s);
  for(size_t done=0;done<bytes;){size_t n=bytes-done;if(n>16384)n=16384;
   if(buffered)memcpy(dest+done,buf+pos-base+done,n);
   else {if(exact(buf,n,pos+done)){JS_FreeValue(c,v);goto bad;}memcpy(dest+done,buf,n);}done+=n;}
  if(width==1)dest[bytes]=0;pos+=bytes;
  if(JS_SetPropertyUint32(c,arr,i,v)<0)goto oom;sample();
 }
 if(pos!=end){failure="trailing_bytes";goto bad;}
 sample();free(buf);native_live=0;
 JSValue p=JS_NewSettledPromise(c,false,arr);JS_FreeValue(c,arr);if(JS_IsException(p))failure="engine_exhaustion";return p;
 oom:failure="engine_exhaustion";
 bad: JS_FreeValue(c,arr);free(buf);native_live=0;
 if(!strcmp(failure,"engine_exhaustion"))return JS_EXCEPTION;
 return JS_ThrowTypeError(c,"prepared input failure");
}
static JSValue mark(JSContext*c,JSValueConst t,int n,JSValueConst*v){(void)t;(void)n;const char*s=JS_ToCString(c,v[0]);report(JS_GetRuntime(c),s?s:"mark");JS_FreeCString(c,s);return JS_UNDEFINED;}
int main(int argc,char**argv){if(argc!=7)return 2;input_fd=atoi(argv[1]);result_size=strtoull(argv[2],0,10);result_count=strtoull(argv[3],0,10);buffered=atoi(argv[4]);native_fail=atoi(argv[5]);
 struct rlimit cpu={1,2},core={0,0};if(setrlimit(RLIMIT_CPU,&cpu)||setrlimit(RLIMIT_CORE,&core))return 3;
 JSMallocFunctions f={ac,am,af,ar,usable};JSRuntime*rt=JS_NewRuntime2(&f,NULL);if(!rt)return 4;JS_SetMemoryLimit(rt,16*1024*1024);JS_SetMaxStackSize(rt,512*1024);JSContext*c=JS_NewContext(rt);if(!c)return 5;
 JSValue g=JS_GetGlobalObject(c);JS_SetPropertyStr(c,g,"lookup",JS_NewCFunction(c,lookup,"lookup",1));JS_SetPropertyStr(c,g,"mark",JS_NewCFunction(c,mark,"mark",1));JS_FreeValue(c,g);report(rt,"cold");
 JSValue root=JS_Eval(c,argv[6],strlen(argv[6]),"fixture",JS_EVAL_TYPE_GLOBAL);int error=JS_IsException(root);JSContext*job;int job_status=0;while(!error&&(job_status=JS_ExecutePendingJob(rt,&job))>0){}if(job_status<0)error=1;
 if(!error && (!JS_IsObject(root) || JS_PromiseState(c,root)!=JS_PROMISE_FULFILLED))error=1;
 if(error && !strcmp(failure,"none"))failure="js_assertion_or_job";
 report(rt,error?"failed":"completed");JS_FreeValue(c,root);JSValue ex=JS_GetException(c);JS_FreeValue(c,ex);JS_RunGC(rt);report(rt,"released_idle");JS_FreeContext(c);JS_FreeRuntime(rt);report(NULL,"runtime_freed");close(input_fd);return error?10:0;
}
