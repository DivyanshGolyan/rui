#include <curl/curl.h>
#include <sys/socket.h>
#include <sys/resource.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
int main(void) {
    struct rlimit r;
    if(getrlimit(RLIMIT_NOFILE,&r)) return 1;
    r.rlim_cur=4096;
    if(setrlimit(RLIMIT_NOFILE,&r)) return 1;
    if(curl_global_init(CURL_GLOBAL_ALL)) return 1;
    CURLM *m=curl_multi_init(); if(!m) return 1;
    int s[2]; if(socketpair(AF_UNIX,SOCK_STREAM,0,s)) return 1;
    int nums[]={s[0],1023,1024,1100,2000};
    for(int i=0;i<5;i++) {
        int fd=i?fcntl(s[0],F_DUPFD,nums[i]):s[0]; if(fd<0) return 1;
        struct curl_waitfd w={fd,CURL_WAIT_POLLIN,0}; int n=0;
        errno=0; CURLMcode rc=curl_multi_poll(m,&w,1,1,&n); int e=errno;
        struct pollfd p={fd,POLLIN,0}; errno=0; int pr=poll(&p,1,1);
        printf("fd=%d curl=%d %s errno=%d native_poll=%d errno=%d\n",fd,rc,curl_multi_strerror(rc),e,pr,errno);
        if(i) close(fd);
    }
    printf("%s\n",curl_version());
    close(s[0]);close(s[1]);curl_multi_cleanup(m);curl_global_cleanup();
    return 0;
}
