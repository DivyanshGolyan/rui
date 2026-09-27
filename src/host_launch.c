#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <crt_externs.h>
#include <spawn.h>
extern char **environ;
static int serve_stdout_at_entry = 1;
#endif

/* Only async-signal-safe operations run after fork. The parent owns the
 * CLOEXEC pipe until exec succeeds or a fixed-size errno is returned. */
static void fail_child(int report, int code) {
    (void)write(report, &code, sizeof(code));
    _exit(127);
}

#if defined(__APPLE__)
/* The spawn action gives the helper only /dev/null stdio and descriptor 3.
 * After exec the helper restores CLOEXEC before making its final child. */
int rui_launch_helper(const char *executable, const char *store) {
    if (fcntl(3, F_SETFD, FD_CLOEXEC) < 0) fail_child(3, errno);
    if (setsid() < 0) fail_child(3, errno);
    pid_t child = fork();
    if (child < 0) fail_child(3, errno);
    if (child > 0) _exit(0);
    const char *argv[] = {executable, "serve", "--store", store,
        "--active-capacity", "8", "--codex", NULL};
    execv(executable, (char *const *)argv);
    fail_child(3, errno);
    return 127;
}

/* Observe stdout before Zig initialization or allocator replacement can reuse
 * a missing fd 1. The spawn boundary already discarded every caller descriptor
 * except the helper's report pipe. */
__attribute__((constructor(101))) static void early_launch_helper(void) {
    if (*_NSGetArgc() < 2) return;
    char **args = *_NSGetArgv();
    if (strcmp(args[1], "serve") == 0) {
        serve_stdout_at_entry = fcntl(1, F_GETFD) >= 0;
        return;
    }
    if (*_NSGetArgc() != 4) return;
    if (strcmp(args[1], "--launch-helper") != 0) return;
    _exit(rui_launch_helper(args[2], args[3]));
}
#endif

int rui_serve_readiness_output_present(void) {
#if defined(__APPLE__)
    return serve_stdout_at_entry;
#else
    return fcntl(1, F_GETFD) >= 0;
#endif
}

/* Scope SIGPIPE suppression to the serving thread's readiness write. A
 * disconnected reader must reach Zig's failed-start diagnostic, not kill the
 * process; other threads and future workload children keep their signals. */
int rui_write_readiness(int fd, const unsigned char *data, size_t length) {
    sigset_t blocked, previous;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGPIPE);
    int result = pthread_sigmask(SIG_BLOCK, &blocked, &previous);
    if (result != 0) return result;
    int failure = 0;
    while (length > 0) {
        ssize_t count = write(fd, data, length);
        if (count > 0) {
            data += count;
            length -= (size_t)count;
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            failure = count == 0 ? EIO : errno;
            break;
        }
    }
    if (failure == EPIPE && !sigismember(&previous, SIGPIPE)) {
        sigset_t pending;
        if (sigpending(&pending) == 0 && sigismember(&pending, SIGPIPE)) {
            int signal_number;
            (void)sigwait(&blocked, &signal_number);
        }
    }
    result = pthread_sigmask(SIG_SETMASK, &previous, NULL);
    return failure != 0 ? failure : result;
}

/* Returns zero after exec, or an errno-style failure. The grandchild has no
 * terminal/session or inherited descriptor; its lifetime is independent of
 * this caller. Readiness and ownership are established separately by Rui. */
static int launch_detached(const char *executable, const char *store) {
    int channel[2];
    if (pipe(channel) != 0) return errno;
    int report = fcntl(channel[1], F_DUPFD_CLOEXEC, 4);
    if (report < 0) {
        int err = errno;
        close(channel[0]);
        close(channel[1]);
        return err;
    }
    close(channel[1]);
#if defined(__APPLE__)
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int err = posix_spawn_file_actions_init(&actions);
    if (err != 0) goto spawn_done;
    err = posix_spawnattr_init(&attributes);
    if (err != 0) goto actions_done;
    err = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    if (err != 0) goto attributes_done;
    for (int fd = 0; fd < 3; fd++) {
        err = posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0);
        if (err != 0) goto attributes_done;
    }
    err = posix_spawn_file_actions_adddup2(&actions, report, 3);
    if (err != 0) goto attributes_done;
    const char *helper[] = {executable, "--launch-helper", executable, store, NULL};
    pid_t child = -1;
    err = posix_spawn(&child, executable, &actions, &attributes, (char *const *)helper, environ);
attributes_done:
    posix_spawnattr_destroy(&attributes);
actions_done:
    posix_spawn_file_actions_destroy(&actions);
spawn_done:
    close(report);
    if (err != 0) {
        close(channel[0]);
        return err;
    }
#else
    pid_t child = fork();
    if (child < 0) {
        int err = errno;
        close(channel[0]);
        close(report);
        return err;
    }
    if (child == 0) {
        close(channel[0]);
        if (setsid() < 0) fail_child(report, errno);
        pid_t grandchild = fork();
        if (grandchild < 0) fail_child(report, errno);
        if (grandchild > 0) _exit(0);
        int null_fd = open("/dev/null", O_RDWR);
        if (null_fd < 0) fail_child(report, errno);
        for (int fd = 0; fd < 3; fd++) {
            if (dup2(null_fd, fd) < 0) fail_child(report, errno);
        }
        if (null_fd > 2 && null_fd != report) close(null_fd);
        /* Preserve the exec-error channel at 3, then close every other
         * descriptor, including ones above a subsequently lowered soft limit. */
        if (report != 3) {
            if (dup2(report, 3) < 0) fail_child(report, errno);
            close(report);
            report = 3;
        }
        if (fcntl(report, F_SETFD, FD_CLOEXEC) < 0) fail_child(report, errno);
        closefrom(4);
        const char *argv[] = {executable, "serve", "--store", store,
            "--active-capacity", "8", "--codex", NULL};
        execv(executable, (char *const *)argv);
        fail_child(report, errno);
    }
    close(report);
#endif
    int error_code = 0;
    ssize_t count;
    do {
        count = read(channel[0], &error_code, sizeof(error_code));
    } while (count < 0 && errno == EINTR);
    int read_error = count < 0 ? errno : count == 0 ? 0 :
        count == (ssize_t)sizeof(error_code) ? error_code : EIO;
    close(channel[0]);
    int status;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) return errno;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        if (read_error == 0) return EIO;
    }
    return read_error;
}

int rui_launch_detached(const char *executable, const char *store) {
    struct sigaction previous, normal = {0};
    normal.sa_handler = SIG_DFL;
    sigemptyset(&normal.sa_mask);
    if (sigaction(SIGCHLD, &normal, &previous) != 0) return errno;
    // The helper must remain waitable even when the caller inherited
    // SIG_IGN or SA_NOCLDWAIT. Its Host grandchild also inherits SIG_DFL.
    int result = launch_detached(executable, store);
    int restore_error = sigaction(SIGCHLD, &previous, NULL) == 0 ? 0 : errno;
    return result != 0 ? result : restore_error;
}
