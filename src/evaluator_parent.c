#define _GNU_SOURCE
#include "evaluator_parent.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int64_t milliseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) return -1;
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int make_pipe(int pipe_fds[2]) {
#ifdef __APPLE__
    if (pipe(pipe_fds)) return -1;
    if (!fcntl(pipe_fds[0], F_SETFD, FD_CLOEXEC) &&
        !fcntl(pipe_fds[1], F_SETFD, FD_CLOEXEC)) return 0;
    close(pipe_fds[0]);
    close(pipe_fds[1]);
    pipe_fds[0] = -1;
    pipe_fds[1] = -1;
    return -1;
#else
    return pipe2(pipe_fds, O_CLOEXEC);
#endif
}

static void close_pipe(int pipe_fds[2]) {
    if (pipe_fds[0] >= 0) close(pipe_fds[0]);
    if (pipe_fds[1] >= 0) close(pipe_fds[1]);
}

enum watchdog_outcome {
    watchdog_running,
    watchdog_stopped,
    watchdog_deadline,
    watchdog_cancelled,
    watchdog_clock_failed,
    watchdog_failed,
};

enum terminal_observation {
    terminal_poll, terminal_success, terminal_child_failure, terminal_failure,
};

/* Value-only terminal authority. Callers serialize the observation and commit
 * under the watchdog mutex; callbacks and process effects stay outside it. */
static enum watchdog_outcome terminal_decision(enum watchdog_outcome current,
        enum terminal_observation observation, int64_t now, int64_t deadline,
        int cancelled) {
    if (current != watchdog_running) return current;
    if (observation == terminal_failure) return watchdog_failed;
    if (now < 0) return watchdog_clock_failed;
    if (now >= deadline) return watchdog_deadline;
    if (cancelled) return watchdog_cancelled;
    if (observation == terminal_child_failure) return watchdog_failed;
    return observation == terminal_success ? watchdog_stopped : watchdog_running;
}

struct watchdog {
    pthread_mutex_t mutex;
    pid_t pid;
    int64_t deadline;
    int (*cancelled)(void *);
    void *cancel_context;
    enum watchdog_outcome outcome;
    int signal_failed;
};

static int fail_evaluation(struct watchdog *watchdog) {
    pthread_mutex_lock(&watchdog->mutex);
    watchdog->outcome = terminal_decision(watchdog->outcome,
        terminal_failure, 0, watchdog->deadline, 0);
    pthread_mutex_unlock(&watchdog->mutex);
    return 1;
}

static void *watch_child(void *context) {
    struct watchdog *watchdog = context;
    for (;;) {
        pthread_mutex_lock(&watchdog->mutex);
        enum watchdog_outcome outcome = watchdog->outcome;
        pthread_mutex_unlock(&watchdog->mutex);
        if (outcome != watchdog_running) return NULL;

        /* A callback may block; it cannot hold terminal-decision authority. */
        int cancelled = watchdog->cancelled && watchdog->cancelled(watchdog->cancel_context);
        pthread_mutex_lock(&watchdog->mutex);
        if (watchdog->outcome != watchdog_running) {
            pthread_mutex_unlock(&watchdog->mutex);
            return NULL;
        }
        int64_t now = milliseconds();
        outcome = terminal_decision(watchdog->outcome,
            terminal_poll, now, watchdog->deadline, cancelled);
        watchdog->outcome = outcome;
        pthread_mutex_unlock(&watchdog->mutex);
        if (outcome != watchdog_running) {
            /* The owner does not reap until this thread has joined, so pid
             * cannot have been reused while this signal is attempted. */
            if (kill(watchdog->pid, SIGKILL) && errno != ESRCH) {
                pthread_mutex_lock(&watchdog->mutex);
                watchdog->signal_failed = 1;
                pthread_mutex_unlock(&watchdog->mutex);
            }
            return NULL;
        }
        struct timespec pause = {0, 10000000};
        nanosleep(&pause, NULL);
    }
}

int rui_evaluate(const char *executable, int source_fd, int prepared_fd,
                 int compile_only,
                 int (*cancelled)(void *), void *cancel_context,
                 int (*append_output)(void *, const unsigned char *, size_t), void *output_context,
                 char *diagnostic, size_t diagnostic_capacity,
                 size_t *diagnostic_length) {
    if (diagnostic_length) *diagnostic_length = 0;
    struct sigaction child_action;
    if (sigaction(SIGCHLD, NULL, &child_action) ||
        child_action.sa_handler != SIG_DFL || (child_action.sa_flags & SA_NOCLDWAIT))
        return -1;
    int input_flags = fcntl(source_fd, F_GETFL);
    struct stat source_stat;
    if (input_flags < 0 || (input_flags & O_ACCMODE) != O_RDONLY ||
        fstat(source_fd, &source_stat) || !S_ISREG(source_stat.st_mode))
        return -1;
    struct stat prepared_stat;
    if ((!compile_only && prepared_fd < 0) || (prepared_fd >= 0 &&
        (compile_only || fcntl(prepared_fd, F_GETFL) < 0 ||
         (fcntl(prepared_fd, F_GETFL) & O_ACCMODE) != O_RDONLY ||
         fstat(prepared_fd, &prepared_stat) || !S_ISREG(prepared_stat.st_mode))))
        return -1;
    if (cancelled && cancelled(cancel_context)) return 1;
    int source_spawn = fcntl(source_fd, F_DUPFD_CLOEXEC, 5);
    if (source_spawn < 0) return -1;
    int prepared_spawn = -1;
    if (prepared_fd >= 0 && (prepared_spawn = fcntl(prepared_fd, F_DUPFD_CLOEXEC, 5)) < 0) {
        close(source_spawn);
        return -1;
    }
    int input_pipe[2] = {-1, -1}, output_pipe[2] = {-1, -1};
    int diagnostic_pipe[2] = {-1, -1};
    if (make_pipe(input_pipe) || make_pipe(output_pipe) || make_pipe(diagnostic_pipe)) {
        close_pipe(input_pipe);
        close_pipe(output_pipe);
        close_pipe(diagnostic_pipe);
        close(source_spawn);
        if (prepared_spawn >= 0) close(prepared_spawn);
        return -1;
    }
    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions)) {
        close_pipe(input_pipe); close_pipe(output_pipe); close_pipe(diagnostic_pipe);
        close(source_spawn); if (prepared_spawn >= 0) close(prepared_spawn);
        return -1;
    }
    int err = posix_spawn_file_actions_adddup2(&actions, input_pipe[0], 0);
    if (!err) err = posix_spawn_file_actions_adddup2(&actions, output_pipe[1], 1);
    if (!err) err = posix_spawn_file_actions_adddup2(&actions, diagnostic_pipe[1], 2);
    if (!err) err = posix_spawn_file_actions_adddup2(&actions, source_spawn, 3);
    if (!err && prepared_spawn >= 0)
        err = posix_spawn_file_actions_adddup2(&actions, prepared_spawn, 4);
#ifdef __APPLE__
    posix_spawnattr_t attr;
    int attr_initialized = posix_spawnattr_init(&attr) == 0;
    if (!attr_initialized) err = -1;
    if (!err) err = posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);
#else
    if (!err) err = posix_spawn_file_actions_addclosefrom_np(&actions,
                                                              prepared_spawn >= 0 ? 5 : 4);
#endif
    pid_t pid = -1;
    char *argv[] = {(char *)executable,
                    compile_only ? "check-prepared" : "run-prepared", NULL};
    char *env[] = {NULL};
    int cancelled_before_spawn = !err && cancelled && cancelled(cancel_context);
    if (cancelled_before_spawn) err = -1;
    /* The child can execute before posix_spawn returns. Start the clock
     * immediately before launch rather than after parent-side cleanup. */
    int64_t start = err ? -1 : milliseconds();
    if (start < 0) err = -1;
    if (!err) err = posix_spawn(&pid, executable, &actions,
#ifdef __APPLE__
                                &attr,
#else
                                NULL,
#endif
                                argv, env);
#ifdef __APPLE__
    if (attr_initialized) posix_spawnattr_destroy(&attr);
#endif
    posix_spawn_file_actions_destroy(&actions);
    close(source_spawn);
    if (prepared_spawn >= 0) close(prepared_spawn);
    close_pipe(input_pipe); /* Closing the writer makes child stdin immediate EOF. */
    close(output_pipe[1]);
    close(diagnostic_pipe[1]);
    if (err) {
        close(output_pipe[0]); close(diagnostic_pipe[0]);
        return cancelled_before_spawn ? 1 : -1;
    }
    int failed = 0;
    struct watchdog watchdog = {
        .pid = pid,
        .deadline = start + 5000,
        .cancelled = cancelled,
        .cancel_context = cancel_context,
        .outcome = watchdog_running,
    };
    pthread_t watchdog_thread;
    int watchdog_started = 0;
    if (!failed && !pthread_mutex_init(&watchdog.mutex, NULL)) {
        if (!pthread_create(&watchdog_thread, NULL, watch_child, &watchdog))
            watchdog_started = 1;
        else
            pthread_mutex_destroy(&watchdog.mutex);
    }
    if (!watchdog_started) failed = 1;
    unsigned char header[4], window[16384];
    size_t header_used = 0;
    uint32_t remaining_chunk = 0;
    uint64_t received = 0;
    int complete = 0, output_eof = 0, diagnostic_eof = 0;
    int reaped = 0, status = 0;
    while (!failed && (!output_eof || !diagnostic_eof)) {
        int64_t remaining = start + 5000 - milliseconds();
        if (remaining <= 0 || remaining > 5000) { failed = fail_evaluation(&watchdog); break; }
        struct pollfd poll_fds[2] = {
            {.fd = output_eof ? -1 : output_pipe[0], .events = POLLIN | POLLHUP},
            {.fd = diagnostic_eof ? -1 : diagnostic_pipe[0], .events = POLLIN | POLLHUP},
        };
        int ready = poll(poll_fds, 2, remaining < 25 ? (int)remaining : 25);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0) { failed = fail_evaluation(&watchdog); break; }
        if (!ready) continue;
        for (unsigned stream = 0; stream < 2 && !failed; stream++) {
            if (!(poll_fds[stream].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            ssize_t n = read(poll_fds[stream].fd, window, sizeof(window));
            if (n < 0 && errno == EINTR) continue;
            if (n < 0) { failed = fail_evaluation(&watchdog); break; }
            if (!n) {
                if (stream) diagnostic_eof = 1;
                else output_eof = 1;
                continue;
            }
            if (stream) {
                if (diagnostic && diagnostic_length &&
                    *diagnostic_length < diagnostic_capacity) {
                    size_t available = diagnostic_capacity - *diagnostic_length;
                    size_t copy = (size_t)n < available ? (size_t)n : available;
                    memcpy(diagnostic + *diagnostic_length, window, copy);
                    *diagnostic_length += copy;
                }
                continue; /* Drain even after the diagnostic buffer fills. */
            }
            if (compile_only) { failed = fail_evaluation(&watchdog); break; }
            size_t offset = 0;
            while (offset < (size_t)n) {
                if (complete) { failed = fail_evaluation(&watchdog); break; }
                if (!remaining_chunk) {
                    while (offset < (size_t)n && header_used < sizeof(header))
                        header[header_used++] = window[offset++];
                    if (header_used != sizeof(header)) continue;
                    uint32_t length = 0;
                    for (unsigned i = 0; i < 4; i++)
                        length |= (uint32_t)header[i] << (8 * i);
                    header_used = 0;
                    if (!length) { complete = 1; continue; }
                    if (length > 16384) {
                        failed = fail_evaluation(&watchdog);
                        break;
                    }
                    remaining_chunk = length;
                }
                size_t body = (size_t)n - offset;
                if (body > remaining_chunk) body = remaining_chunk;
                if (body > UINT64_MAX - received || !append_output ||
                    append_output(output_context, window + offset, body)) {
                    failed = fail_evaluation(&watchdog);
                    break;
                }
                received += body;
                remaining_chunk -= (uint32_t)body;
                offset += body;
            }
        }
    }
    if (!failed && !compile_only && (!complete || remaining_chunk || header_used || !received))
        failed = fail_evaluation(&watchdog);
    close(output_pipe[0]);
    close(diagnostic_pipe[0]);
    if (!failed) {
        /* Keep pid custody. Clock validation and monitoring retirement are one
         * decision, competing with watchdog failure under the same mutex. */
        for (;;) {
            siginfo_t child = {0};
            if (waitid(P_PID, (id_t)pid, &child, WEXITED | WNOHANG | WNOWAIT)) {
                if (errno == EINTR) continue;
                failed = fail_evaluation(&watchdog);
                break;
            }
            pthread_mutex_lock(&watchdog.mutex);
            if (watchdog.outcome == watchdog_running) {
                int64_t now = milliseconds();
                enum terminal_observation observation = terminal_poll;
                if (child.si_pid == pid)
                    observation = child.si_code == CLD_EXITED && child.si_status == 0
                        ? terminal_success : terminal_child_failure;
                watchdog.outcome = terminal_decision(watchdog.outcome,
                    observation, now, watchdog.deadline, 0);
            }
            enum watchdog_outcome outcome = watchdog.outcome;
            pthread_mutex_unlock(&watchdog.mutex);
            if (outcome != watchdog_running) {
                failed = outcome != watchdog_stopped;
                break;
            }
            struct timespec pause = {0, 10000000};
            nanosleep(&pause, NULL);
        }
    }
    if (failed && kill(pid, SIGKILL) && errno != ESRCH)
        failed = 1;
    enum watchdog_outcome watchdog_result = watchdog_clock_failed;
    if (watchdog_started) {
        pthread_join(watchdog_thread, NULL);
        watchdog_result = watchdog.outcome;
        if (watchdog.signal_failed) watchdog_result = watchdog_failed;
        pthread_mutex_destroy(&watchdog.mutex);
        if (watchdog_result != watchdog_stopped) failed = 1;
    }
    /* Joining first is essential: until the watchdog can no longer signal,
     * waitpid must not release this numeric pid for reuse. */
    while (!reaped) {
        pid_t result = waitpid(pid, &status, 0);
        if (result == pid) reaped = 1;
        else if (result < 0 && errno != EINTR) {
            return -1;
        }
    }
    if (failed || !output_eof || !diagnostic_eof ||
        !WIFEXITED(status) || WEXITSTATUS(status) != 0 ||
        (!compile_only && (!complete || remaining_chunk || header_used || !received))) {
        return watchdog_result == watchdog_cancelled ? 1 : -1;
    }
    return 0;
}
