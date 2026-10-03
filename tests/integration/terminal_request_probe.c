/* Hold the real /status body write after its header has reached the peer.
 * The fixture closes that peer before release; libc supplies the real error. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

ssize_t write(int fd, const void *bytes, size_t length) {
    ssize_t (*real_write)(int, const void *, size_t) = dlsym(RTLD_NEXT, "write");
    static int target = -1, held;
    if (fd == target && !held) {
        held = 1;
        const char *notice = getenv("RUI_REQUEST_NOTICE_FD");
        const char *gate = getenv("RUI_REQUEST_GATE_FD");
        char release;
        ssize_t (*real_read)(int, void *, size_t) = dlsym(RTLD_NEXT, "read");
        if (!notice || !gate || real_write(atoi(notice), "w", 1) != 1 ||
            real_read(atoi(gate), &release, 1) != 1) _exit(97);
    }
    ssize_t result = real_write(fd, bytes, length);
    int saved = errno;
    const char *armed = getenv("RUI_REQUEST_ARMED");
    const char *header = "POST /v1/inspect-session HTTP/1.1";
    if (fd > 2 && !held && result == (ssize_t)length && armed && access(armed, F_OK) == 0 &&
        length >= strlen(header) && !memcmp(bytes, header, strlen(header))) target = fd;
    errno = saved;
    return result;
}
