#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#else
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <sys/un.h>
/* XNU bsd/sys/codesign.h and osfmk/kern/cs_blobs.h; these stable
 * syscall constants are not exposed by every public SDK. */
extern int csops(pid_t, unsigned int, void *, size_t);
enum { rui_cs_ops_status = 0, rui_cs_restrict = 0x00000800 };
#endif

/* Observation only: neither a PID nor these bytes authorize process mutation.
 * argv/environ are process memory, not immutable kernel launch records. Two
 * matching observations reject ordinary races, not a hostile same-user process. */
static void wipe(void *bytes, size_t length) {
    volatile unsigned char *p = bytes;
    while (length--) *p++ = 0;
}

int rui_host_peer_pid(int socket, int *pid) {
    if (!pid) return EINVAL;
    *pid = 0;
#if defined(__linux__)
    struct ucred credentials;
    socklen_t size = sizeof(credentials);
    if (getsockopt(socket, SOL_SOCKET, SO_PEERCRED, &credentials, &size) != 0) return errno;
    if (size != sizeof(credentials) || credentials.pid <= 0) return EIO;
    if (credentials.uid != geteuid()) return EPERM;
    *pid = credentials.pid;
    return 0;
#elif defined(__APPLE__)
    uid_t uid;
    gid_t gid;
    if (getpeereid(socket, &uid, &gid) != 0) return errno;
    if (uid != geteuid()) return EPERM;
    pid_t peer = 0;
    socklen_t size = sizeof(peer);
    if (getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) != 0) return errno;
    if (size != sizeof(peer) || peer <= 0) return EIO;
    *pid = peer;
    return 0;
#else
    (void)socket;
    return ENOTSUP;
#endif
}

struct identity {
    unsigned long long started;
    dev_t device;
    ino_t inode;
    char executable[PATH_MAX];
};

static int canonical(const char *path, struct identity *result) {
    if (path[0] != '/') return EINVAL;
    if (!realpath(path, result->executable)) return errno;
    struct stat file;
    if (stat(result->executable, &file) != 0) return errno;
    if (!S_ISREG(file.st_mode)) return EINVAL;
    result->device = file.st_dev;
    result->inode = file.st_ino;
    return 0;
}

#if defined(__linux__)
/* A directory descriptor never retargets a reused PID. All subsequent proc
 * reads are relative to this descriptor, including the final fingerprint. */
static int read_proc(int directory, const char *name, unsigned char *data, size_t cap, size_t *length) {
    int fd = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return errno;
    size_t used = 0;
    int error = 0;
    while (used < cap) {
        ssize_t count = read(fd, data + used, cap - used);
        if (count > 0) used += (size_t)count;
        else if (count == 0) break;
        else if (errno != EINTR) { error = errno; break; }
    }
    if (!error && used == cap) {
        unsigned char extra;
        ssize_t count;
        do { count = read(fd, &extra, 1); } while (count < 0 && errno == EINTR);
        error = count < 0 ? errno : count == 0 ? 0 : E2BIG;
        extra = 0;
    }
    close(fd);
    if (!error) *length = used;
    return error;
}

static int observe_generation(int pid, int directory, unsigned long long *started) {
    (void)pid;
    struct stat owner;
    if (fstat(directory, &owner) != 0) return errno;
    if (owner.st_uid != geteuid()) return EPERM;
    unsigned char bytes[4096];
    size_t length;
    int error = read_proc(directory, "stat", bytes, sizeof(bytes) - 1, &length);
    if (error) return error;
    bytes[length] = 0;
    /* comm may contain spaces, newlines and ')' characters; only the last
     * ')' precedes the numeric fields. starttime is field 22. */
    char *end = strrchr((char *)bytes, ')');
    if (!end || end[1] != ' ') return EINVAL;
    char *cursor = end + 2;
    for (unsigned field = 3; field < 22; field++) {
        char *space = strchr(cursor, ' ');
        if (!space || space == cursor) return EINVAL;
        cursor = space + 1;
    }
    if (*cursor < '0' || *cursor > '9') return EINVAL;
    errno = 0;
    *started = strtoull(cursor, &end, 10);
    if (errno || *end != ' ' || *started == 0) return EINVAL;

    /* The proc directory's owner may be root for a nondumpable task. Check
     * effective uid explicitly too, never use root's privilege to inspect a
     * different user's environment. */
    error = read_proc(directory, "status", bytes, sizeof(bytes) - 1, &length);
    if (error) return error;
    bytes[length] = 0;
    char *uids = strstr((char *)bytes, "\nUid:\t");
    unsigned long real_uid, effective_uid;
    if (!uids || sscanf(uids + 6, "%lu %lu", &real_uid, &effective_uid) != 2) return EINVAL;
    if (effective_uid != (unsigned long)geteuid()) return EPERM;

    return 0;
}

static int observe(int pid, int directory, struct identity *result) {
    int error = observe_generation(pid, directory, &result->started);
    if (error) return error;
    char path[PATH_MAX];
    ssize_t count = readlinkat(directory, "exe", path, sizeof(path) - 1);
    if (count < 0) return errno;
    if (count == (ssize_t)sizeof(path) - 1) return ENAMETOOLONG;
    path[count] = 0;
    error = canonical(path, result);
    if (error) return error;
    /* Reject deleted/replaced executable paths and namespace ambiguity. */
    struct stat actual;
    if (fstatat(directory, "exe", &actual, 0) != 0) return errno;
    if (actual.st_dev != result->device || actual.st_ino != result->inode) return ESTALE;
    return 0;
}

static int arguments(int pid, int directory, unsigned char *data, size_t cap,
                     size_t *length, size_t *argc, size_t *env_offset) {
    (void)pid;
    size_t args_length;
    int error = read_proc(directory, "cmdline", data, cap, &args_length);
    if (error) return error;
    if (!args_length || data[args_length - 1] != 0) return EINVAL;
    *argc = 0;
    for (size_t i = 0; i < args_length; i++) if (!data[i]) ++*argc;
    *env_offset = args_length;
    size_t env_length;
    error = read_proc(directory, "environ", data + args_length, cap - args_length, &env_length);
    if (error) return error;
    *length = args_length + env_length;
    return 0;
}
#elif defined(__APPLE__)
static int observe_generation(int pid, int directory, unsigned long long *started) {
    (void)directory;
    struct proc_bsdinfo info;
    errno = 0;
    int count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (count != sizeof(info)) return errno ? errno : ESRCH;
    if (info.pbi_pid != (uint32_t)pid || info.pbi_uid != geteuid()) return EPERM;
    if (info.pbi_start_tvsec > ULLONG_MAX / 1000000 || info.pbi_start_tvusec >= 1000000 ||
        (info.pbi_start_tvsec == ULLONG_MAX / 1000000 && info.pbi_start_tvusec > ULLONG_MAX % 1000000)) return EINVAL;
    *started = info.pbi_start_tvsec * 1000000 + info.pbi_start_tvusec;
    if (!*started) return EINVAL;
    return 0;
}

static int observe(int pid, int directory, struct identity *result) {
    unsigned int signing_flags = 0;
    if (csops(pid, rui_cs_ops_status, &signing_flags, sizeof(signing_flags)) != 0) return errno;
    if (signing_flags & rui_cs_restrict) return EPERM;
    int error = observe_generation(pid, directory, &result->started);
    if (error) return error;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    int count = proc_pidpath(pid, path, sizeof(path));
    if (count <= 0) return errno ? errno : ESRCH;
    if (!memchr(path, 0, sizeof(path))) return ENAMETOOLONG;
    return canonical(path, result);
}

static int arguments(int pid, int directory, unsigned char *data, size_t cap,
                     size_t *length, size_t *argc, size_t *env_offset) {
    (void)directory;
    int mib[] = { CTL_KERN, KERN_PROCARGS2, pid };
    /* KERN_PROCARGS2 rejects a requested size above kern.argmax. */
    int argmax_mib[] = { CTL_KERN, KERN_ARGMAX };
    int argmax = 0;
    size_t argmax_size = sizeof(argmax);
    if (sysctl(argmax_mib, 2, &argmax, &argmax_size, NULL, 0) != 0) return errno;
    if (argmax_size != sizeof(argmax) || argmax <= 0) return EINVAL;
    size_t kernel_cap = (size_t)argmax + sizeof(int);
    size_t used = cap < kernel_cap ? cap : kernel_cap;
    /* Small buffers trigger legacy silent truncation in XNU, not ENOMEM. */
    size_t required = 0;
    if (sysctl(mib, 3, NULL, &required, NULL, 0) != 0) return errno;
    if (required > used) return E2BIG;
    if (sysctl(mib, 3, data, &used, NULL, 0) != 0) return errno;
    if (used > cap || used < sizeof(int)) return EINVAL;
    int count;
    memcpy(&count, data, sizeof(count));
    if (count <= 0 || (size_t)count > used - sizeof(int)) return EINVAL;
    size_t start = sizeof(int);
    unsigned char *end = memchr(data + start, 0, used - start);
    if (!end) return EINVAL;
    start = (size_t)(end - data) + 1;
    while (start < used && data[start] == 0) start++;
    size_t cursor = start;
    for (int i = 0; i < count; i++) {
        if (cursor >= used) return EINVAL;
        end = memchr(data + cursor, 0, used - cursor);
        if (!end) return EINVAL;
        cursor = (size_t)(end - data) + 1;
    }
    *argc = (size_t)count;
    *env_offset = cursor - start;
    /* Darwin appends padding and Apple auxiliary strings after the empty
     * environment terminator. Those bytes are not environment entries. */
    size_t last = cursor;
    while (cursor < used && data[cursor]) {
        end = memchr(data + cursor, 0, used - cursor);
        if (!end) return EINVAL;
        cursor = (size_t)(end - data) + 1;
        last = cursor;
    }
    *length = last - start;
    memmove(data, data + start, *length);
    wipe(data + *length, used - *length);
    return 0;
}
#endif

int rui_process_generation(int pid, unsigned long long *started) {
    if (!started) return EINVAL;
    *started = 0;
    if (pid <= 0) return EINVAL;
#if defined(__linux__) || defined(__APPLE__)
    int directory = -1;
#if defined(__linux__)
    char path[64];
    int count = snprintf(path, sizeof(path), "/proc/%d", pid);
    if (count <= 0 || (size_t)count >= sizeof(path)) return EINVAL;
    directory = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (directory < 0) return errno;
#endif
    unsigned long long value = 0;
    int error = observe_generation(pid, directory, &value);
    if (directory >= 0) close(directory);
    if (!error) *started = value;
    return error;
#else
    return ENOTSUP;
#endif
}

static int valid_environment(const unsigned char *data, size_t length, size_t start) {
    while (start < length) {
        const unsigned char *end = memchr(data + start, 0, length - start);
        if (!end) return EINVAL;
        const unsigned char *equals = memchr(data + start, '=', (size_t)(end - data) - start);
        if (!equals || equals == data + start) return EINVAL;
        start = (size_t)(end - data) + 1;
    }
    return 0;
}

int rui_process_snapshot(int pid, char *exe, size_t exe_cap, unsigned char *data,
                         size_t cap, size_t *length, size_t *argc, size_t *env_offset,
                         unsigned long long *started) {
    if (pid <= 0 || !exe || !exe_cap || !data || !cap ||
        !length || !argc || !env_offset || !started) return EINVAL;
    *length = *argc = *env_offset = 0;
    *started = 0;
    exe[0] = 0;
#if defined(__linux__) || defined(__APPLE__)
    int directory = -1;
#if defined(__linux__)
    char path[64];
    int count = snprintf(path, sizeof(path), "/proc/%d", pid);
    if (count <= 0 || (size_t)count >= sizeof(path)) return EINVAL;
    directory = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (directory < 0) return errno;
#endif
    struct identity before, after;
    unsigned char *check = NULL;
    int error = observe(pid, directory, &before);
    if (error) goto done;
    error = arguments(pid, directory, data, cap, length, argc, env_offset);
    if (error) goto done;
    error = valid_environment(data, *length, *env_offset);
    if (error) goto done;
    check = malloc(cap);
    if (!check) { error = ENOMEM; goto done; }
    size_t check_length, check_argc, check_env;
    error = arguments(pid, directory, check, cap, &check_length, &check_argc, &check_env);
    if (error) goto done;
    if (check_length != *length || check_argc != *argc || check_env != *env_offset ||
        memcmp(check, data, *length) != 0) { error = ESTALE; goto done; }
    error = observe(pid, directory, &after);
    if (error) goto done;
    if (before.started != after.started || before.device != after.device || before.inode != after.inode ||
        strcmp(before.executable, after.executable) != 0) { error = ESTALE; goto done; }
    size_t exe_length = strlen(before.executable);
    if (exe_length >= exe_cap) { error = ENAMETOOLONG; goto done; }
    memcpy(exe, before.executable, exe_length + 1);
    *started = before.started;
done:
    if (directory >= 0) close(directory);
    if (check) { wipe(check, cap); free(check); }
    if (error) {
        wipe(data, cap);
        *length = *argc = *env_offset = 0;
        *started = 0;
        exe[0] = 0;
    }
    return error;
#else
    return ENOTSUP;
#endif
}
