#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <crt_externs.h>
#include <spawn.h>
#include <sys/sysctl.h>
#include <limits.h>
#endif
extern char **environ;
extern int rui_process_generation(int pid, unsigned long long *started);

int rui_raise_descriptor_limit(size_t required) {
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) != 0) return errno;
    if (limit.rlim_cur == RLIM_INFINITY || limit.rlim_cur >= required) return 0;
    rlim_t target = required;
    if (limit.rlim_max != RLIM_INFINITY && target > limit.rlim_max) target = limit.rlim_max;
#if defined(__APPLE__)
    /* Darwin rejects RLIM_INFINITY and values above its per-process ceiling. */
    int ceiling;
    size_t size = sizeof(ceiling);
    if (sysctlbyname("kern.maxfilesperproc", &ceiling, &size, NULL, 0) != 0) return errno;
    if (ceiling <= 0) return EINVAL;
    if (target > (rlim_t)ceiling) target = (rlim_t)ceiling;
    if (target > OPEN_MAX) target = OPEN_MAX;
#endif
    if (target <= limit.rlim_cur) return 0;
    limit.rlim_cur = target;
    return setrlimit(RLIMIT_NOFILE, &limit) == 0 ? 0 : errno;
}

/* Only async-signal-safe operations run after fork. The parent owns the
 * CLOEXEC pipe until exec succeeds or a fixed-size errno is returned. */
static void fail_child(int report, int code) {
    (void)write(report, &code, sizeof(code));
    _exit(127);
}

struct launch_receipt { int kind; int value; };
enum { receipt_pid = 1, receipt_error = 2, receipt_confirm = 3 };
enum { launch_report_fd = 3, launch_ack_fd = 4, launch_first_unreserved_fd = 5 };

static void write_receipt(int report, int kind, int value) {
    struct launch_receipt receipt = { kind, value };
    const unsigned char *bytes = (const unsigned char *)&receipt;
    size_t left = sizeof(receipt);
    while (left) {
        ssize_t count = write(report, bytes, left);
        if (count > 0) { bytes += count; left -= (size_t)count; }
        else if (count < 0 && errno == EINTR) continue;
        else _exit(127);
    }
}

static void confirm_generation(int report, int acknowledge) {
    write_receipt(report, receipt_pid, getpid());
    unsigned char release = 0;
    ssize_t count;
    do { count = read(acknowledge, &release, 1); } while (count < 0 && errno == EINTR);
    close(acknowledge);
    if (count != 1 || release != 1) _exit(127);
    write_receipt(report, receipt_confirm, getpid());
}

static void fail_launch(int report, int code, int exact) {
    if (exact) { write_receipt(report, receipt_error, code); _exit(127); }
    fail_child(report, code);
}

#if defined(__APPLE__)
static int launch_helper(char *const *argv, int exact) {
    if (fcntl(launch_report_fd, F_SETFD, FD_CLOEXEC) < 0) fail_launch(launch_report_fd, errno, exact);
    if (exact && fcntl(launch_ack_fd, F_SETFD, FD_CLOEXEC) < 0) fail_launch(launch_report_fd, errno, exact);
    if (setsid() < 0) fail_launch(launch_report_fd, errno, exact);
    pid_t child = fork();
    if (child < 0) fail_launch(launch_report_fd, errno, exact);
    if (child > 0) _exit(0);
    if (chdir("/") < 0) fail_launch(launch_report_fd, errno, exact);
    if (exact) confirm_generation(launch_report_fd, launch_ack_fd);
    execve(argv[0], argv, environ);
    fail_launch(launch_report_fd, errno, exact);
    return 127;
}

__attribute__((constructor(101))) static void early_launch_helper(void) {
    if (*_NSGetArgc() < 3) return;
    char **args = *_NSGetArgv();
    int exact = strcmp(args[1], "--launch-exact-helper") == 0;
    if (!exact && strcmp(args[1], "--launch-helper") != 0) return;
    /* OS-provided terminated argv is in final storage before the helper fork
     * and before ordinary Zig initialization. */
    _exit(launch_helper(&args[2], exact));
}
#endif

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
 * this caller. Readiness and ownership are established separately by Rui.
 * Borrow the caller's bounded, terminated argv through exec/error handoff;
 * argv[0] is executable and argc excludes the NULL terminator. */
static int launch_detached(const char *helper_executable, const char *executable,
                           const char *const *argv, size_t argc,
                           const char *const *envp, int startup_write, int *launched_pid,
                           unsigned long long *launched_started) {
    int exact = launched_pid != NULL;
#if defined(__APPLE__)
    (void)executable;
    /* Transport framing only; application policy belongs to the caller.
     * Prepare before spawn, not in the post-fork grandchild. */
    const char *helper[argc + 3];
    helper[0] = helper_executable;
    helper[1] = exact ? "--launch-exact-helper" : "--launch-helper";
    for (size_t i = 0; i < argc; i++) helper[i + 2] = argv[i];
    helper[argc + 2] = NULL;
#else
    (void)argc;
    (void)helper_executable;
#endif
    int channel[2];
    if (pipe(channel) != 0) return errno;
    int report = fcntl(channel[1], F_DUPFD_CLOEXEC, launch_first_unreserved_fd);
    if (report < 0) {
        int err = errno;
        close(channel[0]);
        close(channel[1]);
        return err;
    }
    close(channel[1]);
    int acknowledge[2] = {-1, -1};
    int gate = -1;
    if (exact) {
        int error = pipe(acknowledge) == 0 ? 0 : errno;
        if (!error) {
            gate = fcntl(acknowledge[0], F_DUPFD_CLOEXEC, launch_first_unreserved_fd);
            if (gate < 0 || fcntl(acknowledge[1], F_SETFD, FD_CLOEXEC) < 0) error = errno;
            close(acknowledge[0]);
        }
        if (error) {
            if (gate >= 0) close(gate);
            if (acknowledge[1] >= 0) close(acknowledge[1]);
            close(channel[0]);
            close(report);
            return error;
        }
    }
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
    if (startup_write >= 0) {
        err = posix_spawn_file_actions_adddup2(&actions, startup_write, 2);
        if (err != 0) goto attributes_done;
    }
    err = posix_spawn_file_actions_adddup2(&actions, report, launch_report_fd);
    if (err != 0) goto attributes_done;
    if (exact) {
        err = posix_spawn_file_actions_adddup2(&actions, gate, launch_ack_fd);
        if (err != 0) goto attributes_done;
    }
    pid_t child = -1;
    err = posix_spawn(&child, helper_executable, &actions, &attributes, (char *const *)helper, (char *const *)envp);
attributes_done:
    posix_spawnattr_destroy(&attributes);
actions_done:
    posix_spawn_file_actions_destroy(&actions);
spawn_done:
    close(report);
    if (gate >= 0) close(gate);
    if (err != 0) {
        if (acknowledge[1] >= 0) close(acknowledge[1]);
        close(channel[0]);
        return err;
    }
#else
    pid_t child = fork();
    if (child < 0) {
        int err = errno;
        close(channel[0]);
        close(report);
        if (gate >= 0) close(gate);
        if (acknowledge[1] >= 0) close(acknowledge[1]);
        return err;
    }
    if (child == 0) {
        close(channel[0]);
        if (setsid() < 0) fail_launch(report, errno, exact);
        pid_t grandchild = fork();
        if (grandchild < 0) fail_launch(report, errno, exact);
        if (grandchild > 0) _exit(0);
        int null_fd = open("/dev/null", O_RDWR);
        if (null_fd < 0) fail_launch(report, errno, exact);
        for (int fd = 0; fd < 3; fd++) {
            if (dup2(null_fd, fd) < 0) fail_launch(report, errno, exact);
        }
        if (startup_write >= 0 && dup2(startup_write, 2) < 0) fail_launch(report, errno, exact);
        if (null_fd > 2 && null_fd != report) close(null_fd);
        if (report != launch_report_fd) {
            if (dup2(report, launch_report_fd) < 0) fail_launch(report, errno, exact);
            close(report);
            report = launch_report_fd;
        }
        if (fcntl(report, F_SETFD, FD_CLOEXEC) < 0) fail_launch(report, errno, exact);
        if (exact && dup2(gate, launch_ack_fd) < 0) fail_launch(report, errno, exact);
        closefrom(exact ? launch_first_unreserved_fd : launch_ack_fd);
        if (chdir("/") < 0) fail_launch(report, errno, exact);
        if (exact) confirm_generation(report, launch_ack_fd);
        execve(executable, (char *const *)argv, (char *const *)envp);
        fail_launch(report, errno, exact);
    }
    close(report);
    if (gate >= 0) close(gate);
#endif
    int read_error = 0;
    if (exact) {
        int confirmed = 0;
        for (;;) {
            struct launch_receipt receipt;
            size_t used = 0;
            while (used < sizeof(receipt)) {
                ssize_t count = read(channel[0], (unsigned char *)&receipt + used, sizeof(receipt) - used);
                if (count > 0) used += (size_t)count;
                else if (count < 0 && errno == EINTR) continue;
                else { if (count < 0) read_error = errno; break; }
            }
            if (read_error) break;
            if (used == 0) { if (!confirmed) read_error = EIO; break; }
            if (used != sizeof(receipt)) { read_error = EIO; break; }
            if (receipt.kind == receipt_error && receipt.value > 0) { read_error = receipt.value; break; }
            if (receipt.kind == receipt_confirm && receipt.value == *launched_pid &&
                *launched_started != 0 && !confirmed) { confirmed = 1; continue; }
            if (receipt.kind != receipt_pid || receipt.value <= 0 || *launched_pid != 0) { read_error = EIO; break; }
            *launched_pid = receipt.value;
            read_error = rui_process_generation(*launched_pid, launched_started);
            if (read_error) break;
            if (*launched_started == 0) { read_error = EIO; break; }
            const unsigned char release = 1;
            read_error = rui_write_readiness(acknowledge[1], &release, 1);
            close(acknowledge[1]);
            acknowledge[1] = -1;
            if (read_error) break;
        }
    } else {
        int error_code = 0;
        ssize_t count;
        do { count = read(channel[0], &error_code, sizeof(error_code)); } while (count < 0 && errno == EINTR);
        read_error = count < 0 ? errno : count == 0 ? 0 :
            count == (ssize_t)sizeof(error_code) ? error_code : EIO;
    }
    close(channel[0]);
    if (acknowledge[1] >= 0) close(acknowledge[1]);
    int status;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) return errno;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        if (read_error == 0) return EIO;
    }
    return read_error;
}

static int launch_with_signals(const char *helper_executable, const char *executable,
                               const char *const *argv, size_t argc,
                               const char *const *envp, int startup_write, int *launched_pid,
                               unsigned long long *launched_started) {
    struct sigaction previous, normal = {0};
    normal.sa_handler = SIG_DFL;
    sigemptyset(&normal.sa_mask);
    if (sigaction(SIGCHLD, &normal, &previous) != 0) return errno;
    // The helper must remain waitable even when the caller inherited
    // SIG_IGN or SA_NOCLDWAIT. Its Host grandchild also inherits SIG_DFL.
    int result = launch_detached(helper_executable, executable, argv, argc, envp, startup_write, launched_pid, launched_started);
    int restore_error = sigaction(SIGCHLD, &previous, NULL) == 0 ? 0 : errno;
    return result != 0 ? result : restore_error;
}

int rui_launch_detached(const char *executable, const char *const *argv, size_t argc) {
    return launch_with_signals(executable, executable, argv, argc, (const char *const *)environ, -1, NULL, NULL);
}

static int launch_observed(const char *helper_executable, const char *executable,
                           const char *const *argv, size_t argc, const char *const *envp,
                           int *startup_read, int *launched_pid, unsigned long long *launched_started) {
    int channel[2];
    if (pipe(channel) != 0) return errno;
    int writer = fcntl(channel[1], F_DUPFD_CLOEXEC, launch_report_fd + 1);
    int result = writer < 0 ? errno : 0;
    close(channel[1]);
    if (result == 0 && (fcntl(channel[0], F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(channel[0], F_SETFL, O_NONBLOCK) < 0)) result = errno;
    if (result == 0) result = launch_with_signals(helper_executable, executable, argv, argc, envp, writer, launched_pid, launched_started);
    if (writer >= 0) close(writer);
    if (result != 0) close(channel[0]);
    else *startup_read = channel[0];
    return result;
}

int rui_launch_detached_observed(const char *executable, const char *const *argv, size_t argc, int *startup_read) {
    return launch_observed(executable, executable, argv, argc, (const char *const *)environ, startup_read, NULL, NULL);
}

/* The current executable supplies the Darwin bootstrap even for historical
 * target executables without a launch-helper constructor. envp is borrowed only
 * through the exec handoff, never stored or printed. launched_pid is evidence,
 * not a signal/stop handle; the caller still checks the actual socket peer. */
int rui_launch_pinned(const char *helper_executable, const char *executable,
                      const char *const *argv, size_t argc, const char *const *envp,
                      int *startup_read, int *launched_pid, unsigned long long *launched_started) {
    if (!startup_read || !launched_pid || !launched_started) return EINVAL;
    *startup_read = -1;
    *launched_pid = 0;
    *launched_started = 0;
    if (!helper_executable || helper_executable[0] != '/' || !executable || executable[0] != '/' ||
        !argv || !argc || !argv[0] || strcmp(argv[0], executable) != 0 || argv[argc] != NULL || !envp) return EINVAL;
    for (size_t i = 0; i < argc; i++) if (!argv[i]) return EINVAL;
    int result = launch_observed(helper_executable, executable, argv, argc, envp, startup_read, launched_pid, launched_started);
    if (result != 0) *launched_started = 0;
    return result;
}
