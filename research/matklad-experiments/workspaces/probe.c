#include <assert.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

typedef struct { uint8_t *p; size_t n; uint64_t generation; int stage; } Workspace;
typedef struct { uint64_t generation; int stage; } Borrow;
static Borrow enter(Workspace *w, int stage) { w->generation++; w->stage=stage; return (Borrow){w->generation,stage}; }
static int valid(const Workspace *w, Borrow b) { return w->generation==b.generation && w->stage==b.stage; }
static uint64_t ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (uint64_t)t.tv_sec*1000000000ull+t.tv_nsec; }
static void sample(uint64_t *rss, uint64_t *footprint) {
  task_vm_info_data_t info; mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
  assert(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&info,&count)==KERN_SUCCESS);
  *rss=info.resident_size; *footprint=info.phys_footprint;
}
static volatile uint64_t checksum;
static void stage(Workspace *w, int kind, int iteration) {
  Borrow b=enter(w,kind); assert(valid(w,b));
  memset(w->p,(unsigned char)(kind+iteration),w->n);
  uint64_t sum=0; for(size_t i=0;i<w->n;i+=4096) sum+=w->p[i];
  assert(sum==((w->n+4095)/4096)*(unsigned char)(kind+iteration));
  checksum+=sum; assert(valid(w,b));
}
int main(int argc,char **argv) {
  assert(argc==4); const char *mode=argv[1]; size_t n=strtoull(argv[2],0,10); int cycles=atoi(argv[3]);
  assert(n>0 && n<=32*1024*1024 && cycles>0 && cycles<=100);
  int shared=!strcmp(mode,"shared"); assert(shared || !strcmp(mode,"separate_eager") || !strcmp(mode,"separate_lazy"));
  uint64_t base_rss,base_fp,initial_rss,initial_fp,after_rss,after_fp,end_rss,end_fp;
  sample(&base_rss,&base_fp);
  uint8_t *a=malloc(n), *b=shared?a:malloc(n); assert(a&&b);
  if(strcmp(mode,"separate_lazy")) { memset(a,1,n); if(!shared) memset(b,2,n); }
  sample(&initial_rss,&initial_fp);
  Workspace w={a,n,0,0}; Borrow old=enter(&w,1); enter(&w,2);
  int stale_rejected=!valid(&w,old); assert(stale_rejected);
  // Negative control: stage-only validity would wrongly accept an old view after ABA.
  Borrow aba=enter(&w,1); enter(&w,2); enter(&w,1);
  int unsafe_stage_only_accepts=(w.stage==aba.stage); assert(unsafe_stage_only_accepts && !valid(&w,aba));
  uint64_t start=ns();
  for(int i=0;i<cycles;i++) { w.p=a; stage(&w,1,i); w.p=b; stage(&w,2,i); }
  uint64_t elapsed=ns()-start; sample(&after_rss,&after_fp);
  // Return to idle: mappings retained, borrow invalidated, no stage data persists.
  enter(&w,0); sample(&end_rss,&end_fp);
  struct rusage r; assert(!getrusage(RUSAGE_SELF,&r));
  printf("{\"mode\":\"%s\",\"stage_bytes\":%zu,\"cycles\":%d,\"allocated_bytes\":%zu,\"base_rss\":%llu,\"base_footprint\":%llu,\"initial_rss\":%llu,\"initial_footprint\":%llu,\"after_rss\":%llu,\"after_footprint\":%llu,\"idle_rss\":%llu,\"idle_footprint\":%llu,\"peak_rss\":%ld,\"elapsed_ns\":%llu,\"processed_bytes\":%zu,\"stale_rejected\":%d,\"unsafe_stage_only_accepts\":%d,\"checksum\":%llu}\n",mode,n,cycles,shared?n:n*2,base_rss,base_fp,initial_rss,initial_fp,after_rss,after_fp,end_rss,end_fp,r.ru_maxrss,elapsed,n*2*(size_t)cycles,stale_rejected,unsafe_stage_only_accepts,checksum);
  free(a); if(!shared)free(b); return 0;
}
