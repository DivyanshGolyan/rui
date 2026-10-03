/* Linux fault probe for the production drain borrower's lost-signal window.
 * PTY tcdrain normally succeeds even with unread output. This deliberately
 * holds an interruptible pipe read AFTER the real tcdrain succeeds; it proves
 * cooperative syscall interruption/lifetime, not serial-driver latency.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <termios.h>
#include <unistd.h>

static int notice_fd, gate_fd;
static struct sigaction baseline;
static void (*owner_handler)(int);
static atomic_int first_seen;
static pthread_t borrower;
static atomic_int borrowed;
static atomic_long borrower_tid;
static int signals_sent;

static void notice(char byte) { if (write(notice_fd, &byte, 1) != 1) _exit(91); }
static void interrupted(int signal) {
    owner_handler(signal);
    atomic_store(&first_seen, 1);
}

__attribute__((constructor)) static void setup(void) {
    notice_fd = atoi(getenv("RUI_DRAIN_NOTICE_FD"));
    gate_fd = atoi(getenv("RUI_DRAIN_GATE_FD"));
    int (*real_action)(int, const struct sigaction *, struct sigaction *) = dlsym(RTLD_NEXT, "sigaction");
    struct sigaction initial = { .sa_handler = SIG_IGN, .sa_flags = SA_RESTART };
    sigemptyset(&initial.sa_mask);
    sigaddset(&initial.sa_mask, SIGUSR2);
    if (real_action(SIGUSR1, &initial, NULL) || real_action(SIGUSR1, NULL, &baseline)) _exit(92);
}

int sigaction(int signal, const struct sigaction *action, struct sigaction *previous) {
    int (*real_action)(int, const struct sigaction *, struct sigaction *) = dlsym(RTLD_NEXT, "sigaction");
    if (signal == SIGUSR1 && action && action->sa_handler != SIG_IGN && action->sa_handler != SIG_DFL) {
        owner_handler = action->sa_handler;
        struct sigaction wrapped = *action;
        wrapped.sa_handler = interrupted;
        return real_action(signal, &wrapped, previous);
    }
    int result = real_action(signal, action, previous);
    if (signal == SIGUSR1 && action && borrowed) {
        struct sigaction restored;
        if (result || real_action(signal, NULL, &restored) || restored.sa_handler != baseline.sa_handler ||
            restored.sa_flags != baseline.sa_flags) _exit(93);
        for (int s = 1; s < NSIG; ++s)
            if (sigismember(&restored.sa_mask, s) != sigismember(&baseline.sa_mask, s)) _exit(94);
        notice('R');
    }
    return result;
}

int tcdrain(int fd) {
    int (*real_drain)(int) = dlsym(RTLD_NEXT, "tcdrain");
    if (real_drain(fd)) return -1;
    borrower = pthread_self();
    borrower_tid = syscall(SYS_gettid);
    borrowed = 1;
    notice('E');
    /* The first signal is definitely caught before the blocking syscall.
     * A controller that signals once and then joins cannot complete. */
    while (!atomic_load(&first_seen)) sched_yield();
    notice('B');
    char byte;
    return read(gate_fd, &byte, 1) < 0 ? -1 : 0;
}

int pthread_kill(pthread_t thread, int signal) {
    int (*real_kill)(pthread_t, int) = dlsym(RTLD_NEXT, "pthread_kill");
    struct termios mode;
    if (tcgetattr(0, &mode) || !(mode.c_lflag & ICANON) || !(mode.c_lflag & ECHO) ||
        !(mode.c_lflag & ISIG) || (fcntl(1, F_GETFL) & O_NONBLOCK)) _exit(95);
    notice('T');
    if (signals_sent++) {
        /* Establish the held kernel read, not merely an unread PTY or a
         * pre-syscall marker, before delivering the second signal. */
        char path[128], state[256];
        snprintf(path, sizeof path, "/proc/self/task/%ld/syscall", borrower_tid);
        int blocked = 0;
        for (int attempt = 0; attempt < 1000 && !blocked; ++attempt) {
            int fd = open(path, O_RDONLY);
            ssize_t length = read(fd, state, sizeof state-1);
            close(fd);
            if (length > 0) {
                state[length] = 0;
                long number; unsigned long input;
                blocked = sscanf(state, "%ld %lx", &number, &input) == 2 && number == SYS_read && input == (unsigned long)gate_fd;
            }
            if (!blocked) usleep(1000);
        }
        if (!blocked) _exit(96);
        notice('K');
    }
    return real_kill(thread, signal);
}

int pthread_join(pthread_t thread, void **result) {
    int (*real_join)(pthread_t, void **) = dlsym(RTLD_NEXT, "pthread_join");
    int status = real_join(thread, result);
    if (borrowed && pthread_equal(thread, borrower)) notice('J');
    return status;
}
