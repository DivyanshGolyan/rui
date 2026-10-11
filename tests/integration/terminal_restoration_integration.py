#!/usr/bin/env python3
"""Real editor handoff, queued input and independently failed cleanup effects."""
import fcntl
import json
import os
import pathlib
import pty
import select
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import termios
import threading
import time

import canonical_failure_integration as canonical
import dispatch_integration as fixture
import human_cli_integration as human
from host_process import HostStartError, canonical_fixture_root, start_ready_process


def assert_file_flags(actual, expected):
    # XNU xnu-11417.140.69 exposes kernel-only FWASWRITTEN through F_GETFL.
    # A positive write sets it; successful F_SETFL cannot clear write history.
    # Keep every other bit, including access mode and O_NONBLOCK, exact.
    history = 0x00010000 if sys.platform == "darwin" else 0
    assert actual & ~history == expected & ~history, (
        f"file flags actual={actual:#x} expected={expected:#x} excluded={history:#x}")


PROBE = r"""
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <termios.h>
#include <unistd.h>

static int disabled = 0;
static int detach_phase = 0;
static atomic_int readiness_held = 0;

static void record(const char *text) {
    int fd = open(getenv("RUI_TERMINAL_PROBE"), O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0 || write(fd, text, strlen(text)) != (ssize_t)strlen(text)) _exit(90);
    if (close(fd)) _exit(91);
}

__attribute__((constructor)) static void diagnostic_alias(void) {
    const char *fault = getenv("RUI_TERMINAL_FAULT");
    if (fault && (!strcmp(fault, "readiness-alias") || !strncmp(fault, "readiness-held", 14))) {
        if (dup2(1, 2) < 0) _exit(88);
        record("readiness-aliased\n");
    }
}

static int probe_pthread_create(pthread_t *thread, const pthread_attr_t *attrs,
        void *(*run)(void *), void *arg) {
#ifdef __APPLE__
    int (*real_create)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *) = pthread_create;
#else
    int (*real_create)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *) = dlsym(RTLD_NEXT, "pthread_create");
#endif
    if (!real_create || real_create == probe_pthread_create) _exit(89);
    const char *arm = getenv("RUI_TERMINAL_STARTUP_ARM");
    if (arm && !access(arm, F_OK)) {
        record("worker-not-started\n");
        return EAGAIN;
    }
    return real_create(thread, attrs, run, arg);
}

static ssize_t probe_writev(int fd, const struct iovec *iov, int count) {
#ifdef __APPLE__
    /* dyld exempts references from the tuple-owning image, not dlsym. */
    ssize_t (*real_writev)(int, const struct iovec *, int) = writev;
#else
    ssize_t (*real_writev)(int, const struct iovec *, int) = dlsym(RTLD_NEXT, "writev");
    if (real_writev == writev) _exit(93);
#endif
    if (!real_writev || real_writev == probe_writev) _exit(93);
    const char *fault = getenv("RUI_TERMINAL_FAULT");
    static int stopped = 0;
    if (fd == 1 && count == 1 && iov[0].iov_len == 8 &&
        !memcmp(iov[0].iov_base, "\033[?2004l", 8)) {
        if (!strcmp(fault, "output") && !stopped) {
            if (tcflow(fd, TCOOFF)) _exit(92);
            stopped = 1;
            record("output-stopped\n");
        }
        record("disable\n");
        disabled = 1;
        if (!strcmp(fault, "disable") || !strcmp(fault, "both")) {
            errno = EIO;
            return -1;
        }
    }
    return real_writev(fd, iov, count);
}

static ssize_t probe_write(int fd, const void *bytes, size_t count) {
    const char *readiness_fault = getenv("RUI_TERMINAL_FAULT");
    if (fd == 1 && readiness_fault && !strcmp(readiness_fault, "alias-poison"))
        record("readiness-write-entry\n");
    if (fd == 2 && atomic_load(&readiness_held)) record("readiness-fd2-write\n");
    if (fd == 1 && readiness_fault && !strncmp(readiness_fault, "readiness-held", 14)) {
        atomic_store(&readiness_held, 1);
        record("readiness-held\n");
        while (access(getenv("RUI_DIAGNOSTIC_RELEASE"), F_OK)) usleep(1000);
        atomic_store(&readiness_held, 0);
        if (!strcmp(readiness_fault, "readiness-held-error")) {
            record("readiness-write-failed\n"); errno = EIO; return -1;
        }
    }
    if (fd == 1 && readiness_fault && !strcmp(readiness_fault, "readiness-error")) {
        record("readiness-write-failed\n"); errno = EIO; return -1;
    }
    if (fd == 1 && count == 8 && !memcmp(bytes, "\033[?2004l", 8)) {
        struct iovec iov = { (void *)bytes, count };
        return probe_writev(fd, &iov, 1);
    }
#ifdef __APPLE__
    ssize_t (*real_write)(int, const void *, size_t) = write;
#else
    ssize_t (*real_write)(int, const void *, size_t) = dlsym(RTLD_NEXT, "write");
    if (real_write == write) _exit(96);
#endif
    if (!real_write || real_write == probe_write) _exit(96);
    const char *fault = getenv("RUI_TERMINAL_FAULT");
    const char *diagnostic_arm = getenv("RUI_DIAGNOSTIC_ARM");
    if (fd == 2 && diagnostic_arm && !access(diagnostic_arm, F_OK)) {
        const char phase[] = "{\"rui_test_phase\":\"inspection_captured\",";
        const char subject[] = ",\"subject_kind\":\"session\",\"subject\":\"diagnostic/session\"";
        static atomic_int contention_claimed = 0;
        int selected = 0;
        if (!strcmp(fault, "diagnostic-contention") && count >= sizeof(phase) - 1 &&
            !memcmp(bytes, phase, sizeof(phase) - 1) && count >= 2 &&
            !memcmp((const char *)bytes + count - 2, "}\n", 2)) {
            for (size_t i = 0; i + sizeof(subject) - 1 < count; ++i) {
                if (!memcmp((const char *)bytes + i, subject, sizeof(subject) - 1) &&
                    (((const char *)bytes)[i + sizeof(subject) - 1] == ',' ||
                     ((const char *)bytes)[i + sizeof(subject) - 1] == '}')) selected = 1;
            }
        }
        if (selected && !atomic_exchange(&contention_claimed, 1)) {
            /* Complete fixed fixture identity, before the owned native write.
               The 512-byte buffer exceeds this phase/Session plus u64 metadata. */
            char correlation[512];
            if (count >= sizeof(correlation)) _exit(100);
            memcpy(correlation, bytes, count);
            correlation[count] = 0;
            record(correlation);
            record("diagnostic-held-inspection\n");
            while (access(getenv("RUI_DIAGNOSTIC_RELEASE"), F_OK)) usleep(1000);
        }
        record("diagnostic-write\n");
        static int partial_done = 0;
        static uint64_t partial_hash = 0;
        static size_t partial_count = 0;
        uint64_t hash = 14695981039346656037ULL;
        if (!strcmp(fault, "diagnostic-partial")) {
            for (size_t i = 0; i < count; ++i) hash = (hash ^ ((const unsigned char *)bytes)[i]) * 1099511628211ULL;
            if (partial_done && ((count == partial_count && hash == partial_hash) ||
                (count && ((const char *)bytes)[0] != '{'))) record("diagnostic-partial-retry\n");
        }
        if (!strcmp(fault, "diagnostic-partial") && !partial_done) {
            partial_done = 1;
            partial_hash = hash;
            partial_count = count;
            record("diagnostic-partial\n");
            return real_write(fd, bytes, count > 1 ? 1 : 0);
        }
    }
    const char *arm = getenv("RUI_TERMINAL_STREAM_ARM");
    const char *marker = "VISIBLE-CANCEL-PREFIX";
    static size_t matched = 0;
    static int visible = 0, stream_held = 0;
    int stream = fd == 1 && fault && !strcmp(fault, "visible-stream") && arm && !access(arm, F_OK);
    int reset = count == 4 && !memcmp(bytes, "\033[0m", 4);
    if (stream && visible && !disabled && !reset) {
        if (!stream_held) { record("visible-stream-held\n"); stream_held = 1; }
        errno = EAGAIN;
        return -1;
    }
    ssize_t result = real_write(fd, bytes, count);
    int saved_errno = errno;
    if (stream && result > 0 && !visible) {
        for (ssize_t i = 0; i < result; ++i) {
            char byte = ((const char *)bytes)[i];
            matched = byte == marker[matched] ? matched + 1 : (byte == marker[0] ? 1 : 0);
            if (!marker[matched]) { visible = 1; record("visible-prefix-written\n"); break; }
        }
    }
    static int choice = 0, choice_held = 0;
    if (fd == 1 && result == (ssize_t)count && fault && !strncmp(fault, "consent-", 8)) {
        if (count == strlen("a: Allow once / d: Deny (Enter)") &&
            !memcmp(bytes, "a: Allow once / d: Deny (Enter)", count)) choice = 1;
        if (choice && !choice_held && count >= 4 &&
            !memcmp(bytes, "\r\033[", 3) && ((const char *)bytes)[count - 1] == 'C') {
            choice_held = 1;
            record("choice-output-complete\n");
            while (access(getenv("RUI_TERMINAL_CHOICE_RELEASE"), F_OK)) usleep(1000);
        }
    }
    static int blocked = 0;
    if (fd == 1 && result < 0 && saved_errno == EAGAIN && !blocked &&
        !strcmp(getenv("RUI_TERMINAL_FAULT"), "backpressure")) {
        blocked = 1;
        record("output-blocked\n");
    }
    errno = saved_errno;
    return result;
}

#ifndef __APPLE__
#define probe_fcntl fcntl
#endif
int probe_fcntl(int fd, int command, ...) {
#ifdef __APPLE__
    int (*real_fcntl)(int, int, ...) = fcntl;
#else
    int (*real_fcntl)(int, int, ...) = dlsym(RTLD_NEXT, "fcntl");
#endif
    if (!real_fcntl || real_fcntl == probe_fcntl) _exit(98);
    if (fd == 2 && atomic_load(&readiness_held)) record("readiness-fd2-borrow\n");
    /* Reached no-argument/ignored-argument commands: descriptor queries and
       SQLite's macOS full_fsync. Never fetch an absent variadic argument. */
    if (command == F_GETFL || command == F_GETFD
#ifdef F_FULLFSYNC
        || command == F_FULLFSYNC
#endif
    ) return real_fcntl(fd, command);
#ifdef F_GETPATH
    if (command == F_GETPATH) {
        va_list args;
        va_start(args, command);
        char *path = va_arg(args, char *);
        va_end(args);
        return real_fcntl(fd, command, path);
    }
#endif
    if (command == F_GETLK || command == F_SETLK || command == F_SETLKW) {
        va_list args;
        va_start(args, command);
        struct flock *lock = va_arg(args, struct flock *);
        va_end(args);
        return real_fcntl(fd, command, lock);
    }
    /* Only the reached integer-valued commands are supported by this probe. */
    if (command != F_SETFL && command != F_SETFD && command != F_DUPFD
#ifdef F_DUPFD_CLOEXEC
        && command != F_DUPFD_CLOEXEC
#endif
    ) {
        char text[64];
        snprintf(text, sizeof(text), "unsupported-fcntl:%d\n", command);
        record(text);
        _exit(99);
    }
    va_list args;
    va_start(args, command);
    int value = va_arg(args, int);
    va_end(args);
    const char *diagnostic_arm = getenv("RUI_DIAGNOSTIC_ARM");
    const char *diagnostic_fault = getenv("RUI_TERMINAL_FAULT");
    if (fd == 2 && command == F_SETFL && diagnostic_arm && !access(diagnostic_arm, F_OK)) {
        if (value & O_NONBLOCK) {
            record("diagnostic-enable\n");
            if (!strcmp(diagnostic_fault, "diagnostic-enable-unmutated")) { errno = EIO; return -1; }
            int result = real_fcntl(fd, command, value);
            if (result) return result;
            record("diagnostic-mutated\n");
            if (!strcmp(diagnostic_fault, "diagnostic-enable")) { errno = EIO; return -1; }
            return result;
        }
        record("diagnostic-restore\n");
        if (!strcmp(diagnostic_fault, "diagnostic-restore") || !strcmp(diagnostic_fault, "alias-poison")) {
            record("diagnostic-unrestored\n"); errno = EIO; return -1;
        }
        int result = real_fcntl(fd, command, value);
        if (!result) record("diagnostic-restored\n");
        return result;
    }
    if (fd == 1 && command == F_SETFL && detach_phase) {
        const char *fault = getenv("RUI_TERMINAL_FAULT");
        if (detach_phase == 1 && !(value & O_NONBLOCK)) {
            int result = real_fcntl(fd, command, value);
            if (!result) { detach_phase = 2; record("cleanup-flags-restored\n"); }
            return result;
        }
        if (detach_phase == 2 && (value & O_NONBLOCK)) {
            detach_phase = 3;
            record("detach-enable\n");
            if (!strcmp(fault, "detach-enable")) { errno = EIO; return -1; }
        } else if (detach_phase == 3 && !(value & O_NONBLOCK)) {
            detach_phase = 4;
            record("detach-reset\n");
            if (!strcmp(fault, "detach-reset")) { errno = EIO; return -1; }
        }
    }
    return real_fcntl(fd, command, value);
}

static int probe_fsync(int fd) {
#ifdef __APPLE__
    int (*real_fsync)(int) = fsync;
#else
    int (*real_fsync)(int) = dlsym(RTLD_NEXT, "fsync");
    if (real_fsync == fsync) _exit(97);
#endif
    if (!real_fsync || real_fsync == probe_fsync) _exit(97);
    const char *gate = getenv("RUI_CAPTURE_SYNC_RELEASE");
    struct stat value;
    static int held = 0;
    if (gate && !held && !fstat(fd, &value) && S_ISDIR(value.st_mode)) {
        held = 1;
        record("capture-sync-held\n");
        while (access(gate, F_OK)) usleep(1000);
        if (getenv("RUI_CAPTURE_SYNC_ERROR")) { errno = EIO; return -1; }
    }
    return real_fsync(fd);
}

static int probe_tcdrain(int fd) {
#ifdef __APPLE__
    int (*real_tcdrain)(int) = tcdrain;
#else
    int (*real_tcdrain)(int) = dlsym(RTLD_NEXT, "tcdrain");
    if (real_tcdrain == tcdrain) _exit(94);
#endif
    if (!real_tcdrain || real_tcdrain == probe_tcdrain) _exit(94);
    if (fd == 1 && !strcmp(getenv("RUI_TERMINAL_FAULT"), "consent-cancel")) {
        record("choice-drain-held\n");
        while (access(getenv("RUI_TERMINAL_DRAIN_RELEASE"), F_OK)) usleep(1000);
    }
    if (fd == 1 && disabled) {
        record("drain\n");
        const char *fault = getenv("RUI_TERMINAL_FAULT");
        static int interrupted = 0;
        if (!strcmp(fault, "drain") || !strcmp(fault, "drain-both") || !strcmp(fault, "drain-incomplete")) {
            errno = ENOTTY;
            return -1;
        }
        if (!strcmp(fault, "drain-eintr") && !interrupted) {
            interrupted = 1;
            errno = EINTR;
            return -1;
        }
        if (!strcmp(fault, "drain-held")) {
            record("drain-held\n");
            while (access(getenv("RUI_TERMINAL_DRAIN_RELEASE"), F_OK)) usleep(1000);
        }
        disabled = 0;
    }
    return real_tcdrain(fd);
}

static int probe_tcsetattr(int fd, int action, const struct termios *attrs) {
#ifdef __APPLE__
    int (*real_tcsetattr)(int, int, const struct termios *) = tcsetattr;
#else
    int (*real_tcsetattr)(int, int, const struct termios *) = dlsym(RTLD_NEXT, "tcsetattr");
    if (real_tcsetattr == tcsetattr) _exit(95);
#endif
    if (!real_tcsetattr || real_tcsetattr == probe_tcsetattr) _exit(95);
    if (fd == 0 && (attrs->c_lflag & ICANON)) {
        record(action == TCSAFLUSH ? "restore-flush\n" : "restore-other\n");
        const char *fault = getenv("RUI_TERMINAL_FAULT");
        if (!strcmp(fault, "restore") || !strcmp(fault, "both") || !strcmp(fault, "drain-both") ||
            (!strcmp(fault, "startup-restore") && !access(getenv("RUI_TERMINAL_STARTUP_ARM"), F_OK))) {
            errno = ENOTTY;
            return -1;
        }
    }
    int result = real_tcsetattr(fd, action, attrs);
    const char *arm = getenv("RUI_TERMINAL_DETACH_ARM");
    if (!result && fd == 0 && (attrs->c_lflag & ICANON) && arm && !access(arm, F_OK)) detach_phase = 1;
    return result;
}

#ifdef __APPLE__
#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *new_fn; const void *old_fn; } \
    pair_##original __attribute__((section("__DATA,__interpose"))) = \
        { (const void *)&replacement, (const void *)&original };
INTERPOSE(probe_writev, writev)
INTERPOSE(probe_write, write)
INTERPOSE(probe_fsync, fsync)
INTERPOSE(probe_tcdrain, tcdrain)
INTERPOSE(probe_tcsetattr, tcsetattr)
INTERPOSE(probe_fcntl, fcntl)
INTERPOSE(probe_pthread_create, pthread_create)
#else
ssize_t writev(int fd, const struct iovec *iov, int count) { return probe_writev(fd, iov, count); }
ssize_t write(int fd, const void *bytes, size_t count) { return probe_write(fd, bytes, count); }
int fsync(int fd) { return probe_fsync(fd); }
int tcdrain(int fd) { return probe_tcdrain(fd); }
int tcsetattr(int fd, int action, const struct termios *attrs) { return probe_tcsetattr(fd, action, attrs); }
int pthread_create(pthread_t *thread, const pthread_attr_t *attrs, void *(*run)(void *), void *arg) {
    return probe_pthread_create(thread, attrs, run, arg);
}
#endif
"""


FORWARD_DRIVER = r"""
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/param.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc == 2) {
        const char *negative[] = {
            "{\"rui_test_phase\":\"lifecycle_service_observation\",\"subject_kind\":\"session\",\"subject\":\"diagnostic/session\"}\n",
            "{\"rui_test_phase\":\"inspection_captured\",\"subject_kind\":\"session\",\"subject\":\"diagnostic/session-extra\"}\n",
            "{\"rui_test_phase\":\"inspection_captured\",\"subject_kind\":\"path\",\"subject\":\"diagnostic/session\"}\n",
            "{\"rui_test_phase\":\"inspection_captured\",\"subject_kind\":\"session\",\"subject\":\"diagnostic/session\"}",
        };
        const char *positive = "{\"rui_test_phase\":\"inspection_captured\",\"subject_kind\":\"session\",\"subject\":\"diagnostic/session\",\"process\":\"driver\",\"run\":\"37\",\"sequence\":\"1\"}\n";
        int flags = fcntl(2, F_GETFL);
        if (flags < 0) return 30;
        int count = !strcmp(argv[1], "contention-negatives") ? 4 : 1;
        if (count == 1 && strcmp(argv[1], "contention-positive")) return 31;
        for (int i = 0; i < count; ++i) {
            const char *text = count == 4 ? negative[i] : positive;
            if (fcntl(2, F_SETFL, flags | O_NONBLOCK) || write(2, text, strlen(text)) != (ssize_t)strlen(text) ||
                fcntl(2, F_SETFL, flags)) return 32;
            if ((fcntl(2, F_GETFL) & O_NONBLOCK) != (flags & O_NONBLOCK)) return 33;
        }
        return 0;
    }
#ifdef F_GETPATH
    char path[MAXPATHLEN], expected[MAXPATHLEN];
    if (ttyname_r(1, expected, sizeof(expected)) || fcntl(1, F_GETPATH, path) ||
        strcmp(path, expected)) return 7;
    errno = 0;
    if (fcntl(-1, F_GETPATH, path) != -1 || errno != EBADF) return 8;
#endif
    int flags = fcntl(1, F_GETFL);
    if (flags < 0 || fcntl(1, F_SETFL, flags | O_NONBLOCK) ||
        fcntl(1, F_GETFL) != (flags | O_NONBLOCK) || fcntl(1, F_SETFL, flags) ||
        fcntl(1, F_GETFL) != flags) return 6;
    char name[] = "/tmp/rui-forward-lock.XXXXXX";
    int fd = mkstemp(name);
    if (fd < 0 || unlink(name)) return 9;
    int descriptor_flags = fcntl(fd, F_GETFD);
    if (descriptor_flags < 0 || fcntl(fd, F_SETFD, descriptor_flags | FD_CLOEXEC) ||
        fcntl(fd, F_GETFD) != (descriptor_flags | FD_CLOEXEC) ||
        fcntl(fd, F_SETFD, descriptor_flags) || fcntl(fd, F_GETFD) != descriptor_flags) return 18;
    int duplicate = fcntl(fd, F_DUPFD, 19);
    if (duplicate < 19 || fcntl(duplicate, F_GETFD) != 0 || close(duplicate)) return 19;
#ifdef F_DUPFD_CLOEXEC
    duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 23);
    if (duplicate < 23 || fcntl(duplicate, F_GETFD) != FD_CLOEXEC || close(duplicate)) return 20;
#endif
    errno = 0;
    if (fcntl(-1, F_GETFD) != -1 || errno != EBADF) return 21;
    errno = 0;
    if (fcntl(-1, F_SETFD, FD_CLOEXEC) != -1 || errno != EBADF) return 22;
#ifdef F_FULLFSYNC
    /* Exercise actual local-file durability, with both caller spellings.
       SQLite supplies zero, but the SDK says arg is ignored. */
    if (write(fd, "durable", 7) != 7 || fcntl(fd, F_FULLFSYNC) ||
        fcntl(fd, F_FULLFSYNC, 0)) return 23;
    errno = 0;
    if (fcntl(-1, F_FULLFSYNC) != -1 || errno != EBADF) return 24;
    errno = 0;
    if (fcntl(-1, F_FULLFSYNC, 0) != -1 || errno != EBADF) return 25;
#endif
    struct flock lock = { .l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 3, .l_len = 7 };
    if (fcntl(fd, F_SETLK, &lock)) return 10;
    pid_t child = fork();
    if (child < 0) return 11;
    if (!child) {
        struct flock query = lock;
        if (fcntl(fd, F_GETLK, &query) || query.l_type != F_WRLCK ||
            query.l_start != 3 || query.l_len != 7 || query.l_pid != getppid()) _exit(12);
        errno = 0;
        if (fcntl(fd, F_SETLK, &lock) != -1 || (errno != EACCES && errno != EAGAIN)) _exit(13);
        errno = 0;
        if (fcntl(-1, F_GETLK, &query) != -1 || errno != EBADF) _exit(14);
        _exit(0);
    }
    int status;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status)) return 15;
    if (fcntl(fd, F_SETLKW, &lock)) return 16;
    lock.l_type = F_UNLCK;
    if (fcntl(fd, F_SETLK, &lock) || close(fd)) return 17;
    child = fork();
    if (child < 0) return 26;
    if (!child) {
        /* No guessed va_arg for unknown commands, even without a third arg. */
        fcntl(-1, 2147483647);
        _exit(27);
    }
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status) != 99) return 28;
    struct termios before, changed, after;
    if (tcgetattr(0, &before)) return 1;
    changed = before;
    changed.c_lflag ^= ECHO;
    if (tcsetattr(0, TCSAFLUSH, &changed) || tcgetattr(0, &after) ||
        after.c_lflag != changed.c_lflag) return 2;
    if (tcsetattr(0, TCSAFLUSH, &before) || tcgetattr(0, &after) ||
        after.c_lflag != before.c_lflag) return 3;
    char disable[] = "\033[?2004l";
    struct iovec vector = { disable, sizeof(disable) - 1 };
    if (write(1, disable, sizeof(disable) - 1) != sizeof(disable) - 1) return 5;
    if (writev(1, &vector, 1) != sizeof(disable) - 1 || tcdrain(1)) return 4;
    return 0;
}
"""


def check_forwarding(state, library):
    source, executable, log = state / "forward.c", state / "forward", state / "forward.log"
    source.write_text(FORWARD_DRIVER)
    subprocess.run(["cc", str(source), "-o", str(executable)], check=True)
    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)
    caller = None
    try:
        env = {**os.environ,
            "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
            "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": "forwarding"}
        caller = subprocess.Popen([str(executable)], stdin=slave, stdout=slave,
            stderr=subprocess.PIPE, env=env)
        output = bytearray()
        deadline = time.monotonic() + 5
        while caller.poll() is None or select.select([master], [], [], 0)[0]:
            remaining = deadline - time.monotonic()
            assert remaining > 0, "fixture forwarder did not finish"
            if select.select([master], [], [], min(remaining, 0.05))[0]:
                output.extend(os.read(master, 65536))
                assert len(output) <= 16, output
        result = caller.wait(timeout=5)
        assert result == 0, (result, caller.stderr.read())
        assert output == b"\x1b[?2004l" * 2, output
        assert log.read_text().splitlines() == ["unsupported-fcntl:2147483647",
            "restore-flush", "restore-flush", "disable", "disable", "drain"]
        assert termios.tcgetattr(slave) == original, "fixture forwarder did not restore attributes"
        print("terminal fixture forwarding: write/writev/tcdrain/tcsetattr/fcntl passed", flush=True)
    finally:
        if caller is not None:
            if caller.poll() is None:
                caller.kill()
                caller.wait(timeout=5)
            caller.stderr.close()
        termios.tcflush(slave, termios.TCOFLUSH)
        termios.tcsetattr(slave, termios.TCSAFLUSH, original)
        os.close(master)
        os.close(slave)

    negative_root = state / "forward-contention-negatives"
    negative_root.mkdir(mode=0o700)
    arm, release, log = (negative_root / name for name in ("arm", "release", "probe.log"))
    arm.touch()
    release.touch()
    env = {**os.environ,
        "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
        "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": "diagnostic-contention",
        "RUI_DIAGNOSTIC_ARM": str(arm), "RUI_DIAGNOSTIC_RELEASE": str(release)}
    negative = subprocess.run([str(executable), "contention-negatives"], env=env,
        capture_output=True, timeout=5)
    assert negative.returncode == 0 and negative.stdout == b"", negative
    records = [json.loads(line) for line in negative.stderr.splitlines()]
    assert len(records) == 4 and not negative.stderr.endswith(b"\n"), negative.stderr
    assert [(item["rui_test_phase"], item["subject_kind"], item["subject"]) for item in records] == [
        ("lifecycle_service_observation", "session", "diagnostic/session"),
        ("inspection_captured", "session", "diagnostic/session-extra"),
        ("inspection_captured", "path", "diagnostic/session"),
        ("inspection_captured", "session", "diagnostic/session")], records
    assert "diagnostic-held" not in log.read_text(), "wrong phase, subject or fragment captured native contention"
    release.unlink()
    positive_root = state / "forward-contention-positive"
    positive_root.mkdir(mode=0o700)
    log = positive_root / "probe.log"
    env["RUI_TERMINAL_PROBE"] = str(log)
    caller = subprocess.Popen([str(executable), "contention-positive"], env=env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        fixture.wait_for(lambda: log.exists() and "diagnostic-held-inspection\n" in log.read_text(),
            "exact native inspection write held", timeout=5)
        assert caller.poll() is None, "selected native write did not retain custody"
        release.touch()
        out, err = caller.communicate(timeout=5)
        assert caller.returncode == 0 and out == b"", (out, err)
        record = json.loads(err)
        assert record == {"rui_test_phase": "inspection_captured", "subject_kind": "session",
            "subject": "diagnostic/session", "process": "driver", "run": "37", "sequence": "1"}, record
        assert log.read_text().count("diagnostic-held-inspection\n") == 1
        assert "diagnostic-restored\n" in log.read_text()
        print("terminal fixture contention: wrong phase/Session/kind/fragment forwarded; exact write held, released and flags restored", flush=True)
    finally:
        release.touch()
        if caller.poll() is None:
            caller.kill()
            caller.wait(timeout=5)
        caller.stdout.close()
        caller.stderr.close()


def persistent_cases(state, library, home, store, host):
    """Real synchronous capture custody and actual nonblocking output credit."""
    records = home / ".config/rui/requests"
    records.mkdir(mode=0o700, parents=True, exist_ok=True)
    for case in ("sync-exit", "sync-handoff", "sync-command-int", "sync-command-term",
                 "admission-interrupt", "backpressure", "backpressure-command", "disable", "restore", "both",
                 "incomplete-disable", "incomplete-restore", "incomplete-both"):
        master, slave = pty.openpty()
        output_master, output_slave = pty.openpty()
        original = termios.tcgetattr(slave)
        log, release = state / f"persistent-{case}.log", state / f"persistent-{case}.release"
        caller = proxy = None
        reply_release = threading.Event()
        before = set(records.glob("*.json"))
        try:
            fault = "backpressure" if case.startswith("backpressure") else case.removeprefix("incomplete-")
            environment = {**os.environ, "HOME": str(home),
                "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
                "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": fault}
            if case.startswith("sync-"):
                environment["RUI_CAPTURE_SYNC_RELEASE"] = str(release)
                if case == "sync-handoff":
                    environment["RUI_CAPTURE_SYNC_ERROR"] = "1"
            caller = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
                "--session", "terminal/restoration"], env=environment,
                stdin=slave, stdout=output_slave, stderr=subprocess.PIPE)
            human.read_terminal(output_master, "› ")
            if case.startswith("sync-"):
                os.write(master, b"original synchronously captured\n")
                fixture.wait_for(lambda: log.exists() and "capture-sync-held" in log.read_text(), "real capture directory sync")
                record, = set(records.glob("*.json")) - before
                saved = record.read_bytes()
                key = json.loads(saved)["key"]
                assert fixture.command("observe-command", "--store", store, "--key", key)["observation"]["status"] == "absent"
                if case == "sync-handoff":
                    os.write(master, b"/inspect-action\nSTALE")
                elif case.startswith("sync-command-"):
                    os.write(master, b"/configure --permission-mode ask\n")
                else:
                    os.write(master, b"/exit\nSTALE")
                fixture.wait_for(lambda: termios.tcgetattr(slave)[3] & termios.ICANON, "restoration before synchronous capture join")
                assert caller.poll() is None, "synchronous capture was reported reaped before its gate released"
                if case.startswith("sync-command-"):
                    caller.send_signal(signal.SIGINT if case.endswith("-int") else signal.SIGTERM)
                release.touch()
                if case == "sync-handoff":
                    resumed = human.read_terminal(output_master, "Not confirmed")
                    if "› " not in resumed.split("Not confirmed", 1)[1]:
                        resumed += human.read_terminal(output_master, "› ")
                    assert "STALE" not in resumed, resumed
                    assert "No actionable permission" in resumed, resumed
                    os.write(master, "next café!\x1b[D\x1b[DX".encode())
                    human.read_terminal(output_master, "› next cafXé!")
                    os.write(master, b"\x12")
                    human.read_terminal(output_master, "\n› original synchronously captured")
                    assert record.read_bytes() == saved, "postpublication recovery replaced original record"
                    os.write(master, b"Y\n")
                    human.read_terminal(output_master, "\n› next cafXYé!")
                    os.write(master, b"\x03")
                elif not case.startswith("sync-command-"):
                    # The finished prompt's suffix must not reach the next owner.
                    os.write(master, b"\n")
                    assert select.select([slave], [], [], 5)[0]
                    assert os.read(slave, 4096) == b"\n", "persistent detach leaked queued typeahead"
                    # Canonical ECHO is restored on this separate input PTY.
                    # Darwin's drain-based fixture cleanup waits for its peer;
                    # consume the probe's echo, not only its accepted input.
                    assert select.select([master], [], [], 5)[0]
                    assert os.read(master, 4096) == b"\r\n", "canonical probe echo was not consumed"
            elif case == "admission-interrupt":
                received = threading.Event()
                def hold(response):
                    received.set()
                    assert reply_release.wait(15)
                    return b""  # Caller is already reaped; no delivery to its closed socket.
                proxy = canonical.ReplyProxy(host, "/v1/message", hold)
                os.write(master, b"held real Admission\n")
                assert received.wait(10)
                caller.send_signal(signal.SIGINT)
            elif case.startswith("backpressure"):
                # An external caller admits large exact content after opening;
                # the frontend's actual activity reader fills stdout's PTY.
                human.run(home, "message", "--store", store, "--session", "terminal/restoration", "z" * 50000)
                fixture.wait_for(lambda: log.exists() and "output-blocked" in log.read_text(), "actual terminal EAGAIN")
                os.write(master, b"/configure --permission-mode ask\n" if case == "backpressure-command" else b"\x03")
            elif case.startswith("incomplete-"):
                os.write(master, b"\xc3")
            else:
                os.write(master, b"\x03")
            expected = 1 if fault in ("backpressure", "disable", "restore", "both") else 0
            assert caller.wait(timeout=5) == expected, caller.stderr.read()
            errors = caller.stderr.read().decode()
            if expected:
                assert ("TerminalRestoreFailed" if fault in ("restore", "both") else "TerminalCleanupFailed") in errors, errors
            if case.startswith("incomplete-"):
                assert set(records.glob("*.json")) == before, "incomplete input created a capture"
            if case == "backpressure-command":
                assert all(json.loads(record.read_bytes())["kind"] == "message"
                    for record in set(records.glob("*.json")) - before), "failed cleanup captured pending configuration"
                assert fixture.command("inspect-session", "--store", store,
                    "--session", "terminal/restoration")["session"]["permission_mode"] == "bypass", "failed cleanup executed pending configuration"
            if case.startswith("sync-command-"):
                assert set(records.glob("*.json")) - before == {record}, "interrupt during join captured a pending configuration"
                assert record.read_bytes() == saved, "interrupt replaced original capture"
                assert fixture.command("inspect-session", "--store", store,
                    "--session", "terminal/restoration")["session"]["permission_mode"] == "bypass", "interrupt during join executed pending configuration"
            if fault not in ("restore", "both"):
                actual = termios.tcgetattr(slave)
                if sys.platform == "darwin":
                    mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                    actual[3] &= ~mask
                    original[3] &= ~mask
                assert actual == original, (case, actual, original)
            if case == "admission-interrupt":
                assert not reply_release.is_set(), "borrower cleanup needed the Host reply"
                body, = [body for body, _ in proxy.exchanges]
                request = json.loads(body)
                assert (records / f"{request['key']}.json").read_bytes() == body
                assert f"Message not confirmed. Use rui recover {request['key']}" in errors, errors
            reply_release.set()
            if proxy is not None:
                proxy.close()
                proxy = None
            # Detachment never cancels or restarts the actual owning Host.
            answer = human.admit(home, "message", "--store", store, "--session", "terminal/restoration", f"valid after {case}")
            assert answer["admission"]["answer"]["status"] == "accepted", answer
            print(f"persistent terminal: {case} passed", flush=True)
        finally:
            release.touch()
            reply_release.set()
            if caller is not None and caller.poll() is None:
                caller.kill()
                caller.wait(timeout=5)
            if proxy is not None:
                proxy.close()
            termios.tcflush(output_slave, termios.TCOFLUSH)
            termios.tcsetattr(slave, termios.TCSAFLUSH, original)
            for fd in (master, slave, output_master, output_slave):
                os.close(fd)


def consent_boundary_cases(state, library):
    """Input arriving during final presentation cannot consent or lose Ctrl-C."""
    for case in ("cancel", "paste"):
        root = state / f"consent-{case}"
        root.mkdir()
        home, store = root / "home", root / "store"
        home.mkdir(mode=0o700)
        endpoint = fixture.SuccessEndpoint([
            fixture.sse_tool_calls("consent-call", [("bash", "consent-id",
                json.dumps({"cmd": "printf forbidden > effect", "timeout_ms": None}))]),
            fixture.sse_answer("consent-answer", "consent-reason", "consent-message", "Denied.")[0],
        ])
        thread = threading.Thread(target=endpoint.serve_forever)
        thread.start()
        host = caller = None
        master, slave = pty.openpty()
        original = termios.tcgetattr(slave)
        read_ready, write_ready = os.pipe()
        release, drain, log = root / "choice.release", root / "drain.release", root / "probe.log"
        try:
            host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
            human.run(home, "configure", "--store", store, "--session", "consent/boundary",
                "--workspace", root, "--provider", "codex", "--model", "model-a", "--permission-mode", "ask")
            caller = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
                "--session", "consent/boundary"], stdin=slave, stdout=slave, stderr=subprocess.PIPE,
                env={**os.environ, "HOME": str(home), "NO_COLOR": "1",
                    "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
                    "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": f"consent-{case}",
                    "RUI_TERMINAL_CHOICE_RELEASE": str(release), "RUI_TERMINAL_DRAIN_RELEASE": str(drain),
                    "RUI_TEST_ACTION_READY_FD": str(write_ready)}, pass_fds=(write_ready,))
            human.read_terminal(master, "› ")
            os.write(master, b"propose command\n")
            presentation = human.read_terminal(master, "a: Allow once / d: Deny (Enter)")
            assert "Time limit: Host default" in presentation, presentation
            fixture.wait_for(lambda: log.exists() and "choice-output-complete" in log.read_text(), "final choice write")
            records = home / ".config/rui/requests"
            before = set(records.glob("*.json"))
            os.write(master, b"\x03" if case == "cancel" else b"\x1b[200~")
            release.touch()
            if case == "cancel":
                fixture.wait_for(lambda: termios.tcgetattr(slave)[3] & termios.ICANON,
                    "restoration without releasing consent drain", timeout=3)
                assert not drain.exists(), "fixture released the drain"
                assert not select.select([read_ready], [], [], 0)[0], "cancelled choice became ready"
            else:
                assert not select.select([read_ready], [], [], 0.2)[0], "paste prefix opened consent"
                os.write(master, b"a\n")
                assert not select.select([read_ready], [], [], 0.2)[0], "unfinished paste authorized"
                assert set(records.glob("*.json")) == before
                os.write(master, b"\x1b[201~")
                human.action_ready(read_ready)
                os.write(master, b"d\n")
                human.read_terminal(master, "Permission denied.")
                os.write(master, b"\x03")
            output, errors = human.terminal_exit(caller, master)
            assert caller.wait(timeout=5) == 0, (output, errors)
            actual = termios.tcgetattr(slave)
            if sys.platform == "darwin":
                mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                actual[3] &= ~mask
                original[3] &= ~mask
            assert actual == original
            assert not (root / "effect").exists(), "pre-boundary input ran Bash"
            if case == "cancel":
                assert set(records.glob("*.json")) == before, "cancel captured permission"
            print(f"persistent consent boundary: {case} passed", flush=True)
        finally:
            release.touch()
            drain.touch()
            if caller is not None and caller.poll() is None:
                caller.kill()
                caller.wait(timeout=5)
            if host is not None:
                fixture.stop_host(host)
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)
            termios.tcflush(slave, termios.TCOFLUSH)
            termios.tcsetattr(slave, termios.TCSAFLUSH, original)
            for fd in (master, slave, read_ready, write_ready):
                os.close(fd)


def fatal_reporting_cases(state):
    """Optional fatal text cannot hold exit or name a superseded original."""
    root = state / "fatal-reporting"
    root.mkdir()
    home, store = root / "home", root / "store"
    home.mkdir(mode=0o700)
    endpoint = fixture.SuccessEndpoint([
        fixture.sse_answer("fatal-a", "fatal-ar", "fatal-am", "ACCEPTED-A")[0],
        fixture.sse_answer("fatal-b", "fatal-br", "fatal-bm", "COMMITTED-B")[0],
    ])
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = caller = proxy = None
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        human.run(home, "configure", "--store", store, "--session", "fatal/original",
            "--workspace", root, "--provider", "codex", "--model", "model-a")
        diagnostics = [
            (["resume", "--store", str(store), "missing/fatal"], b"SessionNotConfigured"),
            (["setup", "--provider", "unsupported"], b"UnsupportedPreferenceProvider"),
            (["--store", str(store), "--provider", "unsupported", "--model", "model-a"], b"UnsupportedSelectionProvider"),
        ]
        for args, error, stopped in ((args, error, stopped) for args, error in diagnostics for stopped in (False, True)):
            master, slave = pty.openpty()
            error_master, error_slave = pty.openpty()
            original = termios.tcgetattr(slave)
            error_flags = fcntl.fcntl(error_slave, fcntl.F_GETFL)
            try:
                if stopped:
                    termios.tcflow(error_slave, termios.TCOOFF)
                caller = subprocess.Popen([str(fixture.RUI), *args],
                    env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave, stderr=error_slave)
                assert caller.wait(timeout=3) == 1, "fatal diagnostic did not exit"
                assert termios.tcgetattr(slave) == original
                assert_file_flags(fcntl.fcntl(error_slave, fcntl.F_GETFL), error_flags)
                if not stopped:
                    assert select.select([error_master], [], [], 1)[0]
                    assert error in os.read(error_master, 65536)
                print(f"fatal reporting: {error.decode()} stopped stderr={stopped} passed", flush=True)
            finally:
                if caller is not None and caller.poll() is None:
                    caller.kill()
                    caller.wait(timeout=5)
                termios.tcflow(error_slave, termios.TCOON)
                for fd in (master, slave, error_master, error_slave):
                    os.close(fd)
        # Popen restores default SIGPIPE before exec. Rui's initialized IO
        # runtime must still preserve the real error when stderr disconnects.
        for args, error in diagnostics:
            master, slave = pty.openpty()
            read_error, write_error = os.pipe()
            os.close(read_error)
            original = termios.tcgetattr(slave)
            error_flags = fcntl.fcntl(write_error, fcntl.F_GETFL)
            try:
                caller = subprocess.Popen([str(fixture.RUI), *args],
                    env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave, stderr=write_error)
                assert caller.wait(timeout=3) == 1, "disconnected stderr replaced the real exit"
                assert termios.tcgetattr(slave) == original
                assert_file_flags(fcntl.fcntl(write_error, fcntl.F_GETFL), error_flags)
                print(f"fatal reporting: {error.decode()} disconnected stderr passed", flush=True)
            finally:
                if caller is not None and caller.poll() is None:
                    caller.kill()
                    caller.wait(timeout=5)
                for fd in (master, slave, write_error):
                    os.close(fd)
        master, slave = pty.openpty()
        original = termios.tcgetattr(slave)
        try:
            caller = subprocess.Popen([str(fixture.RUI), "resume", "--store", str(store), "fatal/original"],
                env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            human.read_terminal(master, "› ")
            proxy = canonical.ReplyProxy(host, "/v1/message",
                lambda response: b"" if len(proxy.exchanges) == 2 else response)
            records = home / ".config/rui/requests"
            before = {path: path.read_bytes() for path in records.glob("*.json")}
            os.write(master, b"accepted A\n")
            human.read_terminal(master, "ACCEPTED-A", composer=True)
            human.terminal_step(master, "/status")
            os.write(master, b"uncertain B\n")
            human.read_terminal(master, "Not confirmed")
            first, second = [json.loads(body) for body, _ in proxy.exchanges]
            saved = (home / ".config/rui/requests" / f"{second['key']}.json").read_bytes()
            os.write(master, b"\x1b[")
            output, errors = human.terminal_exit(caller, master, timeout=6)
            assert caller.returncode == 1, (output, errors)
            assert second["key"].encode() in errors and first["key"].encode() not in errors, errors
            assert b"not confirmed" in errors and b"rui recover" in errors and b"IncompleteTerminalInput" in errors, errors
            assert len(proxy.exchanges) == 2 and proxy.exchanges[1][0] == saved, "fatal exit replaced original"
            assert proxy.mutations == [("/v1/message", body) for body, _ in proxy.exchanges]
            after = {path: path.read_bytes() for path in records.glob("*.json")}
            assert set(after) - set(before) == {records / f"{request['key']}.json" for request in (first, second)}
            assert after == {**before, **{records / f"{json.loads(body)['key']}.json": body for body, _ in proxy.exchanges}}
            actual = termios.tcgetattr(slave)
            if sys.platform == "darwin":
                mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                actual[3] &= ~mask
                original[3] &= ~mask
            assert actual == original
            print("fatal reporting: current unconfirmed original passed", flush=True)
        finally:
            if caller is not None and caller.poll() is None:
                caller.kill()
                caller.wait(timeout=5)
            os.close(master)
            os.close(slave)
        master, slave = pty.openpty()
        read_error, write_error = os.pipe()
        os.close(read_error)
        original = termios.tcgetattr(slave)
        error_flags = fcntl.fcntl(write_error, fcntl.F_GETFL)
        records_before = {path: path.read_bytes() for path in records.glob("*.json")}
        try:
            caller = subprocess.Popen([str(fixture.RUI), "resume", "--store", str(store), "fatal/original"],
                env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave, stderr=write_error)
            human.read_terminal(master, "› ", composer=True)
            os.write(master, b"\x1b[")
            assert caller.wait(timeout=6) == 1, "disconnected stderr bypassed acquired-terminal cleanup"
            actual = termios.tcgetattr(slave)
            if sys.platform == "darwin":
                mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                actual[3] &= ~mask
                original[3] &= ~mask
            assert actual == original
            assert_file_flags(fcntl.fcntl(write_error, fcntl.F_GETFL), error_flags)
            assert {path: path.read_bytes() for path in records.glob("*.json")} == records_before
            assert fixture.command("inspect-session", "--store", store, "--session", "fatal/original")["session"]
            print("fatal reporting: acquired terminal disconnected stderr passed", flush=True)
        finally:
            if caller is not None and caller.poll() is None:
                caller.kill()
                caller.wait(timeout=5)
            for fd in (master, slave, write_error):
                os.close(fd)
    finally:
        if proxy is not None:
            proxy.close()
        if host is not None:
            fixture.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)


def decision_reporting_cases(state):
    """Both accepted and interrupted choices retain the exact decision identity."""
    root = state / "decision-reporting"
    root.mkdir()
    home, store = root / "home", root / "store"
    home.mkdir(mode=0o700)
    cases = [(decision, lost) for decision in ("allow_once", "deny") for lost in (False, True)]
    responses = []
    for decision, lost in cases:
        name = f"{decision}-{lost}"
        responses.extend([
            fixture.sse_tool_calls(name, [("bash", name, json.dumps({"cmd": f"printf once >> effect-{name}", "timeout_ms": 1000}))]),
            fixture.sse_answer(f"{name}-a", f"{name}-r", f"{name}-m", f"SETTLED-{name}")[0],
        ])
    endpoint = fixture.SuccessEndpoint(responses)
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = caller = proxy = None
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        for decision, lost in cases:
            name = f"{decision}-{lost}"
            session = f"reporting/{name}"
            human.run(home, "configure", "--store", store, "--session", session,
                "--workspace", root, "--provider", "codex", "--model", "model-a", "--permission-mode", "ask")
            before = {path: path.read_bytes() for path in (home / ".config/rui/requests").glob("*.json")}
            master, slave = pty.openpty()
            read_ready, write_ready = os.pipe()
            original = termios.tcgetattr(slave)
            reply_release, received = threading.Event(), threading.Event()
            try:
                caller = subprocess.Popen([str(fixture.RUI), "resume", "--store", str(store), session],
                    env={**os.environ, "HOME": str(home), "RUI_TEST_ACTION_READY_FD": str(write_ready)},
                    pass_fds=(write_ready,), stdin=slave, stdout=slave, stderr=subprocess.PIPE)
                human.read_terminal(master, "› ")
                if lost:
                    def hold(response):
                        received.set()
                        assert reply_release.wait(15)
                        return b""
                    proxy = canonical.ReplyProxy(host, "/v1/control/permission-decision", hold)
                else:
                    proxy = canonical.ReplyProxy(host, "/v1/control/permission-decision", lambda response: response)
                os.write(master, b"propose exact decision\n")
                human.read_terminal(master, "a: Allow once / d: Deny (Enter)")
                human.action_ready(read_ready)
                os.write(master, b"a\n" if decision == "allow_once" else b"d\n")
                if lost:
                    assert received.wait(10)
                    caller.send_signal(signal.SIGINT)
                else:
                    human.read_terminal(master, f"SETTLED-{name}", composer=True)
                    status = human.terminal_step(master, "/status")
                    assert "Original reserved request:" not in status, status
                    os.write(master, b"\x1b[")
                output, errors = human.terminal_exit(caller, master, timeout=6)
                assert caller.returncode == (0 if lost else 1), (output, errors)
                records = [path for path in (home / ".config/rui/requests").glob("*.json")
                    if json.loads(path.read_bytes()).get("session") == session]
                record, = [path for path in records if json.loads(path.read_bytes())["kind"] == "permission_decision"]
                saved = record.read_bytes()
                request = json.loads(saved)
                message_record, = [path for path in records if json.loads(path.read_bytes())["kind"] == "message"]
                message_bytes = message_record.read_bytes()
                message = json.loads(message_bytes)
                after = {path: path.read_bytes() for path in (home / ".config/rui/requests").glob("*.json")}
                assert set(after) - set(before) == {record, message_record}
                assert after == {**before, record: saved, message_record: message_bytes}
                assert proxy.mutations == [("/v1/message", message_bytes), ("/v1/control/permission-decision", saved)]
                assert len(proxy.exchanges) == 1 and proxy.exchanges[0][0] == saved
                assert request["key"].encode() in errors and message["key"].encode() not in errors, errors
                assert request["decision"] == decision
                assert b"rui recover " + request["key"].encode() in errors and b"rui result" not in errors, errors
                assert (b"Decision not confirmed" if lost else b"Decision accepted; do not repeat it") in errors, errors
                if not lost:
                    assert b"IncompleteTerminalInput" in errors and b"not confirmed" not in errors, errors
                if lost:
                    assert proxy.exchanges[0][0] == saved and not reply_release.is_set()
                    reply_release.set()
                proxy.close()
                proxy = None
                recovered = json.loads(human.run(home, "recover", request["key"], "--json"))["answer"]
                assert recovered["status"] == "accepted" and recovered["replayed"] is True, recovered
                assert record.read_bytes() == saved
                fixture.wait_for(lambda: fixture.completed_observation(store, message["key"]), "decision continuation")
                effect = root / f"effect-{name}"
                assert (effect.read_bytes() if effect.exists() else b"") == (b"once" if decision == "allow_once" else b"")
                actual = termios.tcgetattr(slave)
                if sys.platform == "darwin":
                    mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                    actual[3] &= ~mask
                    original[3] &= ~mask
                assert actual == original
                print(f"decision reporting: {name} passed", flush=True)
            finally:
                reply_release.set()
                if caller is not None and caller.poll() is None:
                    caller.kill()
                    caller.wait(timeout=5)
                if proxy is not None:
                    proxy.close()
                    proxy = None
                for fd in (master, slave, read_ready, write_ready):
                    os.close(fd)
    finally:
        if host is not None:
            fixture.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)


def detach_reporting_cases(state, library):
    """A post-restoration notice error cannot erase an accepted intent."""
    root = state / "detach-reporting"
    root.mkdir()
    home, store = root / "home", root / "store"
    home.mkdir(mode=0o700)
    cases = [(kind, fault) for kind in ("message", "allow_once", "deny") for fault in ("detach-enable", "detach-reset")]
    responses = []
    for kind, fault in cases:
        name = f"{kind}-{fault}"
        if kind != "message":
            responses.append(fixture.sse_tool_calls(name, [("bash", name, json.dumps({"cmd": f"printf once >> effect-{name}", "timeout_ms": 1000}))]))
        responses.append(fixture.sse_answer(f"{name}-a", f"{name}-r", f"{name}-m", f"SETTLED-{name}")[0])
    endpoint = fixture.SuccessEndpoint(responses)
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = caller = proxy = None
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        for kind, fault in cases:
            name = f"{kind}-{fault}"
            session = f"detach/{name}"
            human.run(home, "configure", "--store", store, "--session", session,
                "--workspace", root, "--provider", "codex", "--model", "model-a", "--permission-mode", "ask")
            master, slave = pty.openpty()
            read_ready, write_ready = os.pipe()
            original, flags = termios.tcgetattr(slave), fcntl.fcntl(slave, fcntl.F_GETFL)
            log, arm = root / f"{name}.log", root / f"{name}.arm"
            try:
                caller = subprocess.Popen([str(fixture.RUI), "resume", "--store", str(store), session],
                    env={**os.environ, "HOME": str(home), "RUI_TEST_ACTION_READY_FD": str(write_ready),
                        "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
                        "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": fault, "RUI_TERMINAL_DETACH_ARM": str(arm)},
                    pass_fds=(write_ready,), stdin=slave, stdout=slave, stderr=subprocess.PIPE)
                human.read_terminal(master, "› ")
                proxy = canonical.ReplyProxy(host, "/v1/message", lambda response: response)
                os.write(master, b"accepted original\n")
                if kind != "message":
                    human.read_terminal(master, "a: Allow once / d: Deny (Enter)")
                    human.action_ready(read_ready)
                    os.write(master, b"a\n" if kind == "allow_once" else b"d\n")
                human.read_terminal(master, f"SETTLED-{name}", composer=True)
                status = human.terminal_step(master, "/status")
                assert "Original reserved request:" not in status, status
                before = {path: path.read_bytes() for path in (home / ".config/rui/requests").glob("*.json")}
                records = [path for path in before if json.loads(before[path]).get("session") == session]
                intent_kind = "message" if kind == "message" else "permission_decision"
                record, = [path for path in records if json.loads(before[path])["kind"] == intent_kind]
                request = json.loads(before[record])
                arm.touch()
                os.write(master, b"\x03")
                output, errors = human.terminal_exit(caller, master)
                assert caller.returncode == 1 and b"TerminalCleanupFailed" in errors, (output, errors)
                guide = b"Message accepted; do not resubmit it" if kind == "message" else b"Decision accepted; do not repeat it"
                assert guide in errors and request["key"].encode() in errors, errors
                assert (b"rui result " if kind == "message" else b"rui recover ") + request["key"].encode() in errors
                assert "cleanup-flags-restored\ndetach-enable\n" in log.read_text(), log.read_text()
                assert log.read_text().count(fault + "\n") == 1
                actual = termios.tcgetattr(slave)
                if sys.platform == "darwin":
                    mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                    actual[3] &= ~mask
                    original[3] &= ~mask
                assert actual == original
                assert_file_flags(fcntl.fcntl(slave, fcntl.F_GETFL), flags if fault == "detach-enable" else flags | os.O_NONBLOCK)
                assert {path: path.read_bytes() for path in (home / ".config/rui/requests").glob("*.json")} == before
                messages = [before[path] for path in records if json.loads(before[path])["kind"] == "message"]
                assert proxy.mutations == [("/v1/message", messages[0])] + ([] if kind == "message" else [("/v1/control/permission-decision", before[record])])
                proxy.close()
                proxy = None
                assert json.loads(human.run(home, "recover", request["key"], "--json"))["answer"]["replayed"] is True
                effect = root / f"effect-{name}"
                assert (effect.read_bytes() if effect.exists() else b"") == (b"once" if kind == "allow_once" else b"")
                print(f"detach reporting: {name} exact accepted guide, restored termios and saved replay passed", flush=True)
            finally:
                if caller is not None and caller.poll() is None:
                    caller.kill()
                    caller.wait(timeout=5)
                if proxy is not None:
                    proxy.close()
                    proxy = None
                for fd in (master, slave, read_ready, write_ready):
                    os.close(fd)
    finally:
        if host is not None:
            fixture.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)


def startup_reporting_cases(state, library):
    """Initial launch is definitely unsent; failed retry retains uncertainty."""
    for kind in ("message", "allow_once", "deny", "message-restore", "retry"):
        root = state / f"startup-{kind}"
        root.mkdir()
        home, store = root / "home", root / "store"
        home.mkdir(mode=0o700)
        responses = [fixture.sse_answer("seed", "seed-r", "seed-m", "SEED-ACCEPTED")[0]]
        if kind in ("allow_once", "deny"):
            responses.append(fixture.sse_tool_calls("choice", [("bash", "choice-call", json.dumps({"cmd": "touch must-not-run", "timeout_ms": 1000}))]))
        elif kind == "retry":
            responses.append(fixture.sse_answer("retry", "retry-r", "retry-m", "ORIGINAL-ACCEPTED")[0])
        endpoint = fixture.SuccessEndpoint(responses)
        thread = threading.Thread(target=endpoint.serve_forever)
        thread.start()
        host = caller = proxy = None
        held, release = threading.Event(), threading.Event()
        master, slave = pty.openpty()
        ready_read, ready_write = os.pipe()
        original = termios.tcgetattr(slave)
        arm, log = root / "arm", root / "probe.log"
        try:
            host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
            human.run(home, "configure", "--store", store, "--session", "startup/case",
                "--workspace", root, "--provider", "codex", "--model", "model-a", "--permission-mode", "ask")
            caller = subprocess.Popen([str(fixture.RUI), "resume", "--store", str(store), "startup/case"],
                env={**os.environ, "HOME": str(home), "RUI_TEST_ACTION_READY_FD": str(ready_write),
                    "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
                    "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": "startup-restore" if kind == "message-restore" else "startup",
                    "RUI_TERMINAL_STARTUP_ARM": str(arm)},
                pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            human.read_terminal(master, "› ")
            os.write(master, b"seed accepted original\n")
            human.read_terminal(master, "SEED-ACCEPTED", composer=True)
            assert "Original reserved request:" not in human.terminal_step(master, "/status")
            if kind in ("allow_once", "deny"):
                os.write(master, b"propose exact Action\n")
                human.read_terminal(master, "a: Allow once / d: Deny (Enter)")
                human.action_ready(ready_read)
                proxy = canonical.ReplyProxy(host, "/v1/control/permission-decision", lambda response: response)
                event = b"a\n" if kind == "allow_once" else b"d\n"
            else:
                if kind == "retry":
                    proxy = canonical.ReplyProxy(host, "/v1/message", lambda response: b"")
                    os.write(master, b"retry this exact original\n")
                    human.read_terminal(master, "Not confirmed")
                def hold(response):
                    held.set()
                    assert release.wait(15), "startup observation not released"
                    return response
                if proxy is None:
                    proxy = canonical.ReplyProxy(host, "/v1/inspect-session", hold)
                else:
                    proxy.route, proxy.rewrite = "/v1/inspect-session", hold
                human.terminal_gate(caller, master, held, "startup borrower held")
                event = b"\x12" if kind == "retry" else "definitely unsent café!\n".encode()
            records = home / ".config/rui/requests"
            before = {path: path.read_bytes() for path in records.glob("*.json")}
            mutations = list(proxy.mutations)
            arm.touch()
            os.write(master, event)
            output, errors = human.terminal_exit(caller, master)
            assert caller.returncode == 1, (output, errors)
            assert (b"TerminalRestoreFailed" if kind == "message-restore" else b"SystemResources") in errors, errors
            assert log.read_text().count("worker-not-started\n") == 1, log.read_text()
            if kind == "retry":
                request, = [json.loads(body) for body in before.values()
                    if json.loads(body).get("text", {}).get("value") == "retry this exact original"]
                assert b"Message not confirmed" in errors and request["key"].encode() in errors
                assert b"was not sent" not in errors
            else:
                intent = b"Decision" if kind in ("allow_once", "deny") else b"Message"
                assert intent + b" was not sent" in errors and b"You may submit it again" in errors, errors
                assert b"rui recover " not in errors and b"rui result " not in errors and b"reserved key" not in errors, errors
            assert {path: path.read_bytes() for path in records.glob("*.json")} == before
            assert proxy.mutations == mutations and not (root / "must-not-run").exists()
            actual = termios.tcgetattr(slave)
            if sys.platform == "darwin":
                mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                actual[3] &= ~mask
                original[3] &= ~mask
            if kind == "message-restore":
                assert not actual[3] & termios.ICANON
            else:
                assert actual == original
            release.set()
            proxy.close()
            proxy = None
            if kind == "retry":
                assert json.loads(human.run(home, "recover", request["key"], "--json"))["answer"]["replayed"] is True
            print(f"startup reporting: {kind} exact custody, publication/mutation conservation and cleanup precedence passed", flush=True)
        finally:
            release.set()
            if caller is not None and caller.poll() is None:
                caller.kill()
                caller.wait(timeout=5)
            if proxy is not None:
                proxy.close()
            termios.tcsetattr(slave, termios.TCSANOW, original)
            for fd in (master, slave, ready_read, ready_write):
                os.close(fd)
            if host is not None:
                fixture.stop_host(host)
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)


def visible_stream_handoff_cases(state, library):
    """A cancelled visible stream retires, rather than replaying its prefix."""
    marker = "VISIBLE-CANCEL-PREFIX"
    long = marker + "\n" + "complete saved content\n" * 240 + "VISIBLE-END"
    for phase in ("opening", "activity", "permission", "history", "details"):
        root = state / f"visible-{phase}"
        root.mkdir()
        home, store = root / "home", root / "store"
        home.mkdir(mode=0o700)
        text = json.dumps({"cmd": "echo " + marker + " # " + "x" * 6000, "timeout_ms": 1000})
        responses = [fixture.sse_tool_calls("visible", [("bash", "visible-call", text)])] if phase == "permission" else [
            fixture.sse_answer("visible", "visible-r", "visible-m", long)[0]]
        if phase == "history":
            responses += [fixture.sse_answer(f"short-{i}", f"short-{i}-r", f"short-{i}-m", "OPENING-READY")[0] for i in range(8)]
        endpoint = fixture.SuccessEndpoint(responses)
        thread = threading.Thread(target=endpoint.serve_forever)
        thread.start()
        host = caller = None
        master, slave = pty.openpty()
        original = termios.tcgetattr(slave)
        flags = fcntl.fcntl(slave, fcntl.F_GETFL)
        arm, log = root / "arm", root / "probe.log"
        try:
            host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
            human.run(home, "configure", "--store", store, "--session", "visible/stream",
                "--workspace", root, "--provider", "codex", "--model", "model-a", "--permission-mode", "ask")
            if phase not in ("activity", "permission"):
                for i in range(len(responses)):
                    admission = human.admit(home, "message", "--store", store, "--session", "visible/stream", f"saved input {i}")
                    fixture.wait_for(lambda: fixture.completed_observation(store, admission["request"]), "saved stream content")
            if phase == "opening": arm.touch()
            caller = subprocess.Popen([str(fixture.RUI), "resume", "--store", str(store), "visible/stream"],
                env={**os.environ, "HOME": str(home), "NO_COLOR": "1",
                    "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
                    "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": "visible-stream", "RUI_TERMINAL_STREAM_ARM": str(arm)},
                stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            if phase != "opening":
                ready = "VISIBLE-END" if phase == "details" else "OPENING-READY" if phase == "history" else "› "
                opening = human.read_terminal(master, ready)
                if ready != "› " and "› " not in opening.split(ready, 1)[1]: human.read_terminal(master, "› ")
                arm.touch()
                os.write(master, (f"/{phase}\n" if phase in ("history", "details") else "produce content\n").encode())
            prefix = human.read_terminal(master, marker)
            fixture.wait_for(lambda: log.exists() and "visible-stream-held" in log.read_text(), "post-prefix output gate")
            before = {path: path.read_bytes() for path in (home / ".config/rui/requests").glob("*.json")}
            command = b"/inspect-action\n" if phase == "permission" else b"/status\n"
            os.write(master, command)
            tail, errors = human.terminal_exit(caller, master)
            assert caller.returncode != 0 and b"Cancelled" in errors, (phase, tail, errors)
            assert errors.startswith(b"\n"), "fatal diagnostics merged into incomplete transcript"
            assert b"Session: visible/stream" not in tail and b"Action:" not in tail, "cancelled stream dispatched command"
            assert marker not in tail.decode() and b"Detached." not in tail, "cancelled stream replayed or resumed"
            assert (prefix.encode() + tail).count(marker.encode()) == 1
            actual = termios.tcgetattr(slave)
            if sys.platform == "darwin":
                mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                actual[3] &= ~mask
                original[3] &= ~mask
            assert actual == original
            assert_file_flags(fcntl.fcntl(slave, fcntl.F_GETFL), flags)
            assert {path: path.read_bytes() for path in (home / ".config/rui/requests").glob("*.json")} == before
            assert "restore-other" in log.read_text() and "disable" in log.read_text()
            assert len(endpoint.requests) == len(responses), "command cancellation restarted Host work"
            print(f"visible {phase}: command cancellation restores/joins and retires without dispatch or prefix replay", flush=True)
        finally:
            if caller is not None and caller.poll() is None:
                caller.kill()
                caller.wait(timeout=5)
            if caller is not None: caller.stderr.close()
            termios.tcsetattr(slave, termios.TCSANOW, original)
            os.close(master)
            os.close(slave)
            if host is not None: fixture.stop_host(host)
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)
            assert not thread.is_alive()


def host_diagnostic_cases(state, library):
    """Optional fd2 credit cannot own canonical progress or cleanup authority."""
    root = state / "readiness-alias-poison"
    root.mkdir(mode=0o700)
    store, log, arm = (root / name for name in ("store", "probe.log", "arm"))
    store.mkdir(mode=0o700)
    (store / "diagnostics").mkdir(mode=0o755)
    (store / "diagnostics").chmod(0o755)
    arm.touch()
    read_fd, write_fd = os.pipe()
    flags = fcntl.fcntl(write_fd, fcntl.F_GETFL)
    host = None
    output = bytearray()
    try:
        fcntl.fcntl(write_fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
        filled = 0
        for chunk in (b"F" * 4096, b"F"):
            try:
                while True:
                    filled += os.write(write_fd, chunk)
            except BlockingIOError:
                pass
        fcntl.fcntl(write_fd, fcntl.F_SETFL, flags)
        assert filled > 0
        host = subprocess.Popen(list(map(str, fixture.host_arguments(store, None))),
            stdout=write_fd, stderr=write_fd,
            env={**os.environ,
                "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
                "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": "alias-poison",
                "RUI_DIAGNOSTIC_ARM": str(arm)})
        fixture.wait_for(lambda: log.exists() and "readiness-write-entry\n" in log.read_text(),
            "aliased required write entry without drainage")
        actual = fcntl.fcntl(write_fd, fcntl.F_GETFL)
        (root / "before-release.json").write_text(json.dumps({
            "filled": filled, "flags": actual, "expected_flags": flags,
            "returncode": host.poll()}) + "\n")
        assert host.poll() is None and not actual & os.O_NONBLOCK, (
            "required readiness must stay alive and blocking until caller releases credit",
            host.poll(), actual, log.read_text())
        assert_file_flags(actual, flags)
        remaining = filled
        while remaining:
            assert select.select([read_fd], [], [], 8)[0], "filler drainage stalled"
            chunk = os.read(read_fd, min(remaining, 4096))
            assert chunk and chunk == b"F" * len(chunk), chunk
            remaining -= len(chunk)
        deadline = time.monotonic() + 8
        while b"\n" not in output:
            assert select.select([read_fd], [], [], max(0, deadline - time.monotonic()))[0], "readiness stalled"
            chunk = os.read(read_fd, 1)
            assert chunk, "Host exited before complete readiness"
            output.extend(chunk)
            assert len(output) <= 16 * 1024, "readiness exceeded 16 KiB"
        parts = output.decode().split()
        assert parts[0] == "ready", bytes(output)
        fields = dict(part.split("=", 1) for part in parts[1:])
        assert fields["execution"] == "unavailable", fields
        status = subprocess.run([str(fixture.RUI), "host", "status", "--store", str(store)],
            capture_output=True, text=True, timeout=8)
        assert status.returncode == 0 and "Instance: " in status.stdout, status
        (root / "host-status.stdout").write_text(status.stdout)
        print("Host diagnostics: aliased full stdout, startup warning and failed restore: required readiness blocks until exact filler release; Host usable", flush=True)
    finally:
        if host is not None:
            if host.poll() is None: host.kill()
            host.wait(timeout=8)
        os.set_blocking(read_fd, False)
        while True:
            try:
                chunk = os.read(read_fd, 65536)
            except BlockingIOError:
                break
            if not chunk: break
            output.extend(chunk)
        (root / "stdout-stderr.log").write_bytes(output)
        os.close(read_fd)
        os.close(write_fd)
    root = state / "startup-record-failure"
    root.mkdir(mode=0o700)
    store = root / "store"
    store.mkdir(mode=0o700)
    diagnostics = store / "diagnostics"
    diagnostics.mkdir(mode=0o700)
    # Open succeeds with one full private file. Its next rotation fails at
    # record time, not open time; no new fault hook or I/O interception.
    last = diagnostics / f"host-{2**64 - 2}.jsonl"
    with last.open("wb") as file:
        last.chmod(0o600)
        file.truncate(8 * 1024 * 1024)
        file.seek(-1, os.SEEK_END)
        file.write(b"\n")
    host = None
    output = bytearray()
    try:
        host = subprocess.Popen(list(map(str, fixture.host_arguments(store, None))),
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 8
        while output.count(b"\n") < 2:
            assert select.select([host.stdout], [], [], max(0, deadline - time.monotonic()))[0], "missing retained writer failure notice"
            chunk = os.read(host.stdout.fileno(), 4096)
            assert chunk, "Host exited before readiness and retained failure notice"
            output.extend(chunk)
            assert len(output) <= 16 * 1024
        ready, notice, tail = output.split(b"\n", 2)
        assert ready.startswith(b"ready ") and b"execution=unavailable" in ready, output
        assert notice == b"rui: diagnostic writer unavailable (DiagnosticSequenceExhausted); no Host work was changed", output
        assert not tail, output
        assert last.stat().st_size == 8 * 1024 * 1024
        assert list(diagnostics.iterdir()) == [last], "failed writer grew diagnostics"
        status = subprocess.run([str(fixture.RUI), "host", "status", "--store", str(store)],
            capture_output=True, text=True, timeout=8)
        assert status.returncode == 0 and "Instance: " in status.stdout, status
        print("Host diagnostics: record-time failure retained under exclusion; one notice follows required readiness; Host usable", flush=True)
    finally:
        (root / "stdout-stderr.log").write_bytes(output)
        if host is not None:
            fixture.stop_host(host)
    for kind in ("readiness-held", "readiness-held-error"):
        root = state / kind
        root.mkdir(mode=0o700)
        store, log, release = (root / name for name in ("store", "probe.log", "release"))
        # Save queued work without an execution adapter, then restart it under
        # the native readiness gate. No live raw Store reads or new hooks.
        seed = fixture.start_host(store, None)
        try:
            fixture.configure(root, store, "config", "ready/session", "model-a")
            fixture.message(root, store, "queued", "ready/session", "READY-ANSWER")
        finally:
            fixture.stop_host(seed)
        endpoint = fixture.SuccessEndpoint([
            fixture.sse_answer("ready-a", "ready-r", "ready-m", "READY-ANSWER")[0]])
        server = threading.Thread(target=endpoint.serve_forever)
        server.start()
        result = []
        env = {**os.environ,
            "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
            "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": kind,
            "RUI_DIAGNOSTIC_RELEASE": str(release)}

        def start():
            try:
                result.append(start_ready_process(fixture.host_arguments(store,
                    f"http://127.0.0.1:{endpoint.server_port}/responses", "--test-phase-trace"),
                    env=env, required_fields={"execution": "enabled", "curl": "8.22.0"}))
            except BaseException as error:
                result.append(error)

        starter = threading.Thread(target=start)
        starter.start()
        host = None
        try:
            fixture.wait_for(lambda: log.exists() and "readiness-held\n" in log.read_text(), "required readiness gate")
            # Receiving the request requires preparation and handoff, both of
            # which attempt production opt-in traces before transport service.
            fixture.wait_for(lambda: endpoint.requests, "execution during readiness exclusion")
            assert starter.is_alive() and not result, result
            effects = log.read_text()
            assert "readiness-fd2-borrow\n" not in effects and "readiness-fd2-write\n" not in effects, effects
            release.touch()
            starter.join(timeout=10)
            assert not starter.is_alive() and len(result) == 1, result
            if kind == "readiness-held-error":
                assert isinstance(result[0], HostStartError), result
                assert "readiness-write-failed\n" in log.read_text()
                try:
                    os.kill(result[0].pid, 0)
                except ProcessLookupError:
                    pass
                else:
                    raise AssertionError("failed readiness was not reaped")
            else:
                assert not isinstance(result[0], BaseException), result
                host, fields = result[0]
                assert fields["execution"] == "enabled"
                observation = fixture.wait_for(lambda: fixture.completed_observation(store, "queued"), "queued exact answer")
                assert observation["result"]["status"] == "completed", observation
                assert fixture.read_result(store, "queued") == b"READY-ANSWER"
            print(f"Host diagnostics: {kind}: execution traces attempted under exclusion; no fd2 borrow/write; required outcome checked", flush=True)
        finally:
            release.touch()
            starter.join(timeout=10)
            if host is None and result and isinstance(result[0], tuple): host = result[0][0]
            if host is not None: fixture.stop_host(host)
            endpoint.shutdown()
            endpoint.server_close()
            server.join(timeout=5)
            assert not server.is_alive() and not starter.is_alive()
    for kind in ("readiness-alias", "readiness-error"):
        root = state / kind
        root.mkdir(mode=0o700)
        log = root / "probe.log"
        env = {**os.environ,
            "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
            "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": kind}
        host = None
        try:
            try:
                host, fields = start_ready_process(fixture.host_arguments(root / "store", None),
                    env=env, required_fields={"execution": "unavailable"})
            except HostStartError as error:
                assert kind == "readiness-error", error
                assert "readiness-write-failed\n" in log.read_text()
                # start_ready_process's failure owner has already reaped it.
                try:
                    os.kill(error.pid, 0)
                except ProcessLookupError:
                    pass
                else:
                    raise AssertionError("readiness failure left Host alive")
            else:
                assert kind == "readiness-alias" and fields["execution"] == "unavailable"
                assert "readiness-aliased\n" in log.read_text()
                fixture.configure(root, root / "store", "alias-config", "alias/session", "model-a")
                assert fixture.command("inspect-session", "--store", root / "store", "--session", "alias/session")["session"]
            print(f"Host diagnostics: {kind}: required stdout outcome checked", flush=True)
        finally:
            if host is not None: fixture.stop_host(host)
    population = [
        ("normal", "response-acquire"), ("filled", "response-acquire"),
        ("closed", "response-acquire"), ("normal", "response-metadata"),
        ("filled", "response-metadata"), ("filled", "response-commit"),
        ("normal", "response-write"), ("normal", "response-commit"),
        ("diagnostic-enable", "response-acquire"),
        ("diagnostic-enable-unmutated", "response-acquire"),
        ("diagnostic-partial", "response-acquire"),
        ("diagnostic-nonblock", "response-acquire"),
        ("diagnostic-restore", "response-acquire"),
        ("diagnostic-restore-startup", "response-acquire"),
        ("diagnostic-contention", "response-acquire"),
        ("normal", "response-unlink"),
        ("filled", "success"), ("closed", "success"),
        ("diagnostic-restore", "success"),
    ]
    for credit, fault in population:
        root = state / f"host-{credit}-{fault}"
        root.mkdir(mode=0o700)
        store, log, arm, release = (root / name for name in ("store", "probe.log", "arm", "release"))
        count = 2 if credit in ("diagnostic-enable", "diagnostic-enable-unmutated", "diagnostic-restore", "diagnostic-restore-startup") else 1
        endpoint = fixture.SuccessEndpoint([
            fixture.sse_answer(f"diagnostic-a-{index}", f"diagnostic-r-{index}", f"diagnostic-m-{index}", "ANSWER")[0]
            for index in range(count)
        ])
        thread = threading.Thread(target=endpoint.serve_forever)
        thread.start()
        read_fd, write_fd = os.pipe()
        reader = os.fdopen(read_fd, "rb", buffering=0)
        flags = fcntl.fcntl(write_fd, fcntl.F_GETFL)
        if credit == "diagnostic-nonblock" or (credit == "filled" and fault == "success"):
            # Traced successful work can write while idle: establish its
            # nonblocking flags before spawn, not through an external race.
            flags |= os.O_NONBLOCK
            fcntl.fcntl(write_fd, fcntl.F_SETFL, flags)
        host = pending = None
        env = {**os.environ,
            "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
            "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": "diagnostic-restore" if credit == "diagnostic-restore-startup" else credit,
            "RUI_DIAGNOSTIC_ARM": str(arm), "RUI_DIAGNOSTIC_RELEASE": str(release)}
        try:
            if credit == "diagnostic-restore-startup":
                # An optional startup-file warning poisons later borrowing,
                # not required readiness or already accepted work.
                store.mkdir(mode=0o700)
                (store / "diagnostics").mkdir(mode=0o755)
                (store / "diagnostics").chmod(0o755)
                arm.touch()
            host, _ = start_ready_process(fixture.host_arguments(store,
                f"http://127.0.0.1:{endpoint.server_port}/responses",
                *(["--fault", fault] if fault != "success" else []),
                *(["--test-phase-trace"] if fault == "success" or credit in ("diagnostic-contention", "diagnostic-partial") else [])), env=env, stderr_pipe=(reader, write_fd),
                required_fields={"execution": "enabled", "curl": "8.22.0"})
            session = "diagnostic/session"
            fixture.configure(root, store, "config", session, "model-a")
            if credit == "diagnostic-contention":
                fixture.configure(root, store, "config-other", "diagnostic/session-extra", "model-a")
            status = subprocess.run([str(fixture.RUI), "host", "status", "--store", str(store)],
                capture_output=True, text=True, timeout=8)
            assert status.returncode == 0 and "Instance: " in status.stdout, status
            instance = status.stdout.split("Instance: ", 1)[1].splitlines()[0]
            # Fill only while idle. The inherited open file description starts
            # submissions with exactly its original flags, not Python's flags.
            if credit == "filled":
                fcntl.fcntl(write_fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
                filled = 0
                try:
                    while True:
                        filled += os.write(write_fd, b"F" * 4096)
                except BlockingIOError:
                    try:
                        while True:
                            filled += os.write(write_fd, b"F")
                    except BlockingIOError:
                        pass
                finally:
                    fcntl.fcntl(write_fd, fcntl.F_SETFL, flags)
                assert filled > 0
            if credit == "closed":
                reader.close()
            if credit.startswith("diagnostic-"):
                arm.touch()
            if credit == "diagnostic-partial":
                fixture.command("inspect-session", "--store", store, "--session", session)
                assert "diagnostic-partial\n" in log.read_text()
                arm.unlink()
            if credit == "diagnostic-contention":
                # Wrong phase and prefix-lookalike Session must not claim the
                # hold. No target inspection is outstanding before pending.
                status = subprocess.run([str(fixture.RUI), "host", "status", "--store", str(store)],
                    capture_output=True, text=True, timeout=3)
                assert status.returncode == 0 and "diagnostic-held" not in log.read_text(), status
                unrelated = fixture.start_command("inspect-session", "--store", store, "--session", "diagnostic/session-extra")
                out, err = unrelated.communicate(timeout=3)
                assert unrelated.returncode == 0 and "diagnostic-held" not in log.read_text(), (out, err)
                pending = fixture.start_command("inspect-session", "--store", store, "--session", session)
                fixture.wait_for(lambda: log.exists() and "diagnostic-held-inspection\n" in log.read_text(), "native inspection fd2 held")
                captured = [json.loads(line) for line in log.read_text().splitlines() if line.startswith("{")]
                assert len(captured) == 1, captured
                held = captured[0]
                assert held["rui_test_phase"] == "inspection_captured" and held["subject_kind"] == "session" and held["subject"] == session, held
                assert held["process"] == str(host.pid) and int(held["run"]) > 0 and int(held["sequence"]) > 0 and held["clock"] == "awake_ns", held
                assert pending.poll() is None, "first inspection escaped native gate"
                concurrent = fixture.start_command("inspect-session", "--store", store, "--session", session)
                out, err = concurrent.communicate(timeout=3)
                assert concurrent.returncode == 0, (out, err)
                assert pending.poll() is None, "first inspection escaped native gate"
                release.touch()
                fixture.finish_command(pending)
                pending = None
                arm.unlink()
            for index in range(count):
                key = f"message-{index}"
                # The original regression payload: exactly 156000 decoded bytes.
                text = 'é中🙂\n\\"/' * 12000
                assert len(text.encode()) == 156000
                fixture.message(root, store, key, session, text)
                if fault == "response-commit":
                    fixture.wait_for(lambda: host.poll() is not None, "canonical fence exits")
                    assert host.returncode != 0
                    with sqlite3.connect(f"file:{store / 'rui.sqlite3'}?mode=ro", uri=True) as database:
                        assert database.execute("SELECT uncertain,resolution_code FROM model_operation").fetchone() == (1, None)
                        assert database.execute("SELECT count(*) FROM model_output_item").fetchone() == (0,)
                    break
                if fault == "response-unlink":
                    resources = fixture.wait_for(lambda: (value if (value := fixture.command(
                        "inspect-session", "--store", store, "--session", session)["execution"])["dispatch_fenced"] else None),
                        "retained response cleanup")
                    assert resources["custody_occupied"] == "1", resources
                    leftovers = list((store / "scratch").glob("response-[0-9]*.tmp"))
                    assert len(leftovers) == 1, leftovers
                    # This existing acquisition fault retains an empty named
                    # file before provider launch, so its correct charge is 0.
                    assert int(resources["scratch_used_bytes"]) == leftovers[0].stat().st_size == 0, resources
                    assert not endpoint.requests, endpoint.requests
                    stopped = subprocess.run([str(fixture.RUI), "host", "stop", "--store", str(store), "--instance", instance],
                        capture_output=True, text=True, timeout=8)
                    (root / "host-stop.stdout").write_text(stopped.stdout)
                    (root / "host-stop.stderr").write_text(stopped.stderr)
                    assert stopped.returncode == 0, stopped
                    assert "Stop acknowledged; completion and lease release are not confirmed" in stopped.stdout, stopped
                    print(f"Host diagnostics: retained response file, charge=0, custody=1; stop reply={stopped.stdout!r}", flush=True)
                    # A stop acknowledgement is not cleanup completion: the
                    # injected unlink refusal remains active during shutdown.
                    assert host.poll() is None, "stop falsely completed retained cleanup"
                    (root / "retained-resources.json").write_text(json.dumps(resources, indent=2) + "\n")
                    host.kill()
                    assert host.wait(timeout=8) == -signal.SIGKILL
                    assert leftovers[0].exists()
                    with sqlite3.connect(f"file:{store / 'rui.sqlite3'}?mode=ro", uri=True) as database:
                        assert database.execute("SELECT uncertain,resolution_code FROM model_operation").fetchone() == (1, None)
                        assert database.execute("SELECT count(*) FROM model_output_item").fetchone() == (0,)
                    fresh = fixture.start_host(store, None)
                    try:
                        assert not leftovers[0].exists()
                        clean = fixture.command("inspect-session", "--store", store, "--session", session)["execution"]
                        assert clean["custody_occupied"] == "0" and clean["scratch_used_bytes"] == "0", clean
                        (root / "fresh-resources.json").write_text(json.dumps(clean, indent=2) + "\n")
                    finally:
                        fixture.stop_host(fresh)
                    break
                if fault == "success":
                    observation = fixture.wait_for(lambda: fixture.completed_observation(store, key), f"{credit} answer settles")
                    assert observation["result"]["status"] == "completed", observation
                    assert fixture.read_result(store, key) == b"ANSWER"
                else:
                    expected = {"response-acquire": "response_capture_failed", "response-metadata": "response_metadata_failed",
                        "response-write": "response_write_failed"}[fault]
                    observation = fixture.wait_for(lambda: (value if (value := fixture.observe(store, key)).get("result", {}).get("code") else None),
                        f"{credit} {fault} settles")
                    assert observation["result"]["code"] == expected, observation
                resources = fixture.wait_for(lambda: (value if (value := fixture.command(
                    "inspect-session", "--store", store, "--session", session)["execution"])["custody_occupied"] == "0" else None),
                    "diagnostic custody retirement")
                assert resources["scratch_used_bytes"] == "0", resources
                if index == 0 and credit in ("diagnostic-enable", "diagnostic-enable-unmutated"):
                    arm.unlink()
            assert_file_flags(fcntl.fcntl(write_fd, fcntl.F_GETFL),
                flags | os.O_NONBLOCK if credit.startswith("diagnostic-restore") else flags)
            if credit in ("diagnostic-enable", "diagnostic-enable-unmutated", "diagnostic-restore", "diagnostic-restore-startup"):
                effects = log.read_text()
                assert ("diagnostic-mutated\n" in effects) == (credit != "diagnostic-enable-unmutated"), effects
                if not credit.startswith("diagnostic-restore"):
                    assert "diagnostic-restored\n" in effects, effects
                    assert effects.count("diagnostic-enable\n") == 1, effects
                    assert "diagnostic-write\n" not in effects, effects
                else:
                    assert effects.count("diagnostic-enable\n") == 1 and "diagnostic-unrestored\n" in effects, effects
                    assert effects.count("diagnostic-write\n") == 1, effects
            if credit == "diagnostic-partial":
                effects = log.read_text()
                assert effects.count("diagnostic-partial\n") == 1, effects
                assert "diagnostic-partial-retry\n" not in effects, effects
                assert "diagnostic-restored\n" in effects, effects
            if credit == "diagnostic-nonblock":
                effects = log.read_text()
                assert effects.count("diagnostic-write\n") == 1, effects
                assert "diagnostic-enable\n" not in effects and "diagnostic-restore\n" not in effects, effects
            errors = bytearray()
            if not reader.closed:
                os.set_blocking(reader.fileno(), False)
                while True:
                    try:
                        chunk = os.read(reader.fileno(), 65536)
                    except BlockingIOError:
                        break
                    if not chunk: break
                    errors.extend(chunk)
            (root / "stderr.log").write_bytes(errors)
            contexts = {"response-acquire": b"provider preparation failed for operation",
                "response-metadata": b"provider output rejected for operation 1: InjectedMetadataFailure",
                "response-commit": b"dispatch fenced after", "response-unlink": b"dispatch fenced after"}
            if credit == "normal" and fault in contexts:
                assert contexts[fault] in errors, bytes(errors[-2000:])
            if credit == "normal" and fault in ("response-commit", "response-unlink"):
                guidance = b"Host cannot safely continue; wait for shutdown" if fault == "response-commit" else b"New work is blocked; retained cleanup is still owned."
                assert guidance in errors and b"do not resubmit uncertain work." in errors, bytes(errors)
            if credit in ("diagnostic-enable", "diagnostic-enable-unmutated"):
                assert errors.count(contexts["response-acquire"]) == 1, bytes(errors)
            if credit in ("diagnostic-contention", "diagnostic-partial"):
                records = []
                for line in errors.splitlines():
                    if not line.startswith(b'{'): continue
                    try:
                        records.append(json.loads(line))
                    except json.JSONDecodeError:
                        assert credit == "diagnostic-partial" and line.startswith(b'{{'), line
                assert any(record.get("trace_lost") is True for record in records), records
                lost = next(i for i, record in enumerate(records) if record.get("trace_lost") is True)
                assert all(record.get("trace_lost") is True for record in records[lost:]), records
                assert "diagnostic-restored\n" in log.read_text()
            warnings = [line for line in errors.splitlines() if line.startswith(b"rui:")]
            print(f"Host diagnostics: {credit}/{fault}: public outcome checked, flags checked; warnings={warnings!r}", flush=True)
        finally:
            release.touch()
            if pending is not None:
                pending.communicate(timeout=5)
            if host is not None:
                if host.poll() is None:
                    host.kill()
                host.wait(timeout=8)
                if not reader.closed:
                    os.set_blocking(reader.fileno(), False)
                    with (root / "stderr.log").open("ab") as retained:
                        while True:
                            try:
                                chunk = os.read(reader.fileno(), 65536)
                            except BlockingIOError:
                                break
                            if not chunk: break
                            retained.write(chunk)
                fixture.stop_host(host)
            elif not reader.closed: reader.close()
            os.close(write_fd)
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)
            assert not thread.is_alive()


def main(selected=None):
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-terminal-restoration."))
    home = state / "home"
    home.mkdir()
    store = state / "store"
    host = None
    completed = False
    try:
        source, library = state / "probe.c", state / "probe.so"
        source.write_text(PROBE)
        subprocess.run(["cc", "-dynamiclib" if sys.platform == "darwin" else "-shared",
            "-fPIC", str(source), *(["-ldl"] if sys.platform == "linux" else []), "-o", str(library)], check=True)
        check_forwarding(state, library)
        if selected == "forwarding":
            completed = True
            return
        if selected in (None, "host-diagnostics"):
            host_diagnostic_cases(state, library)
        if selected == "host-diagnostics":
            completed = True
            return
        if selected in (None, "consent"):
            consent_boundary_cases(state, library)
        if selected == "consent":
            completed = True
            return
        if selected in (None, "fatal"):
            fatal_reporting_cases(state)
        if selected == "fatal":
            completed = True
            return
        if selected in (None, "decisions"):
            decision_reporting_cases(state)
        if selected == "decisions":
            completed = True
            return
        if selected in (None, "detach"):
            detach_reporting_cases(state, library)
        if selected == "detach":
            completed = True
            return
        if selected in (None, "startup"):
            startup_reporting_cases(state, library)
        if selected == "startup":
            completed = True
            return
        if selected in (None, "visible-stream"):
            visible_stream_handoff_cases(state, library)
        if selected == "visible-stream":
            completed = True
            return
        host = fixture.start_host(store, None)
        human.run(home, "configure", "--store", store, "--session", "terminal/restoration",
            "--workspace", state, "--provider", "codex", "--model", "model-a")
        assert selected in (None, "persistent"), selected
        persistent_cases(state, library, home, store, host)
        completed = True
    finally:
        if host is not None:
            fixture.stop_host(host)
        if completed and selected != "host-diagnostics":
            shutil.rmtree(state)
        else:
            print(f"retained terminal restoration state (completed={completed}): {state}", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[2] if len(sys.argv) == 3 else None)
