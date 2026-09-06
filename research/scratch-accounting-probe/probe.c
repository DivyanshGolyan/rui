// THROWAWAY: real unlinked files, owned serially; one shared logical-byte cap.
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
struct budget { uint64_t limit; _Atomic uint64_t used; };
struct file { int fd; uint64_t size; };
static bool reserve(struct budget*b,uint64_t n){
    uint64_t old=atomic_load_explicit(&b->used,memory_order_relaxed);
    do {if(n>b->limit-old)return false;}
    while(!atomic_compare_exchange_weak_explicit(&b->used,&old,old+n,memory_order_relaxed,memory_order_relaxed));
    return true;
}
static void give_back(struct budget*b,uint64_t n){uint64_t old=atomic_fetch_sub_explicit(&b->used,n,memory_order_relaxed);assert(old>=n);}
static struct file make_file(void){char path[]="/tmp/onepage-scratch-account-XXXXXX";int fd=mkstemp(path);assert(fd>=0);assert(!unlink(path));return (struct file){fd,0};}
// Caller exclusively owns f. Only this boundary may grow its underlying file.
static ssize_t put(struct budget*b,struct file*f,const void*data,size_t n,uint64_t offset){
    if(offset>INT64_MAX||n>(uint64_t)INT64_MAX-offset){errno=EOVERFLOW;return -1;}
    if(!n)return 0;
    uint64_t end=offset+n,old=f->size,growth=end>old?end-old:0;
    if(b&&growth&&!reserve(b,growth)){errno=ENOSPC;return -1;}
    ssize_t wrote=pwrite(f->fd,data,n,(off_t)offset);
    uint64_t actual_end=wrote>0?offset+(uint64_t)wrote:old;
    uint64_t actual_size=actual_end>old?actual_end:old;
    f->size=actual_size;
    uint64_t refund=growth-(actual_size-old);
    if(b&&refund)give_back(b,refund);
    return wrote;
}
static int shrink(struct budget*b,struct file*f,uint64_t size){assert(size<=f->size);if(ftruncate(f->fd,(off_t)size))return -1;uint64_t removed=f->size-size;f->size=size;if(b&&removed)give_back(b,removed);return 0;}
static void release_file(struct budget*b,struct file*f){assert(!close(f->fd));if(b&&f->size)give_back(b,f->size);f->fd=-1;f->size=0;}
static void verify_file(struct file*f){struct stat s;assert(!fstat(f->fd,&s));assert((uint64_t)s.st_size==f->size);}
static double stamp(clockid_t id){struct timespec t;assert(!clock_gettime(id,&t));return t.tv_sec+t.tv_nsec/1e9;}
static void correctness(void){
    char data[32];memset(data,'x',sizeof(data));struct budget b={.limit=32};struct file a=make_file(),c=make_file();
    assert(put(&b,&a,data,16,0)==16);assert(b.used==16);assert(put(&b,&a,data,4,2)==4);assert(b.used==16);assert(put(&b,&c,data,16,0)==16);assert(b.used==32);
    assert(put(&b,&a,data,1,16)==-1&&errno==ENOSPC);assert(b.used==32);verify_file(&a);verify_file(&c);
    assert(!shrink(&b,&a,8));assert(b.used==24);assert(put(&b,&c,data,8,16)==8);assert(b.used==32);
    release_file(&b,&a);assert(b.used==24);release_file(&b,&c);assert(!b.used);
    a=make_file();assert(put(&b,&a,data,2,10)==2);assert(a.size==12&&b.used==12);verify_file(&a);
    assert(put(&b,&a,data,0,INT64_MAX)==0);assert(b.used==12);assert(put(&b,&a,data,2,INT64_MAX)==-1&&errno==EOVERFLOW);assert(b.used==12);release_file(&b,&a);
    // Kernel-induced partial write and error, without filling the user's volume.
    struct rlimit saved;assert(!getrlimit(RLIMIT_FSIZE,&saved));struct rlimit small=saved;small.rlim_cur=10;signal(SIGXFSZ,SIG_IGN);assert(!setrlimit(RLIMIT_FSIZE,&small));
    a=make_file();assert(put(&b,&a,data,16,0)==10);assert(a.size==10&&b.used==10);verify_file(&a);
    assert(put(&b,&a,data,1,10)==-1&&errno==EFBIG);assert(b.used==10);
    assert(!setrlimit(RLIMIT_FSIZE,&saved));release_file(&b,&a);assert(!b.used);
    // Inject an invalid descriptor to exercise the real ftruncate error path.
    a=make_file();assert(put(&b,&a,data,16,0)==16);struct file view={-1,a.size};assert(shrink(&b,&view,8)==-1&&errno==EBADF);assert(b.used==16&&view.size==16);release_file(&b,&a);assert(!b.used);
    printf("{\"case\":\"correctness\",\"passed\":true,\"budget_bytes\":%zu,\"file_state_bytes\":%zu,\"logical_size_bytes\":%zu,\"lock_free\":%s}\n",sizeof(b),sizeof(a),sizeof(a.size),atomic_is_lock_free(&b.used)?"true":"false");
}
static pthread_mutex_t gate=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t wake=PTHREAD_COND_INITIALIZER;
static int ready,go;
struct job { struct budget*b; uint64_t bytes; int race; uint64_t accepted,rejected; };
static void *writer(void*arg){struct job*j=arg;struct file f=make_file();char data[16384];memset(data,'x',sizeof(data));pthread_mutex_lock(&gate);ready++;pthread_cond_broadcast(&wake);while(!go)pthread_cond_wait(&wake,&gate);pthread_mutex_unlock(&gate);
    for(uint64_t at=0;at<j->bytes;at+=sizeof(data)){ssize_t n=put(j->b,&f,data,sizeof(data),f.size);if(n<0){assert(j->race&&errno==ENOSPC);j->rejected++;break;}assert(n==sizeof(data));j->accepted++;}
    verify_file(&f);
    if(j->race){pthread_mutex_lock(&gate);ready++;pthread_cond_broadcast(&wake);while(go==1)pthread_cond_wait(&wake,&gate);pthread_mutex_unlock(&gate);}
    release_file(j->b,&f);return NULL;}
static void measure(int count,int accounting,int race){
    struct budget b={.limit=race?65536:256ULL*1024*1024};pthread_t threads[8];struct job jobs[8];
    for(int i=0;i<count;i++){jobs[i]=(struct job){accounting?&b:NULL,race?65536:128ULL*1024*1024/count,race,0,0};assert(!pthread_create(&threads[i],NULL,writer,&jobs[i]));}
    pthread_mutex_lock(&gate);while(ready<count)pthread_cond_wait(&wake,&gate);double start=stamp(CLOCK_MONOTONIC),cpu=stamp(CLOCK_PROCESS_CPUTIME_ID);go=1;pthread_cond_broadcast(&wake);
    if(race){while(ready<count*2)pthread_cond_wait(&wake,&gate);assert(b.used==b.limit);go=2;pthread_cond_broadcast(&wake);}pthread_mutex_unlock(&gate);
    for(int i=0;i<count;i++)assert(!pthread_join(threads[i],NULL));
    double wall=stamp(CLOCK_MONOTONIC)-start,usedcpu=stamp(CLOCK_PROCESS_CPUTIME_ID)-cpu;assert(!b.used);
    uint64_t chunks=0,denied=0;for(int i=0;i<count;i++){chunks+=jobs[i].accepted;denied+=jobs[i].rejected;}
    if(race)assert(chunks==4&&denied>=7);
    struct rusage_info_v4 u={0};assert(!proc_pid_rusage(getpid(),RUSAGE_INFO_V4,(rusage_info_t*)&u));
    printf("{\"case\":\"%s\",\"writers\":%d,\"accounting\":%d,\"wall_seconds\":%.9f,\"cpu_seconds\":%.9f,\"chunks\":%llu,\"denied\":%llu,\"physical_after\":%llu,\"physical_lifetime_peak\":%llu,\"final_charge\":%llu}\n",race?"concurrent_cap":"throughput",count,accounting,wall,usedcpu,chunks,denied,u.ri_phys_footprint,u.ri_lifetime_max_phys_footprint,(unsigned long long)b.used);
}
int main(int argc,char**argv){if(argc==1){correctness();return 0;}if(!strcmp(argv[1],"race")){measure(8,1,1);return 0;}assert(argc==3);int n=atoi(argv[1]);assert(n==1||n==2||n==8);measure(n,atoi(argv[2]),0);return 0;}
