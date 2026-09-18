#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>

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
        break;
    case CLD_KILLED:
    case CLD_DUMPED:
        observation->kind = 2;
        break;
    default:
        observation->kind = 3;
        break;
    }
    observation->value = info.si_status;
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
