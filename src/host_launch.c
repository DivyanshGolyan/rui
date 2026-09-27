#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stddef.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

/* Only async-signal-safe operations run after fork. The parent owns the
 * CLOEXEC pipe until exec succeeds or a fixed-size errno is returned. */
static void fail_child(int report, int code) {
    (void)write(report, &code, sizeof(code));
    _exit(127);
}

/* Returns zero after exec, or an errno-style failure. The grandchild has no
 * terminal/session or inherited descriptor; its lifetime is independent of
 * this caller. Readiness and ownership are established separately by Rui. */
int rui_launch_detached(const char *executable, const char *store) {
#if defined(__APPLE__)
    /* Darwin has no closefrom; the hard limit still covers descriptors
     * opened before a caller lowers only its soft limit. */
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) != 0) return errno;
    if (limit.rlim_max == RLIM_INFINITY || limit.rlim_max > INT_MAX) return ENOTSUP;
    int last_fd = (int)limit.rlim_max;
#endif
    int channel[2];
    if (pipe(channel) != 0) return errno;
    int report = fcntl(channel[1], F_DUPFD_CLOEXEC, 3);
    if (report < 0) {
        int err = errno;
        close(channel[0]);
        close(channel[1]);
        return err;
    }
    close(channel[1]);
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
#if defined(__APPLE__)
        for (int fd = 4; fd < last_fd; fd++) close(fd);
#else
        closefrom(4);
#endif
        const char *argv[] = {executable, "serve", "--store", store,
            "--active-capacity", "8", "--codex", NULL};
        execv(executable, (char *const *)argv);
        fail_child(report, errno);
    }
    close(report);
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
    return read_error;
}
