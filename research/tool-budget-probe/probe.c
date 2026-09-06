// Throwaway macOS resource-cost probe. No Bash, Git, SQLite or production Host.
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>
#define N 1000
static struct { unsigned char custody[128]; int fd[6]; pthread_t worker; } slots[N];
static pthread_mutex_t mutex=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond=PTHREAD_COND_INITIALIZER;
static int ready,done;
static void *worker(void *arg){
    (void)arg;volatile unsigned char stack[65536];
    for(size_t i=0;i<sizeof(stack);i++)stack[i]=(unsigned char)i;
    pthread_mutex_lock(&mutex);ready++;pthread_cond_broadcast(&cond);
    while(!done)pthread_cond_wait(&cond,&mutex);
    pthread_mutex_unlock(&mutex);
    unsigned total=0;for(size_t i=0;i<sizeof(stack);i++)total+=stack[i];
    return (void*)(size_t)total;
}
static void sample(const char *phase,int created){
    struct rusage_info_v4 u={0};struct proc_taskinfo t={0};struct proc_fdinfo fds[8192];
    if(proc_pid_rusage(getpid(),RUSAGE_INFO_V4,(rusage_info_t*)&u)||proc_pidinfo(getpid(),PROC_PIDTASKINFO,0,&t,sizeof(t))!=sizeof(t))exit(3);
    int b=proc_pidinfo(getpid(),PROC_PIDLISTFDS,0,fds,sizeof(fds));if(b<0)exit(3);
    printf("{\"phase\":\"%s\",\"physical\":%llu,\"rss\":%llu,\"virtual\":%llu,\"threads\":%d,\"fds\":%zu,\"workers_created\":%d}\n",phase,(unsigned long long)u.ri_phys_footprint,(unsigned long long)t.pti_resident_size,(unsigned long long)t.pti_virtual_size,t.pti_threadnum,b/sizeof(struct proc_fdinfo),created);fflush(stdout);
}
int main(void){
    struct rlimit r;if(getrlimit(RLIMIT_NOFILE,&r))return 2;
    if(r.rlim_cur<8192){r.rlim_cur=r.rlim_max<8192?r.rlim_max:8192;if(setrlimit(RLIMIT_NOFILE,&r))return 2;}
    memset(slots,0,sizeof(slots));sample("baseline",0);
    for(int i=0;i<N;i++){
        for(int j=0;j<2;j++){char path[]="/tmp/onepage-tool-resource-XXXXXX";int fd=mkstemp(path);if(fd<0){perror("scratch");return 2;}if(unlink(path))return 2;slots[i].fd[j]=fd;}
        if(pipe(&slots[i].fd[2])||pipe(&slots[i].fd[4])){perror("pipe");return 2;}
        // Fixture retains write ends too; production Host retains only read ends.
        if(write(slots[i].fd[3],"x",1)!=1||write(slots[i].fd[5],"x",1)!=1)return 2;
    }
    sample("pipes_and_files",0);
    pthread_attr_t attr;if(pthread_attr_init(&attr)||pthread_attr_setstacksize(&attr,256*1024))return 2;
    int created=0,create_error=0;
    for(;created<N;created++){create_error=pthread_create(&slots[created].worker,&attr,worker,NULL);if(create_error)break;}
    pthread_attr_destroy(&attr);
    pthread_mutex_lock(&mutex);while(ready<created)pthread_cond_wait(&cond,&mutex);pthread_mutex_unlock(&mutex);
    sample("workers_ready",created);printf("{\"create_error\":%d,\"message\":\"%s\"}\n",create_error,create_error?strerror(create_error):"none");fflush(stdout);
    pthread_mutex_lock(&mutex);done=1;pthread_cond_broadcast(&cond);pthread_mutex_unlock(&mutex);
    for(int i=0;i<created;i++){void *result;if(pthread_join(slots[i].worker,&result)||(size_t)result!=8355840)return 3;}
    sample("workers_joined",created);
    for(int i=0;i<N;i++)for(int j=0;j<6;j++)if(close(slots[i].fd[j]))return 3;
    sample("released",created);return create_error?4:0;
}
