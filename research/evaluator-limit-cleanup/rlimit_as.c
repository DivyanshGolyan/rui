#include <sys/resource.h>
#include <sys/mman.h>
#include <libproc.h>
#include <stdio.h>
#include <unistd.h>
#include <stdint.h>
#include <errno.h>
int main(void) {
    const size_t size=96u*1024u*1024u;
    struct rlimit lim={64u*1024u*1024u,64u*1024u*1024u},observed;
    if(setrlimit(RLIMIT_AS,&lim)!=0) {printf("{\"requested_limit\":67108864,\"setrlimit_succeeded\":false,\"errno\":%d}\n",errno);return 0;}
    if(getrlimit(RLIMIT_AS,&observed)!=0) return 2;
    volatile unsigned char *p=mmap(NULL,size,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    if(p==MAP_FAILED) {printf("{\"mapped\":false,\"errno\":%d}\n",errno);return 0;}
    for(size_t i=0;i<size;i+=4096) p[i]=(unsigned char)(i/4096);
    struct rusage_info_v4 ru={0};
    if(proc_pid_rusage(getpid(),RUSAGE_INFO_V4,(rusage_info_t*)&ru)!=0)return 3;
    printf("{\"limit\":%llu,\"mapped\":true,\"touched_span\":%zu,\"resident_bytes\":%llu,\"physical_bytes\":%llu}\n",(unsigned long long)observed.rlim_cur,size,(unsigned long long)ru.ri_resident_size,(unsigned long long)ru.ri_phys_footprint);
    return munmap((void*)p,size)!=0;
}
