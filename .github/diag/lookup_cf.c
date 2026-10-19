#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <stdio.h>
#include <time.h>
int main(void) {
    CFStringRef s0 = CFStringCreateWithCString(NULL, "x", kCFStringEncodingUTF8); CFRelease(s0);
    struct in_addr a; inet_pton(AF_INET, "127.0.0.1", &a);
    struct timespec s, e; clock_gettime(CLOCK_MONOTONIC, &s);
    struct hostent *h = gethostbyaddr(&a, sizeof a, AF_INET);
    clock_gettime(CLOCK_MONOTONIC, &e);
    printf("C+CF gethostbyaddr: %.3fs -> %s\n", (e.tv_sec - s.tv_sec) + (e.tv_nsec - s.tv_nsec) / 1e9, h ? h->h_name : "NULL");
    return 0;
}
