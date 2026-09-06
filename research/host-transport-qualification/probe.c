#include <curl/curl.h>
#include <sys/socket.h>
#include <sys/resource.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
struct State { int minimum, actual, watched, interest; size_t bytes; };
static curl_socket_t open_socket(void *opaque, curlsocktype purpose, struct curl_sockaddr *a) {
    struct State *s = opaque;
    if (purpose != CURLSOCKTYPE_IPCXN) return CURL_SOCKET_BAD;
    int fd = socket(a->family, a->socktype, a->protocol);
    if (fd < 0) return CURL_SOCKET_BAD;
    if (fd < s->minimum) { int high = fcntl(fd, F_DUPFD, s->minimum); close(fd); fd = high; }
    s->actual = fd;
    return fd;
}
static size_t body(char *p, size_t n, size_t m, void *opaque) {
    (void)p; ((struct State *)opaque)->bytes += n*m; return n*m;
}
static int interest(CURL *easy, curl_socket_t fd, int what, void *opaque, void *socketp) {
    (void)easy; (void)socketp;
    struct State *s = opaque; s->watched = fd;
    s->interest = what == CURL_POLL_REMOVE ? 0 :
        ((what == CURL_POLL_IN || what == CURL_POLL_INOUT) ? POLLIN : 0) |
        ((what == CURL_POLL_OUT || what == CURL_POLL_INOUT) ? POLLOUT : 0);
    return 0;
}
int main(int argc, char **argv) {
    if (argc != 4) return 2;
    struct rlimit limit; if (getrlimit(RLIMIT_NOFILE,&limit)) return 2;
    limit.rlim_cur=4096; if(setrlimit(RLIMIT_NOFILE,&limit)) return 2;
    if(curl_global_init(CURL_GLOBAL_DEFAULT)) return 2;
    struct State s = {.minimum=atoi(argv[2]), .actual=-1, .watched=-1};
    CURL *e=curl_easy_init(); if(!e) return 2;
#define OPT(k,v) if(curl_easy_setopt(e,k,v)!=CURLE_OK) return 2
    OPT(CURLOPT_URL,argv[1]); OPT(CURLOPT_PROXY,""); OPT(CURLOPT_TIMEOUT_MS,3000L);
    OPT(CURLOPT_NOSIGNAL,1L); OPT(CURLOPT_OPENSOCKETFUNCTION,open_socket); OPT(CURLOPT_OPENSOCKETDATA,&s);
    OPT(CURLOPT_WRITEFUNCTION,body); OPT(CURLOPT_WRITEDATA,&s);
    char error[CURL_ERROR_SIZE]={0}; OPT(CURLOPT_ERRORBUFFER,error);
    CURLcode code=CURLE_FAILED_INIT; CURLMcode multi_code=CURLM_OK;
    if(!strcmp(argv[3],"easy")) code=curl_easy_perform(e);
    else {
        CURLM *m=curl_multi_init(); if(!m) return 2;
        if(curl_multi_setopt(m,CURLMOPT_SOCKETFUNCTION,interest) || curl_multi_setopt(m,CURLMOPT_SOCKETDATA,&s)) return 2;
        if(curl_multi_add_handle(m,e)) return 2;
        int running=0;
        multi_code=curl_multi_socket_action(m,CURL_SOCKET_TIMEOUT,0,&running);
        for(int iteration=0; multi_code==CURLM_OK && running && iteration<1000; ++iteration) {
            long timeout=-1; if(curl_multi_timeout(m,&timeout)) return 2;
            if(timeout<0 || timeout>10) timeout=10;
            struct pollfd fd={s.watched,(short)s.interest,0};
            int ready=poll(&fd,s.interest?1:0,(int)timeout);
            if(ready<0) return 2;
            if(ready) {
                int events=((fd.revents&POLLIN)?CURL_CSELECT_IN:0)|((fd.revents&POLLOUT)?CURL_CSELECT_OUT:0)|((fd.revents&(POLLERR|POLLHUP|POLLNVAL))?CURL_CSELECT_ERR:0);
                multi_code=curl_multi_socket_action(m,fd.fd,events,&running);
            } else multi_code=curl_multi_socket_action(m,CURL_SOCKET_TIMEOUT,0,&running);
        }
        int remaining=0; CURLMsg *msg;
        while((msg=curl_multi_info_read(m,&remaining))) if(msg->msg==CURLMSG_DONE) code=msg->data.result;
        curl_multi_remove_handle(m,e);curl_multi_cleanup(m);
    }
    printf("minimum=%d actual=%d mode=%s curl=%d multi=%d bytes=%zu error=%s\n",s.minimum,s.actual,argv[3],code,multi_code,s.bytes,error);
    printf("%s\n",curl_version()); curl_easy_cleanup(e);curl_global_cleanup();return 0;
}
