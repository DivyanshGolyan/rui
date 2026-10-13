/* Test-side scheduling of the real parent implementation. Native child exit,
 * output, signaling and reap remain real; only clocks and thread order change. */
#include <sys/wait.h>

static struct {
    pthread_t caller;
    int mode;
    int observed;
    pid_t child;
    atomic_int watchdog_parked;
    atomic_int release_watchdog;
    atomic_int watchdog_locking;
    atomic_int watchdog_signalled;
} race;

static void race_wait(atomic_int *flag) {
    while (!atomic_load(flag)) {
        struct timespec pause = {0, 1000000};
        nanosleep(&pause, NULL);
    }
}

static int race_mutex_lock(pthread_mutex_t *mutex) {
    if (!pthread_equal(pthread_self(), race.caller) &&
        atomic_load(&race.release_watchdog))
        atomic_store(&race.watchdog_locking, 1);
    return pthread_mutex_lock(mutex);
}

static int race_mutex_unlock(pthread_mutex_t *mutex) {
    int result = pthread_mutex_unlock(mutex);
    if (!pthread_equal(pthread_self(), race.caller)) {
        atomic_store(&race.watchdog_parked, 1);
        race_wait(&race.release_watchdog);
    }
    return result;
}

static int race_clock_gettime(clockid_t clock, struct timespec *now) {
    (void)clock;
    now->tv_sec = 100;
    now->tv_nsec = 0;
    if (!pthread_equal(pthread_self(), race.caller)) {
        now->tv_sec = race.mode >= 5 ? 100 : 105;
    } else if (race.observed) {
        if (race.mode == 2) {
            /* Pause at the timely exit clock observation until the watchdog
             * attempts its competing terminal transition. */
            atomic_store(&race.release_watchdog, 1);
            race_wait(&race.watchdog_locking);
        }
        if (race.mode == 4) { errno = EIO; return -1; }
        now->tv_sec = race.mode == 3 ? 105 : 104;
        now->tv_nsec = race.mode == 3 ? 0 : 999000000;
    }
    return 0;
}

static int race_waitid(idtype_t type, id_t id, siginfo_t *info, int options) {
    int result = waitid(type, id, info, options);
    if (!result && info->si_pid == (pid_t)id) {
        race_wait(&race.watchdog_parked);
        race.observed = 1;
        race.child = info->si_pid;
    }
    return result;
}

static int race_pthread_join(pthread_t thread, void **value) {
    /* The parent has made its terminal decision before joining. A watchdog
     * resuming here must not override it from an earlier running snapshot. */
    atomic_store(&race.release_watchdog, 1);
    return pthread_join(thread, value);
}

static int race_kill(pid_t pid, int signal) {
    if (race.mode == 5 && pthread_equal(pthread_self(), race.caller)) {
        race.child = pid;
        race_wait(&race.watchdog_parked);
        atomic_store(&race.release_watchdog, 1);
    }
    int result = kill(pid, signal);
    if (race.mode == 6 && !pthread_equal(pthread_self(), race.caller)) {
        race.child = pid;
        atomic_store(&race.watchdog_signalled, 1);
    }
    return result;
}

#define rui_evaluate race_evaluate
#define pthread_mutex_lock race_mutex_lock
#define pthread_mutex_unlock race_mutex_unlock
#define clock_gettime race_clock_gettime
#define waitid race_waitid
#define pthread_join race_pthread_join
#define kill race_kill
#include "../../src/evaluator_parent.c"
#undef rui_evaluate
#undef pthread_mutex_lock
#undef pthread_mutex_unlock
#undef clock_gettime
#undef waitid
#undef pthread_join
#undef kill
