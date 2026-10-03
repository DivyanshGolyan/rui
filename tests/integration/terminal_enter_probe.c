/* Schedule at the real first Enter read or fresh choice prompt write, then
 * observe real write EAGAIN and consumed typeahead. Native TCOOFF/TCOON supplies
 * backpressure; this probe never changes bytes, syscall results or geometry. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int entered, blocked, typed, serviced;

static void notice(char byte) {
    ssize_t (*real_write)(int, const void *, size_t) = dlsym(RTLD_NEXT, "write");
    if (real_write(atoi(getenv("RUI_ENTER_NOTICE_FD")), &byte, 1) != 1) _exit(91);
}

ssize_t read(int fd, void *bytes, size_t length) {
    ssize_t (*real_read)(int, void *, size_t) = dlsym(RTLD_NEXT, "read");
    ssize_t result = real_read(fd, bytes, length);
    int saved_errno = errno;
    if (fd == 0 && result == 1) {
        char byte = *(char *)bytes;
        if (!entered && !getenv("RUI_ENTER_PROMPT") && (byte == '\n' || byte == '\r')) {
            entered = 1;
            notice('e');
            char release;
            if (real_read(atoi(getenv("RUI_ENTER_GATE_FD")), &release, 1) != 1) _exit(92);
        } else if (entered) typed = 1;
    }
    errno = saved_errno;
    return result;
}

ssize_t write(int fd, const void *bytes, size_t length) {
    ssize_t (*real_write)(int, const void *, size_t) = dlsym(RTLD_NEXT, "write");
    if (fd == 1 && !entered && getenv("RUI_ENTER_PROMPT") &&
        memmem(bytes, length, "Allow once, deny, or later?", 26)) {
        entered = 1;
        notice('e');
        ssize_t (*real_read)(int, void *, size_t) = dlsym(RTLD_NEXT, "read");
        char release;
        if (real_read(atoi(getenv("RUI_ENTER_GATE_FD")), &release, 1) != 1) _exit(92);
    }
    ssize_t result = real_write(fd, bytes, length);
    int saved_errno = errno;
    if (fd == 1 && entered && result < 0 && saved_errno == EAGAIN && !blocked) {
        blocked = 1;
        notice('x');
    }
    errno = saved_errno;
    return result;
}

int poll(struct pollfd *fds, nfds_t count, int timeout) {
    int (*real_poll)(struct pollfd *, nfds_t, int) = dlsym(RTLD_NEXT, "poll");
    int result = real_poll(fds, count, timeout);
    int saved_errno = errno;
    if (result == 0 && count == 1 && fds[0].fd == 0 && blocked && typed && !serviced) {
        serviced = 1;
        notice('i');
    }
    errno = saved_errno;
    return result;
}
