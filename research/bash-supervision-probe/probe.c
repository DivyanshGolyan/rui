// THROWAWAY: native parent supervision, not the OnePage Host or a product limit.
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
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

typedef struct { pid_t pid; int rd[2], file[2], status, reaped, failed, released; uint64_t size[2]; } Owner;
typedef struct { uint64_t footprint, rss; int fds, threads; } Metrics;
static struct proc_fdinfo fd_observer[8192];
static uint64_t now(void){struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000000000+t.tv_nsec;}
static Metrics metrics(void){
 task_vm_info_data_t vm; mach_msg_type_number_t n=TASK_VM_INFO_COUNT;
 assert(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&vm,&n)==KERN_SUCCESS);
 struct proc_taskinfo ti; assert(proc_pidinfo(getpid(),PROC_PIDTASKINFO,0,&ti,sizeof ti)==sizeof ti);
 return (Metrics){vm.phys_footprint,vm.resident_size,proc_pidinfo(getpid(),PROC_PIDLISTFDS,0,fd_observer,sizeof fd_observer)/(int)sizeof(struct proc_fdinfo),ti.pti_threadnum};
}
static void sample(Metrics *peak){Metrics m=metrics();if(m.footprint>peak->footprint)peak->footprint=m.footprint;if(m.rss>peak->rss)peak->rss=m.rss;if(m.fds>peak->fds)peak->fds=m.fds;if(m.threads>peak->threads)peak->threads=m.threads;}
static int scratch(void){char p[]="./capture-XXXXXX";int f=mkstemp(p);assert(f>=0);assert(unlink(p)==0);return f;}
static void stop(Owner *o){if(!o->reaped&&o->pid>0) {kill(-o->pid,SIGKILL);kill(o->pid,SIGKILL);} }
static Owner *cleanup_owners; static volatile sig_atomic_t cleanup_count;
static void abort_probe(int sig){for(int i=0;i<cleanup_count;i++)stop(&cleanup_owners[i]);_exit(128+sig);}
static unsigned char pattern(int owner,int stream){return (unsigned char)(1+(owner*2+stream)%250);}
static void child(int index,size_t bytes,const char *mode){
 char ready='r';if(write(3,&ready,1)!=1)_exit(90);close(3);
 char gate;while(read(0,&gate,1)<0&&errno==EINTR){} close(0);
 if(!strcmp(mode,"hold")){for(;;)pause();}
 if(!strcmp(mode,"eof")){close(1);close(2);struct timespec t={0,100000000};nanosleep(&t,NULL);_exit(0);}
 unsigned char buf[4096];
 for(int s=0;s<2;s++){memset(buf,pattern(index,s),sizeof buf);size_t off=0;while(off<bytes){size_t len=bytes-off<sizeof buf?bytes-off:sizeof buf;ssize_t n=write(s+1,buf,len);if(n<0&&errno==EINTR)continue;if(n<=0)_exit(91);off+=(size_t)n;}}
 _exit(0);
}
int main(int argc,char **argv){
 if(argc==6&&!strcmp(argv[1],"child")){child(atoi(argv[2]),strtoull(argv[3],0,10),argv[4]);}
 if(argc!=7){fprintf(stderr,"usage: probe count bytes mode waves quota cwd\n");return 2;}
 int count=atoi(argv[1]),waves=atoi(argv[4]);size_t bytes=strtoull(argv[2],0,10);const char *mode=argv[3];uint64_t quota=strtoull(argv[5],0,10);
 assert(count>0&&count<=1000&&waves>0&&waves<=10);assert(chdir(argv[6])==0);
 struct rlimit lim;assert(getrlimit(RLIMIT_NOFILE,&lim)==0);rlim_t need=(rlim_t)count*4+64;if(lim.rlim_cur<need){lim.rlim_cur=need<lim.rlim_max?need:lim.rlim_max;assert(setrlimit(RLIMIT_NOFILE,&lim)==0);}
 for(size_t i=0;i<sizeof fd_observer;i++)((volatile unsigned char*)fd_observer)[i]=0;
 Metrics base=metrics(),peak=base;Owner *owners=calloc((size_t)count,sizeof *owners);struct pollfd *polls=calloc((size_t)count*2,sizeof *polls);assert(owners&&polls);
 unsigned char window[16384];memset(window,0,sizeof window);uint64_t high_scratch=0,total_bytes=0;int launch_errno=0,total_started=0,total_ready=0,failures=0,cancelled=0,completed=0,cohort_max=0;uint64_t start=now();
 cleanup_owners=owners;signal(SIGTERM,abort_probe);signal(SIGINT,abort_probe);
 for(int wave=0;wave<waves;wave++){
  cleanup_count=0;
  for(int i=0;i<count;i++){owners[i]=(Owner){.rd={-1,-1},.file={-1,-1}};}
  int gate[2],ready[2];assert(pipe(gate)==0&&pipe(ready)==0);fcntl(ready[0],F_SETFL,O_NONBLOCK);int launched=0;
  for(int i=0;i<count;i++){
   Owner *o=&owners[i];int pipes[2][2];assert(pipe(pipes[0])==0&&pipe(pipes[1])==0);
   for(int s=0;s<2;s++){o->rd[s]=pipes[s][0];fcntl(o->rd[s],F_SETFL,O_NONBLOCK);o->file[s]=scratch();}
   posix_spawn_file_actions_t fa;posix_spawnattr_t attr;assert(posix_spawn_file_actions_init(&fa)==0&&posix_spawnattr_init(&attr)==0);
   assert(posix_spawn_file_actions_adddup2(&fa,gate[0],0)==0);
   assert(posix_spawn_file_actions_adddup2(&fa,pipes[0][1],1)==0&&posix_spawn_file_actions_adddup2(&fa,pipes[1][1],2)==0);
   assert(posix_spawn_file_actions_adddup2(&fa,ready[1],3)==0);
   assert(posix_spawnattr_setflags(&attr,POSIX_SPAWN_CLOEXEC_DEFAULT|POSIX_SPAWN_SETPGROUP)==0);assert(posix_spawnattr_setpgroup(&attr,0)==0);
   char idx[24],length[32];snprintf(idx,sizeof idx,"%d",i);snprintf(length,sizeof length,"%zu",bytes);
   // Real Bash dispatch; the model-selected fixture command replaces Bash with a tiny output producer.
   char *args[]={"/bin/bash","--noprofile","--norc","-c","exec \"$1\" child \"$2\" \"$3\" \"$4\" fixture","bash",argv[0],idx,length,(char*)mode,NULL};
   char *env[]={"PATH=/usr/bin:/bin","LC_ALL=C",NULL};
   int rc=posix_spawn(&o->pid,"/bin/bash",&fa,&attr,args,env);
   posix_spawn_file_actions_destroy(&fa);posix_spawnattr_destroy(&attr);close(pipes[0][1]);close(pipes[1][1]);
   if(rc){launch_errno=rc;for(int s=0;s<2;s++){close(o->rd[s]);close(o->file[s]);o->rd[s]=o->file[s]=-1;}break;}
   launched++;cleanup_count=launched;if(i%32==0)sample(&peak);
  }
  total_started+=launched;if(launched>cohort_max)cohort_max=launched;close(gate[0]);close(ready[1]);
  int seen=0;uint64_t deadline=now()+30000000000ULL;
  while(seen<launched&&now()<deadline){ssize_t n=read(ready[0],window,sizeof window);if(n>0)seen+=(int)n;else if(n==0)break;else{struct pollfd p={ready[0],POLLIN,0};poll(&p,1,20);}}
  total_ready+=seen;assert(seen==launched);close(ready[0]);sample(&peak);
  if(!strcmp(mode,"hold")){for(int i=0;i<launched;i++){owners[i].failed=2;stop(&owners[i]);}}
  close(gate[1]);uint64_t used=0;int live=launched;deadline=now()+60000000000ULL;
  while(live){
   if(now()>deadline){for(int i=0;i<launched;i++)stop(&owners[i]);fprintf(stderr,"supervisor deadline\n");return 3;}
   for(int i=0;i<launched;i++)for(int s=0;s<2;s++)polls[2*i+s]=(struct pollfd){owners[i].rd[s],POLLIN,0};
   int rc=poll(polls,(nfds_t)launched*2,10);if(rc<0&&errno==EINTR)continue;assert(rc>=0);
   for(int i=0;i<launched;i++){
    Owner *o=&owners[i];if(o->released)continue;
    for(int s=0;s<2;s++){
     if(o->rd[s]<0||!polls[2*i+s].revents)continue;
     ssize_t n=read(o->rd[s],window,sizeof window);
     if(n==0){close(o->rd[s]);o->rd[s]=-1;continue;}
     if(n<0){assert(errno==EAGAIN||errno==EINTR);continue;}
     if(o->failed)continue;
     if((uint64_t)n>quota-used){o->failed=1;stop(o);continue;}
     used+=(uint64_t)n;if(used>high_scratch)high_scratch=used;
     ssize_t wrote=write(o->file[s],window,(size_t)n);assert(wrote>=0);used-=(uint64_t)n-(uint64_t)wrote;o->size[s]+=(uint64_t)wrote;
     if(wrote!=n){o->failed=1;stop(o);}
    }
    if(!o->reaped){pid_t p=waitpid(o->pid,&o->status,WNOHANG);if(p==o->pid)o->reaped=1;else assert(p==0||(p<0&&errno==EINTR));}
    if(o->reaped&&o->rd[0]<0&&o->rd[1]<0){
     if(!o->failed){assert(WIFEXITED(o->status)&&WEXITSTATUS(o->status)==0);for(int s=0;s<2;s++)assert(o->size[s]==bytes);completed++;}
     else if(o->failed==2){assert(WIFSIGNALED(o->status)&&WTERMSIG(o->status)==SIGKILL);cancelled++;}else failures++;
     for(int s=0;s<2;s++){uint64_t off=0;while(off<o->size[s]){size_t n=o->size[s]-off<sizeof window?(size_t)(o->size[s]-off):sizeof window;assert(pread(o->file[s],window,n,(off_t)off)==(ssize_t)n);for(size_t j=0;j<n;j++)assert(window[j]==pattern(i,s));off+=n;}total_bytes+=o->size[s];assert(close(o->file[s])==0);o->file[s]=-1;used-=o->size[s];}
     o->released=1;live--;
    }
   }
   sample(&peak);
  }
  assert(used==0);sample(&peak);if(launch_errno)break;
 }
 cleanup_count=0;free(owners);free(polls);Metrics end=metrics();struct rusage usage;getrusage(RUSAGE_SELF,&usage);
 assert(end.fds==base.fds);
 printf("{\"requested\":%d,\"started\":%d,\"ready\":%d,\"cohort_max\":%d,\"completed\":%d,\"cancelled\":%d,\"capture_failures\":%d,\"launch_errno\":%d,\"owner_size\":%zu,\"owner_table_bytes\":%zu,\"poll_table_bytes\":%zu,\"shared_window_bytes\":%zu,\"baseline_footprint\":%llu,\"sampled_peak_footprint\":%llu,\"retained_footprint\":%llu,\"peak_rss\":%ld,\"baseline_fds\":%d,\"peak_fds\":%d,\"final_fds\":%d,\"peak_threads\":%d,\"captured_bytes\":%llu,\"peak_scratch\":%llu,\"elapsed_ms\":%.3f}\n",count,total_started,total_ready,cohort_max,completed,cancelled,failures,launch_errno,sizeof(Owner),sizeof(Owner)*(size_t)count,sizeof(struct pollfd)*(size_t)count*2,sizeof window,(unsigned long long)base.footprint,(unsigned long long)peak.footprint,(unsigned long long)end.footprint,usage.ru_maxrss,base.fds,peak.fds,end.fds,peak.threads,(unsigned long long)total_bytes,(unsigned long long)high_scratch,(double)(now()-start)/1e6);
 return 0;
}
