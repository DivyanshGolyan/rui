// THROWAWAY macOS measurement harness. Not a production HTTP implementation.
#include <arpa/inet.h>
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
#include <unistd.h>

#define LIMIT 100
#define WINDOW 8192
extern int parse_head(const unsigned char *, size_t, uint64_t *, int *);
struct client { int fd, phase, large; unsigned char *buf; size_t used, sent, pending; uint64_t body, output; };
static struct client clients[LIMIT];
static unsigned long accepted, completed, rejected;
static int reuse_buffers;
static void release(struct client *c) { unsigned char *buf=c->buf; close(c->fd); if(!reuse_buffers) free(buf); memset(c, 0, sizeof(*c)); c->fd=-1; if(reuse_buffers) c->buf=buf; }
static void response(struct client *c) {
    c->phase=2; c->sent=0;
    c->output=c->large ? 32ULL*1024*1024 : 2;
    c->pending=(size_t)snprintf((char *)c->buf+WINDOW, WINDOW,
        "HTTP/1.1 200 OK\r\nContent-Length: %llu\r\nConnection: close\r\n\r\n", (unsigned long long)c->output);
}
static void sample(void) {
    struct rusage_info_v4 usage={0}; struct proc_taskinfo task={0};
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&usage) ||
        proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &task, sizeof(task)) != sizeof(task)) exit(3);
    int active=0; for(int i=0;i<LIMIT;i++) active+=clients[i].fd>=0;
    printf("{\"physical\":%llu,\"rss\":%llu,\"threads\":%d,\"active\":%d,\"accepted\":%lu,\"completed\":%lu,\"rejected\":%lu}\n",
        (unsigned long long)usage.ri_phys_footprint, (unsigned long long)task.pti_resident_size,
        task.pti_threadnum,active,accepted,completed,rejected); fflush(stdout);
}
int main(int argc, char **argv) {
    signal(SIGPIPE,SIG_IGN);
    reuse_buffers=argc>1 && !strcmp(argv[1],"reuse");
    for(int i=0;i<LIMIT;i++) clients[i].fd=-1;
    int listener=-1;
    if(argc>1 && strcmp(argv[1],"baseline")) {
        listener=socket(AF_INET,SOCK_STREAM,0); if(listener<0) return 2;
        struct sockaddr_in addr={.sin_len=sizeof(addr),.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
        if(bind(listener,(void *)&addr,sizeof(addr)) || listen(listener,128)) return 2;
        socklen_t n=sizeof(addr); if(getsockname(listener,(void *)&addr,&n)) return 2;
        fcntl(listener,F_SETFL,O_NONBLOCK);
        printf("%d\n",ntohs(addr.sin_port));
    } else puts("0");
    fflush(stdout);
    for(;;) {
        struct pollfd p[LIMIT+2]; p[0]=(struct pollfd){0,POLLIN,0}; p[1]=(struct pollfd){listener,POLLIN,0};
        for(int i=0;i<LIMIT;i++) p[i+2]=(struct pollfd){clients[i].fd,clients[i].phase==2?POLLOUT:POLLIN,0};
        if(poll(p,LIMIT+2,-1)<0) { if(errno==EINTR) continue; return 2; }
        if(p[0].revents) { char ch; if(read(0,&ch,1)<=0 || ch=='q') break; if(ch=='s') sample(); }
        if(p[1].revents&POLLIN) {
            int fd=accept(listener,NULL,NULL);
            if(fd>=0) {
                int slot=0; while(slot<LIMIT && clients[slot].fd>=0) slot++;
                if(slot==LIMIT) { close(fd); rejected++; }
                else {
                    fcntl(fd,F_SETFL,O_NONBLOCK);
                    clients[slot].fd=fd; if(!clients[slot].buf) clients[slot].buf=malloc(WINDOW*2);
                    if(!clients[slot].buf) return 2;
                    // Touch both windows so idle-connection accounting is conservative.
                    memset(clients[slot].buf,'x',WINDOW*2); accepted++;
                }
            }
        }
        for(int i=0;i<LIMIT;i++) {
            struct client *c=&clients[i]; short ev=p[i+2].revents;
            if(c->fd<0 || !ev) continue;
            if(ev&(POLLERR|POLLNVAL|POLLHUP)) { release(c); continue; }
            if(ev&POLLIN) {
                ssize_t n=recv(c->fd,c->buf+c->used,WINDOW-c->used,0);
                if(n<=0) { if(n==0 || (errno!=EAGAIN && errno!=EINTR)) release(c); continue; }
                c->used+=(size_t)n;
                if(c->phase==0) {
                    size_t end=0;
                    for(size_t j=3;j<c->used;j++) if(!memcmp(c->buf+j-3,"\r\n\r\n",4)) { end=j+1; break; }
                    if(!end) { if(c->used==WINDOW) release(c); continue; }
                    if(parse_head(c->buf,end,&c->body,&c->large) || c->used-end>c->body) { release(c); continue; }
                    c->body-=c->used-end; c->used=0; c->phase=1;
                } else { if(c->used>c->body) { release(c); continue; } c->body-=c->used; c->used=0; }
                if(c->body==0) response(c);
            }
            if(ev&POLLOUT) {
                ssize_t n=send(c->fd,c->buf+WINDOW+c->sent,c->pending-c->sent,0);
                if(n<0) { if(errno!=EAGAIN && errno!=EINTR) release(c); continue; }
                c->sent+=(size_t)n;
                if(c->sent==c->pending) {
                    if(!c->output) { completed++; release(c); continue; }
                    c->pending=c->output<WINDOW?(size_t)c->output:WINDOW; c->output-=c->pending;
                    memset(c->buf+WINDOW,'x',c->pending); c->sent=0;
                }
            }
        }
    }
    for(int i=0;i<LIMIT;i++) if(clients[i].fd>=0) release(&clients[i]);
    if(listener>=0) close(listener);
}
