/* Observe Admission's inherited mask at pthread creation, before worker entry.
 * An unrelated blocked signal makes exact parent-mask restoration observable. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

static _Thread_local int admission_launch;
static pthread_t body_borrower;
static int has_body_borrower;

static void notice(char byte) {
    const char *fd = getenv("RUI_ADMISSION_NOTICE_FD");
    if (!fd || write(atoi(fd), &byte, 1) != 1) _exit(98);
}

__attribute__((constructor)) static void setup(void) {
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, SIGUSR2);
    if (pthread_sigmask(SIG_BLOCK, &set, NULL)) _exit(98);
}

int pthread_sigmask(int how, const sigset_t *set, sigset_t *previous) {
    int (*real_mask)(int, const sigset_t *, sigset_t *) = dlsym(RTLD_NEXT, "pthread_sigmask");
    static int blocks;
    if (how == SIG_BLOCK && set && sigismember(set, SIGINT)) {
        const char *attempt = getenv("RUI_ADMISSION_FAIL_ATTEMPT");
        if (++blocks == (attempt ? atoi(attempt) : 1) && getenv("RUI_ADMISSION_FAIL_MASK")) {
            notice('F');
            return EAGAIN;
        }
    }
    if (how == SIG_SETMASK && set && admission_launch &&
        (getenv("RUI_ADMISSION_FAIL_SETMASK") || getenv("RUI_ADMISSION_HOLD_SETMASK"))) {
        admission_launch = 0;
        notice('R');
        const char *gate = getenv("RUI_ADMISSION_MASK_GATE_FD");
        char byte;
        if (!gate || read(atoi(gate), &byte, 1) != 1 || byte != 'x') _exit(98);
        if (getenv("RUI_ADMISSION_HOLD_SETMASK")) {
            int result = real_mask(how, set, previous);
            notice('E');
            return result;
        }
        if (getenv("RUI_ADMISSION_QUEUE_INTERRUPT") && kill(getpid(), SIGINT)) _exit(98);
        // Deliberately do not perform restoration. Verify retained blocked
        // SIGINT/SIGUSR2, not false equality with the original parent mask.
        sigset_t actual;
        if (real_mask(SIG_SETMASK, NULL, &actual) || !sigismember(&actual, SIGINT) || !sigismember(&actual, SIGUSR2)) _exit(98);
        notice('E');
        return EIO;
    }
    return real_mask(how, set, previous);
}

struct observed_launch { void *(*start)(void *); void *argument; };

static void *observe_completion(void *opaque) {
    struct observed_launch launch = *(struct observed_launch *)opaque;
    free(opaque);
    void *result = launch.start(launch.argument);
    notice('D');
    return result;
}

ssize_t read(int fd, void *bytes, size_t length) {
    ssize_t (*real_read)(int, void *, size_t) = dlsym(RTLD_NEXT, "read");
    ssize_t result = real_read(fd, bytes, length);
    int saved_errno = errno;
    const char *body = "{\"code\":\"canonical_store_failure\"}";
    if (fd > 2 && getenv("RUI_ADMISSION_HOLD_BODY") && result == (ssize_t)strlen(body) &&
        !memcmp(bytes, body, result)) {
        // Real bytes are already in the worker's buffer. Hold only the return
        // so terminal cleanup must precede joining this outstanding borrower.
        notice('C');
        const char *gate = getenv("RUI_ADMISSION_BODY_GATE_FD");
        char release;
        if (!gate || real_read(atoi(gate), &release, 1) != 1 || release != 'x') _exit(98);
    }
    errno = saved_errno;
    return result;
}

int tcsetattr(int fd, int action, const struct termios *mode) {
    int (*real_set)(int, int, const struct termios *) = dlsym(RTLD_NEXT, "tcsetattr");
    int result = real_set(fd, action, mode);
    int saved_errno = errno;
    if (fd == 0 && result == 0 && (mode->c_lflag & ICANON) && getenv("RUI_ADMISSION_HOLD_BODY")) notice('T');
    errno = saved_errno;
    return result;
}

int pthread_join(pthread_t thread, void **result) {
    int (*real_join)(pthread_t, void **) = dlsym(RTLD_NEXT, "pthread_join");
    if (has_body_borrower && pthread_equal(thread, body_borrower)) notice('J');
    return real_join(thread, result);
}

int pthread_create(pthread_t *thread, const pthread_attr_t *attributes,
                   void *(*start)(void *), void *argument) {
    int (*real_create)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *) = dlsym(RTLD_NEXT, "pthread_create");
    sigset_t mask;
    if (pthread_sigmask(SIG_SETMASK, NULL, &mask)) _exit(98);
    if (sigismember(&mask, SIGINT)) {
        notice('B');
        admission_launch = 1;
        static int launches;
        const char *attempt = getenv("RUI_ADMISSION_FAIL_ATTEMPT");
        if (++launches == (attempt ? atoi(attempt) : 1) && getenv("RUI_ADMISSION_FAIL_SPAWN")) return EAGAIN;
        if (getenv("RUI_ADMISSION_FAIL_SETMASK") || getenv("RUI_ADMISSION_HOLD_SETMASK") || getenv("RUI_ADMISSION_HOLD_BODY")) {
            struct observed_launch *launch = malloc(sizeof(*launch));
            if (!launch) _exit(98);
            *launch = (struct observed_launch){start, argument};
            int result = real_create(thread, attributes, observe_completion, launch);
            if (result) free(launch);
            else if (getenv("RUI_ADMISSION_HOLD_BODY")) {
                body_borrower = *thread;
                has_body_borrower = 1;
            }
            return result;
        }
    }
    return real_create(thread, attributes, start, argument);
}
