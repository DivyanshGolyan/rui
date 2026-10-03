/* Observe native restoration and any later borrower creation in a held /status
 * failure. A cancelled socket may never reach the proxy, but starting another
 * request borrower after terminal custody ended is itself the owner violation.
 * No syscall result, disposition, mask, input or output is changed. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <termios.h>
#include <unistd.h>

static atomic_int raw_seen, restored;

static void notice(char byte) {
    if (write(atoi(getenv("RUI_CUSTODY_NOTICE_FD")), &byte, 1) != 1) _exit(91);
}

int tcsetattr(int fd, int action, const struct termios *mode) {
    int (*real_set)(int, int, const struct termios *) = dlsym(RTLD_NEXT, "tcsetattr");
    int result = real_set(fd, action, mode);
    int saved_errno = errno;
    if (fd == 0 && result == 0) {
        if (!(mode->c_lflag & ICANON)) raw_seen = 1;
        else if (raw_seen) {
            restored = 1;
            notice('r');
        }
    }
    errno = saved_errno;
    return result;
}

int pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                   void *(*run)(void *), void *argument) {
    int (*real_create)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *) = dlsym(RTLD_NEXT, "pthread_create");
    if (restored) notice('s');
    return real_create(thread, attr, run, argument);
}
