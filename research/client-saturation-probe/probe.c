// THROWAWAY macOS Unix HTTP admission probe. No Host or semantic mutations.
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#define PROBE_MAX 1024
#define WINDOW 8192
#define REPORT (1024*1024)
extern int parse_head(const unsigned char *,size_t,uint64_t *,int *);
struct client { int fd, scratch, phase, ordinary, rejected, large; unsigned char *buf; size_t used,sent,pending; uint64_t body,output; double born,progress; };
static struct client clients[PROBE_MAX];
static int limit, ordinary_limit, active, ordinary;
static unsigned long rejected,completed,expired;
static double header_timeout,stall_timeout;
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }
static void release(struct client *c) {
    close(c->fd); if(c->scratch>=0)close(c->scratch);
    ordinary-=c->ordinary; active--; unsigned char *b=c->buf;
    memset(c,0,sizeof(*c)); c->fd=c->scratch=-1; c->buf=b;
}
static int scratch(void) { char path[]="/tmp/onepage-client-probe-XXXXXX"; int fd=mkstemp(path); if(fd<0)exit(3); if(unlink(path))exit(3); return fd; }
static void write_all(int fd,const void *p,size_t n) { while(n) { ssize_t r=write(fd,p,n); if(r<=0)exit(3); p=(const char*)p+r; n-=r; } }
static void response(struct client *c,int busy) {
    c->phase=2; c->sent=0; c->output=busy?0:c->large?REPORT:2;
    c->pending=snprintf((char*)c->buf+WINDOW,WINDOW,"HTTP/1.1 %s\r\nContent-Length: %llu\r\nConnection: close\r\n\r\n",busy?"503 Service Unavailable":"200 OK",(unsigned long long)c->output);
    c->progress=now();
}
static void sample(void) {
    struct rusage_info_v4 u={0};struct proc_taskinfo t={0};
    if(proc_pid_rusage(getpid(),RUSAGE_INFO_V4,(rusage_info_t*)&u)||proc_pidinfo(getpid(),PROC_PIDTASKINFO,0,&t,sizeof(t))!=sizeof(t))exit(3);
    unsigned long logical=0,allocated=0;int files=0,headers=0,uploads=0,downloads=0;
    for(int i=0;i<limit;i++){struct client*c=&clients[i];if(c->fd<0)continue;headers+=c->phase==0;uploads+=c->phase==1;downloads+=c->phase==2&&c->large;if(c->scratch>=0){struct stat s;if(fstat(c->scratch,&s))exit(3);files++;logical+=s.st_size;allocated+=s.st_blocks*512;}}
    struct proc_fdinfo fds[PROBE_MAX*3]; int fdbytes=proc_pidinfo(getpid(),PROC_PIDLISTFDS,0,fds,sizeof(fds)); if(fdbytes<0)exit(3);
    printf("{\"physical\":%llu,\"rss\":%llu,\"threads\":%d,\"active\":%d,\"ordinary\":%d,\"headers\":%d,\"uploads\":%d,\"downloads\":%d,\"scratch_files\":%d,\"scratch_logical\":%lu,\"scratch_allocated\":%lu,\"open_fds\":%d,\"client_struct_bytes\":%zu,\"window_bytes\":%d,\"completed\":%lu,\"rejected\":%lu,\"expired\":%lu}\n",(unsigned long long)u.ri_phys_footprint,(unsigned long long)t.pti_resident_size,t.pti_threadnum,active,ordinary,headers,uploads,downloads,files,logical,allocated,fdbytes/(int)sizeof(struct proc_fdinfo),sizeof(struct client),WINDOW*2,completed,rejected,expired);fflush(stdout);
}
int main(int argc,char**argv){
    if(argc!=6)return 2; limit=atoi(argv[2]);ordinary_limit=atoi(argv[3]);header_timeout=atof(argv[4]);stall_timeout=atof(argv[5]);if(limit<1||limit>PROBE_MAX||ordinary_limit<1||ordinary_limit>limit)return 2;
    signal(SIGPIPE,SIG_IGN);struct rlimit rl;if(getrlimit(RLIMIT_NOFILE,&rl))return 2;if(rl.rlim_cur<4096){rl.rlim_cur=rl.rlim_max<4096?rl.rlim_max:4096;if(setrlimit(RLIMIT_NOFILE,&rl))return 2;}
    for(int i=0;i<PROBE_MAX;i++)clients[i].fd=clients[i].scratch=-1;
    int listener=socket(AF_UNIX,SOCK_STREAM,0);struct sockaddr_un addr={.sun_len=sizeof(addr),.sun_family=AF_UNIX};if(strlen(argv[1])>=sizeof(addr.sun_path))return 2;strcpy(addr.sun_path,argv[1]);
    if(listener<0||bind(listener,(void*)&addr,sizeof(addr))||listen(listener,128))return 2;fcntl(listener,F_SETFL,O_NONBLOCK);puts("ready");fflush(stdout);
    for(;;){
        struct pollfd p[PROBE_MAX+2];p[0]=(struct pollfd){0,POLLIN,0};p[1]=(struct pollfd){listener,POLLIN,0};double ts=now(),next=ts+3600;
        for(int i=0;i<limit;i++){struct client*c=&clients[i];if(c->fd>=0){double deadline=c->phase==0?c->born+header_timeout:c->progress+stall_timeout;if(deadline<=ts){expired++;release(c);}else if(deadline<next)next=deadline;}p[i+2]=(struct pollfd){c->fd,c->phase==2?POLLOUT:POLLIN,0};}
        int ms=(int)((next-ts)*1000)+1;if(poll(p,limit+2,ms)<0){if(errno==EINTR)continue;return 2;}
        if(p[0].revents){char ch;if(read(0,&ch,1)<=0||ch=='q')break;if(ch=='s')sample();}
        // One accept per turn; do not let connection churn drain all service time.
        if(p[1].revents&POLLIN){int fd=accept(listener,NULL,NULL);if(fd>=0){int slot=0;while(slot<limit&&clients[slot].fd>=0)slot++;if(slot==limit){close(fd);rejected++;}else{struct client*c=&clients[slot];c->fd=fd;fcntl(fd,F_SETFL,O_NONBLOCK);if(!c->buf)c->buf=malloc(WINDOW*2);if(!c->buf)return 2;memset(c->buf,'x',WINDOW*2);c->born=c->progress=now();active++;}}}
        for(int i=0;i<limit;i++){struct client*c=&clients[i];short ev=p[i+2].revents;if(c->fd<0||!ev)continue;if(ev&(POLLERR|POLLNVAL|POLLHUP)){release(c);continue;}
            if(ev&POLLIN){ssize_t n=recv(c->fd,c->buf+c->used,WINDOW-c->used,0);if(n<=0){if(n==0||(errno!=EAGAIN&&errno!=EINTR))release(c);continue;}c->progress=now();c->used+=n;
                if(c->phase==0){size_t end=0;for(size_t j=3;j<c->used;j++)if(!memcmp(c->buf+j-3,"\r\n\r\n",4)){end=j+1;break;}if(!end){if(c->used==WINDOW)release(c);continue;}
                    if(parse_head(c->buf,end,&c->body,&c->large)||c->used-end>c->body){release(c);continue;}
                    int control=end>=20&&!memcmp(c->buf,"POST /stop HTTP/1.1\r\n",21)&&c->body==0;
                    if(!control&&ordinary>=ordinary_limit){rejected++;c->rejected=1;response(c,1);continue;}
                    c->ordinary=!control;ordinary+=c->ordinary;
                    if(c->body||c->large)c->scratch=scratch();
                    if(c->body)write_all(c->scratch,c->buf+end,c->used-end);
                    c->body-=c->used-end;c->used=0;c->phase=1;
                    if(c->large){memset(c->buf,'x',WINDOW);for(int j=0;j<REPORT/WINDOW;j++)write_all(c->scratch,c->buf,WINDOW);if(lseek(c->scratch,0,SEEK_SET)<0)return 3;}
                }else{if(c->used>c->body){release(c);continue;}write_all(c->scratch,c->buf,c->used);c->body-=c->used;c->used=0;}
                if(c->body==0)response(c,0);
            }
            if(ev&POLLOUT){ssize_t n=send(c->fd,c->buf+WINDOW+c->sent,c->pending-c->sent,0);if(n<0){if(errno!=EAGAIN&&errno!=EINTR)release(c);continue;}if(n)c->progress=now();c->sent+=n;if(c->sent==c->pending){if(!c->output){if(!c->rejected)completed++;release(c);continue;}c->pending=c->output<WINDOW?c->output:WINDOW;c->output-=c->pending;if(c->large){ssize_t r=read(c->scratch,c->buf+WINDOW,c->pending);if(r!=(ssize_t)c->pending)return 3;}else memset(c->buf+WINDOW,'x',c->pending);c->sent=0;}}
        }
    }
    for(int i=0;i<limit;i++){if(clients[i].fd>=0)release(&clients[i]);free(clients[i].buf);}close(listener);unlink(argv[1]);return 0;
}
