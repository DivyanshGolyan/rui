/* Observe actual production footer write EAGAIN, including a >4-KiB
 * combining cluster. No injected output, delays, or fabricated failures. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

ssize_t write(int fd, const void *bytes, size_t length) {
    ssize_t (*real_write)(int, const void *, size_t) = dlsym(RTLD_NEXT, "write");
    ssize_t result = real_write(fd, bytes, length);
    int saved_errno = errno;
    static int notified;
    const char *cluster = getenv("RUI_PAINT_CLUSTER");
    if (fd == 1 && result < 0 && saved_errno == EAGAIN && !notified &&
        ((!cluster || cluster[0] != '1') || memmem(bytes, length, "\xcc\x81", 2))) {
        notified = 1;
        const char *notice = getenv("RUI_PAINT_NOTICE_FD");
        if (!notice || real_write(atoi(notice), "x", 1) != 1) _exit(97);
    }
    errno = saved_errno;
    return result;
}
