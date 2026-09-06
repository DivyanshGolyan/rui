// THROWAWAY one-at-a-time evaluator driver; no Store or real control commands.
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach/mach.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static volatile sig_atomic_t active;
static void stop(int s){if(active>0)kill(active,SIGKILL);_exit(128+s);}
static uint64_t now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000000000+t.tv_nsec;}
static uint64_t footprint(pid_t pid){struct rusage_info_v4 r;if(proc_pid_rusage(pid,RUSAGE_INFO_V4,(rusage_info_t*)&r))return 0;return r.ri_phys_footprint;}
static int fds(void){struct proc_fdinfo f[64];int n=proc_pidinfo(getpid(),PROC_PIDLISTFDS,0,f,sizeof f);assert(n>=0);return n/(int)sizeof f[0];}
static void writeall(int f,char *p,size_t n){while(n){ssize_t k=write(f,p,n);if(k<0&&errno==EINTR)continue;assert(k>0);n-=(size_t)k;p+=k;}}
int main(int argc,char **argv){
 assert(argc>=3);signal(SIGTERM,stop);signal(SIGINT,stop);uint64_t baseline=footprint(getpid()),batch=now();int basefds=fds();
 for(int a=2;a<argc;a++){
  uint64_t start=now();int input=open(argv[a],O_RDONLY);assert(input>=0);int pipes[2][2];assert(pipe(pipes[0])==0&&pipe(pipes[1])==0);
  char path[2048];snprintf(path,sizeof path,"%s.out",argv[a]);int out=open(path,O_WRONLY|O_CREAT|O_TRUNC,0600);assert(out>=0);
  snprintf(path,sizeof path,"%s.err",argv[a]);int err=open(path,O_WRONLY|O_CREAT|O_TRUNC,0600);assert(err>=0);
  posix_spawn_file_actions_t fa;posix_spawnattr_t attr;assert(!posix_spawn_file_actions_init(&fa)&&!posix_spawnattr_init(&attr));
  assert(!posix_spawn_file_actions_adddup2(&fa,input,0));assert(!posix_spawn_file_actions_adddup2(&fa,pipes[0][1],1));assert(!posix_spawn_file_actions_adddup2(&fa,pipes[1][1],2));assert(!posix_spawnattr_setflags(&attr,POSIX_SPAWN_CLOEXEC_DEFAULT));
  char *args[]={argv[1],NULL};char *env[]={NULL};pid_t child;int rc=posix_spawn(&child,argv[1],&fa,&attr,args,env);assert(!rc);active=child;
  posix_spawn_file_actions_destroy(&fa);posix_spawnattr_destroy(&attr);close(input);close(pipes[0][1]);close(pipes[1][1]);
  fcntl(pipes[0][0],F_SETFL,O_NONBLOCK);fcntl(pipes[1][0],F_SETFL,O_NONBLOCK);
  int reaped=0,status=0,timedout=0,openstreams=2;uint64_t bytes[2]={0,0},childpeak=0,parentpeak=baseline,combined=baseline,maxgap=0,last=now(),samples=0;struct rusage usage={0};
  while(!reaped||openstreams){
   uint64_t t=now();if(t-last>maxgap)maxgap=t-last;last=t;
   uint64_t parent=footprint(getpid()),cf=reaped?0:footprint(child);if(cf)samples++;if(cf>childpeak)childpeak=cf;if(parent>parentpeak)parentpeak=parent;if(parent+cf>combined)combined=parent+cf;
   if(!reaped&&!timedout&&t-start>2000000000ULL){kill(child,SIGKILL);timedout=1;}
   struct pollfd pf[2]={{pipes[0][0],POLLIN,0},{pipes[1][0],POLLIN,0}};rc=poll(pf,2,1);if(rc<0&&errno==EINTR)continue;assert(rc>=0);
   char window[4096];
   for(int s=0;s<2;s++)if(pf[s].fd>=0&&pf[s].revents){ssize_t n=read(pf[s].fd,window,sizeof window);if(n==0){close(pipes[s][0]);pipes[s][0]=-1;openstreams--;}else if(n>0){bytes[s]+=(uint64_t)n;assert(bytes[s]<=(s?4096:1048576));writeall(s?err:out,window,(size_t)n);}else assert(errno==EAGAIN||errno==EINTR);}
   if(!reaped){pid_t p=wait4(child,&status,WNOHANG,&usage);if(p==child){reaped=1;active=0;}else assert(p==0||(p<0&&errno==EINTR));}
  }
  close(out);close(err);assert(fds()==basefds);
  printf("{\"ordinal\":%d,\"queue_wait_ms\":%.3f,\"service_ms\":%.3f,\"baseline_parent\":%llu,\"sampled_child_peak\":%llu,\"sampled_parent_peak\":%llu,\"sampled_combined_peak\":%llu,\"child_peak_rss\":%ld,\"child_samples\":%llu,\"loop_max_gap_ms\":%.3f,\"stdout_bytes\":%llu,\"stderr_bytes\":%llu,\"timeout\":%d,\"exit_code\":%d,\"signal\":%d,\"final_fds\":%d}\n",a-2,(double)(start-batch)/1e6,(double)(now()-start)/1e6,(unsigned long long)baseline,(unsigned long long)childpeak,(unsigned long long)parentpeak,(unsigned long long)combined,usage.ru_maxrss,(unsigned long long)samples,(double)maxgap/1e6,(unsigned long long)bytes[0],(unsigned long long)bytes[1],timedout,WIFEXITED(status)?WEXITSTATUS(status):-1,WIFSIGNALED(status)?WTERMSIG(status):0,fds());fflush(stdout);
 }
 return 0;
}
