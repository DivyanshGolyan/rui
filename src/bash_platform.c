#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#else
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

struct rui_bash_observation {
    int32_t kind;
    int32_t value;
};

int rui_bash_observe(pid_t pid, struct rui_bash_observation *observation) {
    siginfo_t info;
    memset(&info, 0, sizeof(info));
    int result;
    do {
        result = waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT);
    } while (result != 0 && errno == EINTR);
    if (result != 0) {
        return -errno;
    }
    if (info.si_pid == 0) {
        return 0;
    }
    switch (info.si_code) {
    case CLD_EXITED:
        observation->kind = 1;
        /* Darwin waitid can retain the full exit value; waitpid exposes only
           its low byte. Keep observation and final reap on the same status. */
        observation->value = (uint8_t)info.si_status;
        break;
    case CLD_KILLED:
    case CLD_DUMPED:
        observation->kind = 2;
        observation->value = info.si_status;
        break;
    default:
        observation->kind = 3;
        observation->value = info.si_status;
        break;
    }
    return 1;
}

int rui_bash_reap(pid_t pid, struct rui_bash_observation *observation) {
    int status = 0;
    pid_t result;
    do {
        result = waitpid(pid, &status, WNOHANG);
    } while (result < 0 && errno == EINTR);
    if (result < 0) {
        return -errno;
    }
    if (result == 0) {
        return 0;
    }
    if (result != pid) {
        return -ECHILD;
    }
    if (WIFEXITED(status)) {
        observation->kind = 1;
        observation->value = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        observation->kind = 2;
        observation->value = WTERMSIG(status);
    } else {
        observation->kind = 3;
        observation->value = status;
    }
    return 1;
}

int rui_bash_pipe_queued_bytes(int fd, uint64_t *bytes) {
    int queued = 0;
    if (ioctl(fd, FIONREAD, &queued) != 0) {
        return -errno;
    }
    if (queued < 0) {
        return -EIO;
    }
    *bytes = (uint64_t)queued;
    return 0;
}

int rui_bash_group_absent(pid_t pgid) {
    if (kill(-pgid, 0) == 0) {
        return 0;
    }
    if (errno == ESRCH) {
        return 1;
    }
    if (errno == EPERM) {
        return 0;
    }
    return -errno;
}

static int make_pipe(int fds[2]) {
#ifdef __APPLE__
    if (pipe(fds) != 0) return errno;
    if (fcntl(fds[0], F_SETFD, FD_CLOEXEC) == 0 && fcntl(fds[1], F_SETFD, FD_CLOEXEC) == 0) return 0;
    int err = errno;
    close(fds[0]);
    close(fds[1]);
    return err;
#else
    return pipe2(fds, O_CLOEXEC) == 0 ? 0 : errno;
#endif
}

/* Launch Bash as the leader of a new process group with /dev/null stdin and
   piped stdout/stderr. The child starts with an empty signal mask and every
   signal at its default action, whatever the Host thread blocked or the Host
   inherited as ignored; caught handlers never survive exec anyway. /dev/null
   is opened by the spawn itself, so the Host keeps no inheritable descriptor.
   Other descriptors keep their own close-on-exec flags. A path without '/'
   is searched on the Host's PATH. Returns 0 or errno; on success the parent
   owns both read ends, close-on-exec. */
int rui_bash_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                   pid_t *pid, int *stdout_read, int *stderr_read) {
    int out[2], err_pipe[2];
    int result = make_pipe(out);
    if (result != 0) return result;
    result = make_pipe(err_pipe);
    if (result != 0) {
        close(out[0]);
        close(out[1]);
        return result;
    }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    sigset_t empty, all;
    sigemptyset(&empty);
    sigfillset(&all);
    int have_actions = 0, have_attributes = 0;
    result = posix_spawn_file_actions_init(&actions);
    if (result == 0) have_actions = 1;
    if (result == 0) result = posix_spawn_file_actions_addchdir_np(&actions, cwd);
    if (result == 0) result = posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDWR, 0);
    if (result == 0) result = posix_spawn_file_actions_adddup2(&actions, out[1], 1);
    if (result == 0) result = posix_spawn_file_actions_adddup2(&actions, err_pipe[1], 2);
    if (result == 0) result = posix_spawnattr_init(&attributes);
    if (result == 0) have_attributes = 1;
    if (result == 0) result = posix_spawnattr_setflags(&attributes,
        POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
    if (result == 0) result = posix_spawnattr_setpgroup(&attributes, 0);
    if (result == 0) result = posix_spawnattr_setsigmask(&attributes, &empty);
    if (result == 0) result = posix_spawnattr_setsigdefault(&attributes, &all);
    if (result == 0) result = posix_spawnp(pid, path, &actions, &attributes, argv, envp);
    if (have_attributes) posix_spawnattr_destroy(&attributes);
    if (have_actions) posix_spawn_file_actions_destroy(&actions);
    close(out[1]);
    close(err_pipe[1]);
    if (result != 0) {
        close(out[0]);
        close(err_pipe[0]);
        return result;
    }
    *stdout_read = out[0];
    *stderr_read = err_pipe[0];
    return 0;
}
