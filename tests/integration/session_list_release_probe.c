#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* Opt-in Linux proof only. Intercept the actual Store report descriptor;
 * existing stdin/stderr provide control, with no added Host descriptor. */
static int (*real_close)(int);
static atomic_uint hits;
static _Thread_local int probing;

__attribute__((constructor)) static void initialize(void) {
    real_close = dlsym(RTLD_NEXT, "close");
    if (!real_close) _exit(90);
}

static int64_t monotonic_ms(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) _exit(91);
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

int close(int fd) {
    int original_errno = errno;
    const char *mode = getenv("RUI_CENSUS_PROBE_MODE");
    const char *parent = getenv("RUI_CENSUS_PROBE_PARENT");
    const char *request = getenv("RUI_CENSUS_PROBE_REQUEST");
    if (probing || fd < 3 || !mode || !parent || !request) return real_close(fd);
    probing = 1;
    char link[64], target[1024], expected[1024];
    snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
    ssize_t length = readlink(link, target, sizeof(target) - 1);
    if (length < 0) length = 0;
    target[length] = 0;
    int wanted = snprintf(expected, sizeof(expected), "%s/report-%s-1.tmp (deleted)", parent, request);
    struct stat identity;
    int match = wanted > 0 && (size_t)wanted < sizeof(expected) &&
        strcmp(target, expected) == 0 && fstat(fd, &identity) == 0 && S_ISREG(identity.st_mode);
    if (!match) {
        probing = 0;
        errno = original_errno;
        return real_close(fd);
    }
    if (atomic_fetch_add(&hits, 1) != 0) _exit(92);
    int held = strcmp(mode, "hold") == 0;
    if (!held && strcmp(mode, "leak") != 0) _exit(93);
    char receipt[512];
    int size = snprintf(receipt, sizeof(receipt),
        "{\"rui_test_phase\":\"release_probe_%s\",\"pid\":%d,\"request\":\"%s\","
        "\"fd\":%d,\"device\":%llu,\"inode\":%llu}\n",
        held ? "held" : "leaked", getpid(), request, fd,
        (unsigned long long)identity.st_dev, (unsigned long long)identity.st_ino);
    if (size <= 0 || (size_t)size >= sizeof(receipt)) _exit(94);
    ssize_t written;
    do { written = write(STDERR_FILENO, receipt, (size_t)size); }
    while (written < 0 && errno == EINTR);
    if (written != size) _exit(95);
    if (held) {
        int64_t deadline = monotonic_ms() + 10000;
        for (;;) {
            int64_t remaining = deadline - monotonic_ms();
            if (remaining <= 0) _exit(96);
            struct pollfd input = { .fd = STDIN_FILENO, .events = POLLIN };
            int ready = poll(&input, 1, (int)remaining);
            if (ready < 0 && errno == EINTR) continue;
            if (ready <= 0) _exit(97);
            char command;
            ssize_t count = read(STDIN_FILENO, &command, 1);
            if (count < 0 && errno == EINTR) continue;
            if (count != 1 || command != 'r') _exit(98);
            break;
        }
    }
    probing = 0;
    errno = original_errno;
    /* In leak mode, deliberately relinquish ownership without closing the
     * same real report fd. Charge/counter release and the milestone proceed. */
    return held ? real_close(fd) : 0;
}
