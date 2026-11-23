#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#else
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <fcntl.h>
#ifdef __APPLE__
#include <libproc.h>
#else
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#endif
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

/* Returns 1 when no process but `leader` belongs to `pgid`, 0 when another
   member may exist and -errno when the group cannot be listed. A miss is safe:
   it only ends the graceful TERM window early, and KILL plus the absence probe
   still retire the group. */
int rui_bash_group_holds_only(pid_t pgid, pid_t leader) {
#ifdef __APPLE__
    pid_t members[64];
    int bytes = proc_listpids(PROC_PGRP_ONLY, (uint32_t)pgid, members, sizeof(members));
    if (bytes < 0) return -errno;
    if ((size_t)bytes >= sizeof(members)) return 0;
    for (int i = 0; i < bytes / (int)sizeof(pid_t); i++) {
        if (members[i] != 0 && members[i] != leader) return 0;
    }
    return 1;
#else
    DIR *proc = opendir("/proc");
    if (proc == NULL) return -errno;
    int alone = 1;
    struct dirent *entry;
    while (alone == 1 && (entry = readdir(proc)) != NULL) {
        char *end;
        long pid = strtol(entry->d_name, &end, 10);
        if (*end != '\0' || pid <= 0 || pid == leader) continue;
        char path[64], stat[512];
        snprintf(path, sizeof(path), "/proc/%ld/stat", pid);
        int fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd < 0) {
            if (errno != ENOENT && errno != ESRCH) alone = 0;
            continue;
        }
        ssize_t count = read(fd, stat, sizeof(stat) - 1);
        close(fd);
        if (count <= 0) {
            if (count < 0 && errno != ESRCH) alone = 0;
            continue;
        }
        stat[count] = '\0';
        /* comm may hold spaces or parentheses; fields resume after the last ')'. */
        char *fields = strrchr(stat, ')');
        int parent, group;
        char state;
        if (fields == NULL || sscanf(fields + 1, " %c %d %d", &state, &parent, &group) != 3) {
            alone = 0;
        } else if (group == pgid) {
            alone = 0;
        }
    }
    closedir(proc);
    return alone;
#endif
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

int rui_bash_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                   pid_t *pid, int *stdout_read, int *stderr_read, int stdin_read) {
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
    if (result == 0) result = stdin_read < 0
        ? posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDWR, 0)
        : posix_spawn_file_actions_adddup2(&actions, stdin_read, 0);
    if (result == 0) result = posix_spawn_file_actions_adddup2(&actions, out[1], 1);
    if (result == 0) result = posix_spawn_file_actions_adddup2(&actions, err_pipe[1], 2);
    if (result == 0) result = posix_spawnattr_init(&attributes);
    if (result == 0) have_attributes = 1;
    if (result == 0) result = posix_spawnattr_setflags(&attributes,
        POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
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
