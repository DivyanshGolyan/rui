/* One native bridge witness: park a watchdog with a running snapshot until
 * acceptance commits. The resumed watchdog must not signal or replace success.
 * All other terminal orderings are checked directly through the value owner. */
#include <sys/wait.h>

static struct {
    pthread_t caller;
    int mode;
    int observed;
    pid_t child;
    atomic_int watchdog_parked;
    atomic_int release_watchdog;
    atomic_int signals;
} race;

static void race_wait(atomic_int *flag) {
    while (!atomic_load(flag)) {
        struct timespec pause = {0, 1000000};
        nanosleep(&pause, NULL);
    }
}

static int race_mutex_unlock(pthread_mutex_t *mutex) {
    int result = pthread_mutex_unlock(mutex);
    if (race.mode && !pthread_equal(pthread_self(), race.caller)) {
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
        now->tv_sec = 105;
    } else if (race.observed) {
        now->tv_sec = 104;
        now->tv_nsec = 999000000;
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
    atomic_fetch_add(&race.signals, 1);
    return kill(pid, signal);
}

#define rui_evaluate race_evaluate
#define pthread_mutex_unlock race_mutex_unlock
#define clock_gettime race_clock_gettime
#define waitid race_waitid
#define pthread_join race_pthread_join
#define kill race_kill
#include "../../src/evaluator_parent.c"
#undef rui_evaluate
#undef pthread_mutex_unlock
#undef clock_gettime
#undef waitid
#undef pthread_join
#undef kill

static int check_terminal_decisions(void) {
    const struct {
        enum terminal_observation observation;
        int64_t now;
        int cancelled;
        enum watchdog_outcome expected;
    } cases[] = {
        {terminal_poll, 4999, 0, watchdog_running},
        {terminal_poll, 4999, 1, watchdog_cancelled},
        {terminal_poll, 5000, 0, watchdog_deadline},
        {terminal_poll, 5000, 1, watchdog_deadline},
        {terminal_poll, 5001, 0, watchdog_deadline},
        {terminal_poll, -1, 0, watchdog_clock_failed},
        {terminal_poll, -1, 1, watchdog_clock_failed},
        {terminal_success, 4999, 0, watchdog_stopped},
        {terminal_success, 5000, 0, watchdog_deadline},
        {terminal_success, 5001, 0, watchdog_deadline},
        {terminal_success, -1, 0, watchdog_clock_failed},
        {terminal_success, 4999, 1, watchdog_cancelled},
        {terminal_success, 5000, 1, watchdog_deadline},
        {terminal_success, -1, 1, watchdog_clock_failed},
        {terminal_child_failure, 4999, 0, watchdog_failed},
        {terminal_child_failure, 5000, 0, watchdog_deadline},
        {terminal_child_failure, -1, 0, watchdog_clock_failed},
        {terminal_failure, 4999, 0, watchdog_failed},
        {terminal_failure, 4999, 1, watchdog_failed},
        {terminal_failure, 5000, 1, watchdog_failed},
        {terminal_failure, -1, 1, watchdog_failed},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        enum watchdog_outcome result = terminal_decision(watchdog_running,
            cases[i].observation, cases[i].now, 5000, cases[i].cancelled);
        if (result != cases[i].expected) {
            fprintf(stderr, "terminal case %zu: got %d expected %d\n",
                i, result, cases[i].expected);
            return 12;
        }
        /* Check the parent-failure adapter as well as the value policy. A
         * missed commit here would let a later watchdog cancellation win. */
        struct watchdog watchdog = {.deadline = 5000, .outcome = result};
        if (pthread_mutex_init(&watchdog.mutex, NULL)) return 12;
        int failed = fail_evaluation(&watchdog);
        enum watchdog_outcome after_failure = watchdog.outcome;
        pthread_mutex_destroy(&watchdog.mutex);
        enum watchdog_outcome expected_failure = result == watchdog_running
            ? watchdog_failed : result;
        if (!failed || after_failure != expected_failure) {
            fprintf(stderr, "parent failure adapter after case %zu\n", i);
            return 12;
        }
        /* Every committed terminal outcome is immutable under every later
         * observation, including failure-after-cancel and cancel-after-failure. */
        if (result == watchdog_running) continue;
        for (size_t j = 0; j < sizeof(cases) / sizeof(cases[0]); j++) {
            if (terminal_decision(result, cases[j].observation,
                    cases[j].now, 5000, cases[j].cancelled) != result) {
                fprintf(stderr, "terminal immutability %zu after %zu\n", i, j);
                return 12;
            }
        }
    }
    return 0;
}
