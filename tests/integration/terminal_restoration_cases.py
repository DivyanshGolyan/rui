"""Real editor handoff, queued input and independently failed cleanup effects.

terminal_restoration_integration.py runs these cases; the human CLI fixture runs
them too in its full mode."""
import fcntl
import json
import os
import pathlib
import pty
from terminal_process import close_pty, answers_to, open_pty, spawn
import resource
import select
import shutil
import signal
import sqlite3
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
from collections import Counter

import canonical_fixture as canonical
import model_fixture as fixture
import human_cli_fixture as human
from host_process import HostStartError, canonical_fixture_root, cleanup_failure, dispose_all, preserve_failure_metadata, retain_failure_state, start_ready_process, stop_process
import os_semantics
from product_defaults import DEFAULTS
from terminal_restoration_fixture import assert_file_flags, preserve_renderer_comparison, stop_receipt_case


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
#include <signal.h>
#include <sys/resource.h>
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

/* App writes the screen through its own /dev/tty descriptor, and commands
   borrow fd 1 for their page. Screen probes match the terminal that was fd 1
   at load, or the controlling terminal opened as /dev/tty, by identity rather
   than the descriptor number. */
static int screen_known = 0, controlling_known = 0;
static dev_t screen_dev, controlling_dev;
static ino_t screen_ino, controlling_ino;

__attribute__((constructor)) static void screen_identity(void) {
    struct stat st;
    if (isatty(1) && !fstat(1, &st)) {
        screen_dev = st.st_dev;
        screen_ino = st.st_ino;
        screen_known = 1;
    }
    if (!stat("/dev/tty", &st)) {
        controlling_dev = st.st_dev;
        controlling_ino = st.st_ino;
        controlling_known = 1;
    }
}

static int screen_fd(int fd) {
    struct stat st;
    if (fd == 1) return 1;
    if (fd > 2 && !fstat(fd, &st) && ((screen_known && st.st_dev == screen_dev && st.st_ino == screen_ino)
            || (controlling_known && st.st_dev == controlling_dev && st.st_ino == controlling_ino))) return 1;
    return fd;
}

static int command_saved[2] = {-1, -1};
static int command_page = -1;
static int command_restore_failed = 0;

static int restoration_fault(void) {
    const char *fault = getenv("RUI_TERMINAL_FAULT");
    if (!fault) return 0;
    if (!strcmp(fault, "configure-restore-stdout")) return 1;
    if (!strcmp(fault, "configure-restore-stderr")) return 2;
    if (!strcmp(fault, "configure-restore-both")) return 3;
    return 0;
}

static int probe_dup2(int source, int target) {
#ifdef __APPLE__
    int (*real_dup2)(int, int) = dup2;
#else
    int (*real_dup2)(int, int) = dlsym(RTLD_NEXT, "dup2");
#endif
    if (!real_dup2 || real_dup2 == probe_dup2) _exit(98);
    const int fault = restoration_fault();
    if (fault && target >= 1 && target <= 2) {
        if (source == command_saved[target - 1]) {
            record(target == 1 ? "restore-stdout-attempt\n" : "restore-stderr-attempt\n");
            if (fault & target) {
                command_restore_failed = 1;
                errno = EIO;
                return -1;
            }
        } else if (target == 1) {
            command_page = source;
        }
    }
    return real_dup2(source, target);
}

/* Stop the unfixed feedback loop before it can consume disk. This checks
   the actual descriptor identities, not just the injected syscall result. */
static void check_command_replay(int fd, const void *bytes, size_t count) {
    if (!command_restore_failed || count != strlen("rui: Interrupted command output:\n") ||
        memcmp(bytes, "rui: Interrupted command output:\n", count)) return;
    struct stat sink, page;
    if (fstat(fd, &sink) || fstat(command_page, &page)) _exit(86);
    if (sink.st_dev == page.st_dev && sink.st_ino == page.st_ino) {
        record("replayed-into-scratch\n");
        _exit(87);
    }
    record("replayed-to-safe-sink\n");
}

__attribute__((constructor)) static void diagnostic_alias(void) {
    const char *fault = getenv("RUI_TERMINAL_FAULT");
    if (fault && (!strcmp(fault, "readiness-alias") || !strncmp(fault, "readiness-held", 14))) {
        if (dup2(1, 2) < 0) _exit(88);
        record("readiness-aliased\n");
    }
}

/* Only the submission owner can name this boundary: ClientTask and
   std.Thread use an opaque entry/argument pair shared by readers. Scope the
   identity to the spawning thread, and clear it even when pthread_create fails. */
static _Thread_local int submission_start = 0;

void rui_test_submission_start(int entering) {
    if (submission_start == entering) _exit(85);
    submission_start = entering;
    const char *arm = getenv("RUI_TERMINAL_STARTUP_ARM");
    if (arm && !access(arm, F_OK))
        record(entering ? "submission-start\n" : "submission-start-end\n");
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
    const int armed = arm && !access(arm, F_OK);
    if (armed && submission_start) {
        record("worker-not-started\n");
        return EAGAIN;
    }
    const int result = real_create(thread, attrs, run, arg);
    if (armed && !result) record("non-submission-worker-started\n");
    return result;
}

static int command_return_signal(int fd, const void *bytes, size_t count) {
    const char *fault = getenv("RUI_TERMINAL_FAULT");
    static int signaled = 0;
    static size_t matched = 0;
    static int mismatch = 0;
    if (signaled || !fault) return 0;
    const char *marker = NULL;
    int prefix = 0;
    /* Commands write their page through fd 1 (the Session screen uses its
       own duplicate); inspections such as /requests write their page file
       directly. A Configure's capture file is not a page: its partial line
       would poison the matcher. */
    struct stat st;
    const int command_page = fd == 1;
    const int inspection_page = fd > 2 && !fstat(fd, &st) && S_ISREG(st.st_mode);
    if (command_page && (!strcmp(fault, "configure-admitted") || !strcmp(fault, "configure-presentation") || restoration_fault()))
        marker = "Rui: Configured.";
    else if (command_page && !strcmp(fault, "configure-rejected")) marker = "admitted: rejected";
    else if (inspection_page && !strcmp(fault, "requests")) marker = "Rui: Local recovery handles (not Host work status):";
    else if (fd == 2 && !strcmp(fault, "configure-canonical")) {
        marker = "rui: Configuration ";
        prefix = 1;
    }
    if (!marker) return 0;
    const size_t length = strlen(marker);
    /* Retain only a bounded prefix and mismatch bit, never a diagnostic line.
       Newline is the completion boundary, independent of syscall segmentation. */
    for (size_t i = 0; i < count; ++i) {
        char byte = ((const char *)bytes)[i];
        if (byte == '\n') {
            int complete = !mismatch && matched == length;
            matched = 0;
            mismatch = 0;
            if (!complete) continue;
            signaled = 1;
            record("command-return-signal\n");
            raise(SIGINT);  /* Complete admission/error is already decoded by its owner. */
            if (!strcmp(fault, "configure-presentation")) { errno = EIO; return -1; }
            break;
        }
        if (!mismatch) {
            if (matched < length && byte == marker[matched]) ++matched;
            else if (!(prefix && matched == length)) mismatch = 1;
        }
    }
    return 0;
}

static ssize_t probe_writev(int fd, const struct iovec *iov, int count) {
    const int screen = screen_fd(fd);
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
    for (int i = 0; i < count; ++i)
        if (command_return_signal(fd, iov[i].iov_base, iov[i].iov_len)) return -1;
    if (screen == 1 && count == 1 && iov[0].iov_len == 8 &&
        !memcmp(iov[0].iov_base, "\033[?2004l", 8)) {
        if (!strcmp(fault, "output") && !stopped) {
            if (tcflow(fd, TCOOFF)) _exit(92);
            stopped = 1;
            record("output-stopped\n");
        }
        record("disable\n");
        disabled = 1;
        /* EAGAIN on a large repaint does not establish lack of credit for
           this small control. Inject its cleanup failure independently. */
        if (!strcmp(fault, "disable") || !strcmp(fault, "both") || !strcmp(fault, "backpressure")) {
            errno = EIO;
            return -1;
        }
    }
    return real_writev(fd, iov, count);
}

static ssize_t probe_write(int fd, const void *bytes, size_t count) {
    check_command_replay(fd, bytes, count);
    const int screen = screen_fd(fd);
    const char *readiness_fault = getenv("RUI_TERMINAL_FAULT");
    if (screen == 1 && readiness_fault && !strcmp(readiness_fault, "alias-poison"))
        record("readiness-write-entry\n");
    if (fd == 2 && atomic_load(&readiness_held)) record("readiness-fd2-write\n");
    if (screen == 1 && readiness_fault && !strncmp(readiness_fault, "readiness-held", 14)) {
        atomic_store(&readiness_held, 1);
        record("readiness-held\n");
        while (access(getenv("RUI_DIAGNOSTIC_RELEASE"), F_OK)) usleep(1000);
        atomic_store(&readiness_held, 0);
        if (!strcmp(readiness_fault, "readiness-held-error")) {
            record("readiness-write-failed\n"); errno = EIO; return -1;
        }
    }
    if (screen == 1 && readiness_fault && !strcmp(readiness_fault, "readiness-error")) {
        record("readiness-write-failed\n"); errno = EIO; return -1;
    }
    if (screen == 1 && count == 8 && !memcmp(bytes, "\033[?2004l", 8)) {
        struct iovec iov = { (void *)bytes, count };
        return probe_writev(fd, &iov, 1);
    }
    if (screen == 1 && count == 8 && !memcmp(bytes, "\033[?1007h", 8)) record("scroll-enabled\n");
    if (screen == 1 && count == 8 && !memcmp(bytes, "\033[?1007l", 8)) record("scroll-reset\n");
#ifdef __APPLE__
    ssize_t (*real_write)(int, const void *, size_t) = write;
#else
    ssize_t (*real_write)(int, const void *, size_t) = dlsym(RTLD_NEXT, "write");
    if (real_write == write) _exit(96);
#endif
    if (!real_write || real_write == probe_write) _exit(96);
    const char *fault = getenv("RUI_TERMINAL_FAULT");
    if (command_return_signal(fd, bytes, count)) return -1;
    if (screen == 1 && detach_phase == 3 && fault && !strcmp(fault, "detach-write-full")) {
        record("detach-write\n");
        if (!(fcntl(fd, F_GETFL) & O_NONBLOCK)) record("detach-write-blocking\n");
    }
    const char *diagnostic_arm = getenv("RUI_DIAGNOSTIC_ARM");
    if (fd == 2 && diagnostic_arm && !access(diagnostic_arm, F_OK)) {
        const int lifecycle = !strcmp(fault, "diagnostic-contention-host");
        const char *phase = lifecycle ? "{\"rui_test_phase\":\"lifecycle_boundary\"," :
            "{\"rui_test_phase\":\"inspection_captured\",";
        /* The real Host allocates its identity after launch. Carry that exact
           ID in the arm file; the synthetic forwarding driver leaves it empty. */
        char session[8] = {0};
        if (!strcmp(fault, "diagnostic-contention")) {
            int arm_fd = open(diagnostic_arm, O_RDONLY);
            if (arm_fd < 0) _exit(100);
            ssize_t length = read(arm_fd, session, sizeof(session) - 1);
            if (close(arm_fd) || (length != 0 && length != 6)) _exit(100);
        }
        char subject[128];
        int subject_length = snprintf(subject, sizeof(subject),
            ",\"subject_kind\":\"session\",\"subject\":\"%s\"",
            session[0] ? session : "diagnostic/session");
        if (subject_length < 0 || (size_t)subject_length >= sizeof(subject)) _exit(100);
        static atomic_int contention_claimed = 0;
        int selected = 0;
        if ((lifecycle || !strcmp(fault, "diagnostic-contention")) && count >= strlen(phase) &&
            !memcmp(bytes, phase, strlen(phase)) && count >= 2 &&
            !memcmp((const char *)bytes + count - 2, "}\n", 2)) {
            selected = lifecycle;
            for (size_t i = 0; !lifecycle && i + (size_t)subject_length < count; ++i) {
                if (!memcmp((const char *)bytes + i, subject, (size_t)subject_length) &&
                    (((const char *)bytes)[i + subject_length] == ',' ||
                     ((const char *)bytes)[i + subject_length] == '}')) selected = 1;
            }
        }
        static atomic_int inspection_dropped = 0;
        if (selected && getenv("RUI_DIAGNOSTIC_DROP_FIRST_INSPECTION") &&
            !atomic_exchange(&inspection_dropped, 1)) {
            record("diagnostic-dropped-inspection\n");
            errno = EAGAIN;
            return -1;
        }
        if (selected && !atomic_exchange(&contention_claimed, 1)) {
            /* Complete fixed fixture identity, before the owned native write.
               The 512-byte buffer exceeds this phase/Session plus u64 metadata. */
            char correlation[512];
            if (count >= sizeof(correlation)) _exit(100);
            memcpy(correlation, bytes, count);
            correlation[count] = 0;
            record(correlation);
            record(lifecycle ? "diagnostic-held-lifecycle\n" : "diagnostic-held-inspection\n");
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
    /* Hold only after the frame carrying the marker closes: a terminal
       shows a synchronized frame only once its end arrives. */
    const char *frame_end = "\033[?2026l";
    static size_t matched = 0, ended = 0;
    static int visible = 0, shown = 0, stream_held = 0;
    int stream = screen == 1 && fault && !strcmp(fault, "visible-stream") && arm && !access(arm, F_OK);
    int reset = count == 4 && !memcmp(bytes, "\033[0m", 4);
    if (stream && shown && !disabled && !reset) {
        if (!stream_held) { record("visible-stream-held\n"); stream_held = 1; }
        errno = EAGAIN;
        return -1;
    }
    const char *pressure_arm = getenv("RUI_TERMINAL_BACKPRESSURE_ARM");
    static int pressure_stopped = 0;
    int pressured = fault && (!strcmp(fault, "backpressure") || !strcmp(fault, "renderer-backpressure"));
    if (screen == 1 && pressured && pressure_arm && !access(pressure_arm, F_OK) && !pressure_stopped) {
        /* Stop the real PTY before a bounded repaint, independently of input
           queue pressure. The syscall must encounter actual kernel EAGAIN.
           Arming after opening keeps a transient opening EAGAIN, drained by
           the test's own reader, from standing in for this one. */
        if (tcflow(fd, TCOOFF)) _exit(92);
        /* A stopped Darwin tty still queues a small frame. Fill the queue
           with ignored NULs, then single bytes, until the kernel itself
           reports EAGAIN. */
        int pressure_flags = fcntl(fd, F_GETFL);
        if (pressure_flags < 0 || fcntl(fd, F_SETFL, pressure_flags | O_NONBLOCK)) _exit(93);
        static const char filler[256];
        while (real_write(fd, filler, sizeof filler) > 0) {}
        while (errno == EAGAIN && real_write(fd, filler, 1) > 0) {}
        if (errno != EAGAIN || fcntl(fd, F_SETFL, pressure_flags)) _exit(94);
        pressure_stopped = 1;
        record("output-stopped\n");
    }
    ssize_t result = real_write(fd, bytes, count);
    int saved_errno = errno;
    if (stream && result > 0 && !shown) {
        for (ssize_t i = 0; i < result && !shown; ++i) {
            char byte = ((const char *)bytes)[i];
            if (!visible) {
                matched = byte == marker[matched] ? matched + 1 : (byte == marker[0] ? 1 : 0);
                if (!marker[matched]) { visible = 1; record("visible-prefix-written\n"); }
            } else {
                ended = byte == frame_end[ended] ? ended + 1 : (byte == frame_end[0] ? 1 : 0);
                if (!frame_end[ended]) { shown = 1; record("visible-frame-closed\n"); }
            }
        }
    }
    static int blocked = 0, progressed = 0;
    if (screen == 1 && pressure_stopped && result < 0 && saved_errno == EAGAIN && !blocked) {
        blocked = 1;
        record("output-blocked\n");
    }
    /* Later accepted screen output would mean the stopped queue drained,
       distinguishing that from work done while still blocked. */
    if (screen == 1 && blocked && !progressed && result > 0 && !strcmp(fault, "backpressure")) {
        progressed = 1;
        record("output-progressed\n");
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
    if (restoration_fault() && (fd == 1 || fd == 2) && command == F_DUPFD_CLOEXEC) {
        struct rlimit limit;
        if (getrlimit(RLIMIT_NOFILE, &limit) || limit.rlim_cur != 256) _exit(85);
        record("command-nofile-256\n");
        const int saved = real_fcntl(fd, command, value);
        command_saved[fd - 1] = saved;
        return saved;
    }
    const char *diagnostic_arm = getenv("RUI_DIAGNOSTIC_ARM");
    const char *diagnostic_fault = getenv("RUI_TERMINAL_FAULT");
    if (command == F_SETFL && diagnostic_fault && !strncmp(diagnostic_fault, "entry-", 6)) {
        const int target = diagnostic_fault[6] - '0';
        /* The screen enables its private duplicate of stdout. */
        if (fd == target || (target == 1 && screen_fd(fd) == 1)) {
            if (value & O_NONBLOCK) {
                record("entry-enable\n");
                if (strstr(diagnostic_fault, "unmutated")) { errno = EIO; return -1; }
                int result = real_fcntl(fd, command, value);
                if (result) return result;
                record("entry-mutated\n");
                errno = EIO; return -1;
            }
            record("entry-restore\n");
            if (strstr(diagnostic_fault, "reset")) { errno = EIO; return -1; }
            int result = real_fcntl(fd, command, value);
            if (!result) record("entry-restored\n");
            return result;
        }
    }
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
    if (screen_fd(fd) == 1 && command == F_SETFL && detach_phase) {
        const char *fault = getenv("RUI_TERMINAL_FAULT");
        if (detach_phase == 1 && !(value & O_NONBLOCK)) {
            int result = real_fcntl(fd, command, value);
            if (!result) { detach_phase = 2; record("cleanup-flags-restored\n"); }
            return result;
        }
        if (detach_phase == 2 && (value & O_NONBLOCK)) {
            detach_phase = 3;
            record("detach-enable\n");
            if (!strcmp(fault, "detach-enable-mutated-reset")) {
                int result = real_fcntl(fd, command, value);
                if (result) return result;
                record("detach-mutated\n");
                errno = EIO; return -1;
            }
        } else if (detach_phase == 3 && !(value & O_NONBLOCK)) {
            detach_phase = 4;
            record("detach-reset\n");
            if (!strcmp(fault, "detach-enable-mutated-reset")) { errno = EIO; return -1; }
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
    if (screen_fd(fd) == 1 && disabled) {
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

/* Page files may be written positionally; their markers still count. */
static ssize_t probe_pwritev(int fd, const struct iovec *iov, int count, off_t offset) {
#ifdef __APPLE__
    ssize_t (*real_pwritev)(int, const struct iovec *, int, off_t) = pwritev;
#else
    ssize_t (*real_pwritev)(int, const struct iovec *, int, off_t) = dlsym(RTLD_NEXT, "pwritev64");
#endif
    if (!real_pwritev || real_pwritev == probe_pwritev) _exit(97);
    for (int i = 0; i < count; ++i)
        if (command_return_signal(fd, iov[i].iov_base, iov[i].iov_len)) return -1;
    return real_pwritev(fd, iov, count, offset);
}

static ssize_t probe_pwrite(int fd, const void *bytes, size_t count, off_t offset) {
#ifdef __APPLE__
    ssize_t (*real_pwrite)(int, const void *, size_t, off_t) = pwrite;
#else
    ssize_t (*real_pwrite)(int, const void *, size_t, off_t) = dlsym(RTLD_NEXT, "pwrite64");
#endif
    if (!real_pwrite || real_pwrite == probe_pwrite) _exit(97);
    if (command_return_signal(fd, bytes, count)) return -1;
    return real_pwrite(fd, bytes, count, offset);
}

#ifdef __APPLE__
#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *new_fn; const void *old_fn; } \
    pair_##original __attribute__((section("__DATA,__interpose"))) = \
        { (const void *)&replacement, (const void *)&original };
INTERPOSE(probe_writev, writev)
INTERPOSE(probe_write, write)
INTERPOSE(probe_pwritev, pwritev)
INTERPOSE(probe_pwrite, pwrite)
INTERPOSE(probe_fsync, fsync)
INTERPOSE(probe_tcdrain, tcdrain)
INTERPOSE(probe_tcsetattr, tcsetattr)
INTERPOSE(probe_fcntl, fcntl)
INTERPOSE(probe_dup2, dup2)
INTERPOSE(probe_pthread_create, pthread_create)
#else
int dup2(int source, int target) { return probe_dup2(source, target); }
ssize_t writev(int fd, const struct iovec *iov, int count) { return probe_writev(fd, iov, count); }
ssize_t write(int fd, const void *bytes, size_t count) { return probe_write(fd, bytes, count); }
ssize_t pwritev64(int fd, const struct iovec *iov, int count, off_t offset) { return probe_pwritev(fd, iov, count, offset); }
ssize_t pwrite64(int fd, const void *bytes, size_t count, off_t offset) { return probe_pwrite(fd, bytes, count, offset); }
int fsync(int fd) { return probe_fsync(fd); }
int tcdrain(int fd) { return probe_tcdrain(fd); }
int tcsetattr(int fd, int action, const struct termios *attrs) { return probe_tcsetattr(fd, action, attrs); }
int pthread_create(pthread_t *thread, const pthread_attr_t *attrs, void *(*run)(void *), void *arg) {
    return probe_pthread_create(thread, attrs, run, arg);
}
#endif
"""


FORWARD_DRIVER = r"""
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/param.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

static volatile sig_atomic_t signals = 0;
static void interrupted(int sig) { (void)sig; ++signals; }

static void *noop(void *arg) { return arg; }

static int start_and_join(void) {
    pthread_t thread;
    int result = pthread_create(&thread, NULL, noop, NULL);
    return result ? result : pthread_join(thread, NULL);
}

struct other_start { int gate; int result; };
static void *start_elsewhere(void *raw) {
    struct other_start *other = raw;
    char byte;
    if (read(other->gate, &byte, 1) != 1) _exit(40);
    other->result = start_and_join();
    return NULL;
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "startup-selector")) {
        void (*mark)(int) = dlsym(RTLD_DEFAULT, "rui_test_submission_start");
        int gate[2];
        pthread_t other;
        if (!mark || pipe(gate)) return 41;
        struct other_start context = { .gate = gate[0], .result = -1 };
        /* Start the helper before entering the main thread's scope. Its own
           create runs only while that scope is active, proving TLS isolation. */
        if (pthread_create(&other, NULL, start_elsewhere, &context) || start_and_join()) return 42;
        mark(1);
        if (start_and_join() != EAGAIN) return 43;
        if (write(gate[1], "x", 1) != 1 || pthread_join(other, NULL) || context.result) return 44;
        mark(0);
        if (start_and_join()) return 45;  /* Failed spawn did not leak scope. */
        mark(1);
        if (start_and_join() != EAGAIN) return 46;
        mark(0);
        return close(gate[0]) || close(gate[1]);
    }
    if (argc == 3 && !strcmp(argv[1], "command-marker")) {
        const char *fault = getenv("RUI_TERMINAL_FAULT");
        int canonical = !strcmp(fault, "configure-canonical");
        int presentation = !strcmp(fault, "configure-presentation");
        int fd = canonical ? 2 : 1;
        const char *marker = canonical ? "rui: Configuration failed" :
            !strcmp(fault, "configure-rejected") ? "admitted: rejected" : "Rui: Configured.";
        signal(SIGINT, interrupted);
        /* Embedded and truncated line lookalikes must not signal. */
        write(fd, "x", 1);
        write(fd, marker, strlen(marker));
        write(fd, "\n", 1);
        write(fd, marker, 3);
        write(fd, "\n", 1);
        if (signals) return 30;
        ssize_t result;
        if (!strcmp(argv[2], "coalesced")) {
            char buffer[128];
            strcpy(buffer, "context\n");
            strcat(buffer, marker);
            strcat(buffer, "\ntrailer\n");
            result = write(fd, buffer, strlen(buffer));
        } else {
            write(fd, "context\n", 8);
            write(fd, marker, 3);
            if (signals) return 31;
            struct iovec parts[] = {{(void *)(marker + 3), strlen(marker) - 3}, {(void *)"", 0}};
            writev(fd, parts, 2);
            if (signals) return 32;
            struct iovec end[] = {{(void *)"\n", 1}, {(void *)"trailer\n", 8}};
            result = writev(fd, end, 2);
        }
        if (signals != 1) return 33;
        if (presentation ? (result != -1 || errno != EIO) : result < 0) return 34;
        write(fd, marker, strlen(marker));
        write(fd, "\n", 1);
        return signals == 1 ? 0 : 35;
    }
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
    master, slave = open_pty()
    original = termios.tcgetattr(slave)
    caller = None
    try:
        env = {**os.environ,
            os_semantics.PRELOAD: str(library),
            "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": "forwarding"}
        caller = spawn([str(executable)], stdin=slave, stdout=slave,
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
        dispose_all(
            lambda: stop_process(caller, timeout=5) if caller is not None else None,
            lambda: termios.tcflush(slave, termios.TCOFLUSH),
            lambda: termios.tcflush(slave, termios.TCIFLUSH),
            lambda: termios.tcsetattr(slave, termios.TCSANOW, original),
            lambda: close_pty(master), lambda: close_pty(slave),
        )

    arm, log = state / "forward-startup-arm", state / "forward-startup.log"
    arm.touch()
    result = subprocess.run([str(executable), "startup-selector"], env={**env,
        "RUI_TERMINAL_STARTUP_ARM": str(arm), "RUI_TERMINAL_PROBE": str(log)},
        capture_output=True, timeout=5)
    assert result.returncode == 0 and result.stdout == result.stderr == b"", result
    assert log.read_text().splitlines() == [
        "non-submission-worker-started", "non-submission-worker-started",
        "submission-start", "worker-not-started", "non-submission-worker-started", "submission-start-end",
        "non-submission-worker-started", "submission-start", "worker-not-started", "submission-start-end"], log.read_text()
    print("terminal fixture startup selector: unscoped/concurrent starts forwarded, scoped EAGAIN and reset passed", flush=True)

    for fault in ("configure-admitted", "configure-presentation", "configure-rejected", "configure-canonical"):
        for shape in ("coalesced", "split-writev"):
            log = state / f"forward-{fault}-{shape}.log"
            env["RUI_TERMINAL_PROBE"] = str(log)
            env["RUI_TERMINAL_FAULT"] = fault
            result = subprocess.run([str(executable), "command-marker", shape], env=env,
                capture_output=True, timeout=5)
            assert result.returncode == 0, (fault, shape, result.returncode, result.stdout, result.stderr)
            assert log.read_text().splitlines() == ["command-return-signal"], (fault, shape)
    print("terminal fixture command markers: four selectors, coalesced/split writev, line boundaries and one signal passed", flush=True)

    negative_root = state / "forward-contention-negatives"
    negative_root.mkdir(mode=0o700)
    arm, release, log = (negative_root / name for name in ("arm", "release", "probe.log"))
    arm.touch()
    release.touch()
    env = {**os.environ,
        os_semantics.PRELOAD: str(library),
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
        dispose_all(release.touch, lambda: stop_process(caller, timeout=5))


def secret_entry_restore_case(state, library):
    """An OpenAI key typed at the hidden prompt is refused, not saved, when
    the terminal's own settings cannot be restored afterwards."""
    root = state / "secret-entry-restore"
    root.mkdir()
    home = root / "home"
    home.mkdir(mode=0o700)
    log = root / "probe.log"
    env = {key: value for key, value in os.environ.items() if key != "RUI_OPENAI_KEY_FILE"}
    master, slave = open_pty()
    try:
        caller = spawn([str(fixture.RUI), "auth", "login", "openai"], stdin=slave, stdout=slave,
            stderr=subprocess.PIPE, env={**env, "HOME": str(home), os_semantics.PRELOAD: str(library),
                                         "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": "restore"})
        shown, deadline = b"", time.monotonic() + 10
        while b"(it is not shown): " not in shown:
            assert time.monotonic() < deadline and caller.poll() is None, shown
            if select.select([master], [], [], 0.1)[0]:
                shown += os.read(master, 4096)
        os.write(master, b"sk-refused\r")
        assert caller.wait(timeout=10) == 1, "a key was accepted with the terminal unrestored"
        errors = caller.stderr.read().decode()
        assert "[internal_unexpected]" in errors, errors
        assert "restore-flush" in log.read_text(), log.read_text()
        assert not (home / ".config" / "rui" / "openai.key").exists(), "a key was saved with the terminal unrestored"
    finally:
        close_pty(master)
        close_pty(slave)
    print("secret entry restore passed: an unrestored terminal refuses the typed key and saves nothing")


def consent_boundary_cases(state):
    """At the permission card, Ctrl-C quits with the terminal usable and
    nothing decided, a paste decides nothing, and a fresh Allow or Deny
    decides. Authorization starts when the card draws its request (decided
    2026-11-09: no flush receipt, no per-key spending)."""
    for case in ("cancel", "paste", "allow"):
        root = state / f"consent-{case}"
        root.mkdir()
        home, store = root / "home", root / "store"
        home.mkdir(mode=0o700)
        endpoint = fixture.SuccessEndpoint([
            fixture.sse_tool_calls("consent-call", [("bash", "consent-id",
                json.dumps({"cmd": "printf forbidden > effect", "timeout_ms": None, "description": "Write consent effect marker"}))]),
            fixture.sse_answer("consent-answer", "consent-reason", "consent-message",
                "Allowed." if case == "allow" else "Denied.")[0],
        ])
        thread = threading.Thread(target=endpoint.serve_forever)
        thread.start()
        host = caller = None
        master, slave = open_pty()
        original = termios.tcgetattr(slave)
        read_ready, write_ready = os.pipe()
        try:
            host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
            session = human.admit(home, "session", "configure", "--store", store,
                "--workspace", root, "--provider", "codex", "--model", "gpt-6-sol", "--permission-mode", "ask")["admission"]["answer"]["session"]
            caller = spawn([str(fixture.RUI), "session", "resume", "--store", str(store),
                "--", session], stdin=slave, stdout=slave, stderr=subprocess.PIPE,
                env={**os.environ, "HOME": str(home), "NO_COLOR": "1",
                    "RUI_TEST_ACTION_READY_FD": str(write_ready)}, pass_fds=(write_ready,))
            human.read_terminal(master, "› ")
            records = home / ".config/rui/requests"
            os.write(master, b"propose command\r")
            human.read_terminal(master, human.CHOICE)
            human.action_ready(read_ready, master)
            before = set(records.glob("*.json"))
            if case == "paste":
                # A paste, even one holding an Enter, is never a decision.
                os.write(master, b"\x1b[200~\r\x1b[201~")
                human.settle_screen(master, quiet=0.5)
                assert set(records.glob("*.json")) == before, "paste at the card captured a decision"
                assert not (root / "effect").exists(), "paste at the card ran Bash"
            if case == "cancel":
                os.write(master, b"\x03")
            else:
                os.write(master, human.ALLOW if case == "allow" else b"\x1b[C" + human.ALLOW)
                human.read_terminal(master, "Allowed." if case == "allow" else "■ Write consent effect marker — Denied")
                assert len(set(records.glob("*.json")) - before) == 1, "the fresh choice was not captured once"
                os.write(master, b"\x03")
            output, errors = human.terminal_exit(caller, master)
            assert caller.wait(timeout=5) == 0, (output, errors)
            actual = termios.tcgetattr(slave)
            assert os_semantics.user_termios(actual) == os_semantics.user_termios(original)
            if case == "allow":
                assert (root / "effect").read_bytes() == b"forbidden", "fresh Allow was swallowed"
            else:
                assert not (root / "effect").exists(), "cancelled or denied input ran Bash"
            if case == "cancel":
                assert set(records.glob("*.json")) == before, "cancel captured permission"
            print(f"persistent consent card: {case} passed", flush=True)
        finally:
            if sys.exc_info()[0] is not None:
                preserve_failure_metadata(root / "pty-failure.json", lambda: {
                    "case": case, "error": sys.exc_info()[0].__name__,
                    "caller_returncode": caller.poll() if caller is not None else None,
                    "ready_pending": bool(select.select([read_ready], [], [], 0)[0]),
                    "terminal_pending": bool(select.select([master], [], [], 0)[0]),
                })
            dispose_all(
                lambda: stop_process(caller, timeout=5) if caller is not None else None,
                lambda: fixture.stop_host(host) if host is not None else None,
                endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
                lambda: termios.tcflush(slave, termios.TCOFLUSH),
                lambda: termios.tcflush(slave, termios.TCIFLUSH),
                lambda: termios.tcsetattr(slave, termios.TCSANOW, original),
                *(lambda fd=fd: close_pty(fd) for fd in (master, slave, read_ready, write_ready)),
            )


def unread_input(slave):
    """Bytes written to the terminal that the caller has not read yet."""
    return struct.unpack("i", fcntl.ioctl(slave, termios.FIONREAD, b"\0" * 4))[0]


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
        session = human.admit(home, "session", "configure", "--store", store,
            "--workspace", root, "--provider", "codex", "--model", "gpt-6-sol")["admission"]["answer"]["session"]
        missing_session = "000000" if session != "000000" else "000001"
        diagnostics = [
            (["session", "resume", "--store", str(store), missing_session], b"[internal_unexpected]"),
            (["defaults", "configure", "--provider", "unsupported"], b"[choice_unsupported]"),
            (["--store", str(store), "--provider", "unsupported", "--model", "gpt-6-sol"], b"[choice_unsupported]"),
        ]
        for args, error, stopped in ((args, error, stopped) for args, error in diagnostics for stopped in (False, True)):
            master, slave = open_pty()
            error_master, error_slave = open_pty()
            original = termios.tcgetattr(slave)
            error_flags = fcntl.fcntl(error_slave, fcntl.F_GETFL)
            try:
                if stopped:
                    termios.tcflow(error_slave, termios.TCOOFF)
                caller = spawn([str(fixture.RUI), *args],
                    env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave, stderr=error_slave)
                assert caller.wait(timeout=3) == (2 if error == b"[choice_unsupported]" else 1), "fatal diagnostic did not exit"
                assert termios.tcgetattr(slave) == original
                assert_file_flags(fcntl.fcntl(error_slave, fcntl.F_GETFL), error_flags)
                if not stopped:
                    assert select.select([error_master], [], [], 1)[0]
                    assert error in os.read(error_master, 65536)
                print(f"fatal reporting: {error.decode()} stopped stderr={stopped} passed", flush=True)
            finally:
                dispose_all(
                    lambda: stop_process(caller, timeout=5) if caller is not None else None,
                    lambda: termios.tcflow(error_slave, termios.TCOON),
                    *(lambda fd=fd: close_pty(fd) for fd in (master, slave, error_master, error_slave)),
                )
        # Popen restores default SIGPIPE before exec. Rui's initialized IO
        # runtime must still preserve the real error when stderr disconnects.
        for args, error in diagnostics:
            master, slave = open_pty()
            read_error, write_error = os.pipe()
            os.close(read_error)
            original = termios.tcgetattr(slave)
            error_flags = fcntl.fcntl(write_error, fcntl.F_GETFL)
            try:
                caller = spawn([str(fixture.RUI), *args],
                    env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave, stderr=write_error)
                assert caller.wait(timeout=3) == (2 if error == b"[choice_unsupported]" else 1), "disconnected stderr replaced the real exit"
                assert termios.tcgetattr(slave) == original
                assert_file_flags(fcntl.fcntl(write_error, fcntl.F_GETFL), error_flags)
                print(f"fatal reporting: {error.decode()} disconnected stderr passed", flush=True)
            finally:
                dispose_all(
                    lambda: stop_process(caller, timeout=5) if caller is not None else None,
                    *(lambda fd=fd: close_pty(fd) for fd in (master, slave, write_error)),
                )
    finally:
        dispose_all(
            lambda: proxy.close() if proxy is not None else None,
            lambda: fixture.stop_host(host) if host is not None else None,
            endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
        )


def decision_reporting_cases(state):
    """A decision still unconfirmed when the conversation ends keeps its exact
    identity: Ctrl-C, SIGHUP and a closed terminal (EOF, the same hangup) each
    exit naming its recovery, and the Host, still running, continues it."""
    root = state / "decision-reporting"
    root.mkdir()
    home, store = root / "home", root / "store"
    home.mkdir(mode=0o700)
    cases = [(decision, ending) for decision in ("allow_once", "deny") for ending in ("interrupt", "sighup", "closed")]
    responses = []
    for decision, ending in cases:
        name = f"{decision}-{ending}"
        responses.extend([
            fixture.sse_tool_calls(name, [("bash", name, json.dumps({"cmd": f"printf once >> effect-{name}", "timeout_ms": 1000, "description": f"Append effect-{name} marker"}))]),
            fixture.sse_answer(f"{name}-a", f"{name}-r", f"{name}-m", f"SETTLED-{name}")[0],
        ])
    endpoint = fixture.SuccessEndpoint(responses)
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = caller = proxy = None
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        for decision, ending in cases:
            name = f"{decision}-{ending}"
            session = human.admit(home, "session", "configure", "--store", store,
                "--workspace", root, "--provider", "codex", "--model", "gpt-6-sol", "--permission-mode", "ask")["admission"]["answer"]["session"]
            before = {path: path.read_bytes() for path in (home / ".config/rui/requests").glob("*.json")}
            master, slave = open_pty()
            read_ready, write_ready = os.pipe()
            original = termios.tcgetattr(slave)
            reply_release, received = threading.Event(), threading.Event()
            try:
                caller = spawn([str(fixture.RUI), "session", "resume", "--store", str(store), session],
                    env={**os.environ, "HOME": str(home), "RUI_TEST_ACTION_READY_FD": str(write_ready)},
                    pass_fds=(write_ready,), stdin=slave, stdout=slave, stderr=subprocess.PIPE)
                human.read_terminal(master, "› ")

                def hold(response):
                    received.set()
                    assert reply_release.wait(15)
                    return b""
                proxy = canonical.ReplyProxy(host, "/v1/control/permission-decision", hold)
                os.write(master, b"propose exact decision\r")
                proposal = human.read_terminal(master, human.CHOICE)
                proposal += human.action_ready(read_ready, master)
                if decision != "allow_once":
                    human.pick_deny(master)
                os.write(master, human.ALLOW)
                fixture.wait_for(human.draining(master, received.is_set), "permission decision route reached", timeout=10)
                if ending == "closed":
                    # The terminal went away: no restoration is claimed.
                    close_pty(master)
                    master = None
                    _, errors = caller.communicate(timeout=6)
                else:
                    caller.send_signal(signal.SIGINT if ending == "interrupt" else signal.SIGHUP)
                    output, errors = human.terminal_exit(caller, master, timeout=6)
                assert caller.returncode == 0, (ending, errors)
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
                assert b"rui request recover " + request["key"].encode() in errors, errors
                assert b"rui request read-result" not in errors, errors
                assert b"Decision not confirmed" in errors, errors
                assert proxy.exchanges[0][0] == saved and not reply_release.is_set()
                reply_release.set()
                proxy.close()
                proxy = None
                recovered = json.loads(human.run(home, "request", "recover", request["key"]))["answer"]
                assert recovered["status"] == "accepted" and recovered["replayed"] is True, recovered
                assert record.read_bytes() == saved
                fixture.wait_for(lambda: fixture.completed_observation(store, message["key"]), "decision continuation")
                effect = root / f"effect-{name}"
                assert (effect.read_bytes() if effect.exists() else b"") == (b"once" if decision == "allow_once" else b"")
                if ending != "closed":
                    actual = termios.tcgetattr(slave)
                    assert os_semantics.user_termios(actual) == os_semantics.user_termios(original)
                print(f"decision reporting: {name} passed", flush=True)
            finally:
                if sys.exc_info()[0] is not None:
                    preserve_failure_metadata(root / "pty-failure.json", lambda: {
                        "case": name, "error": sys.exc_info()[0].__name__,
                        "caller_returncode": caller.poll() if caller is not None else None,
                        "ready_pending": bool(select.select([read_ready], [], [], 0)[0]),
                        "terminal_pending": master is not None and bool(select.select([master], [], [], 0)[0]),
                        "reply_released": reply_release.is_set(),
                        "exchanges": len(proxy.exchanges) if proxy is not None else 0,
                    })
                dispose_all(
                    reply_release.set,
                    lambda: stop_process(caller, timeout=5) if caller is not None else None,
                    lambda: proxy.close() if proxy is not None else None,
                    *(lambda fd=fd: close_pty(fd) for fd in (master, slave, read_ready, write_ready) if fd is not None),
                )
                proxy = None
    finally:
        dispose_all(
            lambda: fixture.stop_host(host) if host is not None else None,
            endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
        )


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
                os_semantics.PRELOAD: str(library),
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
        assert status.returncode == 0, status
        reported = json.loads(status.stdout)
        assert reported["type"] == "host_status" and reported["status"] == "ready" and reported["instance"], status
        (root / "host-status.stdout").write_text(status.stdout)
        print("Host diagnostics: aliased full stdout, startup warning and failed restore: required readiness blocks until exact filler release; Host usable", flush=True)
    finally:
        def save_output():
            os.set_blocking(read_fd, False)
            while True:
                try:
                    chunk = os.read(read_fd, 65536)
                except BlockingIOError:
                    break
                if not chunk: break
                output.extend(chunk)
            (root / "stdout-stderr.log").write_bytes(output)

        dispose_all(lambda: stop_process(host, timeout=8) if host is not None else None,
                    save_output, lambda: os.close(read_fd), lambda: os.close(write_fd))
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
        assert status.returncode == 0, status
        reported = json.loads(status.stdout)
        assert reported["type"] == "host_status" and reported["status"] == "ready" and reported["instance"], status
        print("Host diagnostics: record-time failure retained under exclusion; one notice follows required readiness; Host usable", flush=True)
    finally:
        dispose_all(lambda: (root / "stdout-stderr.log").write_bytes(output),
                    lambda: fixture.stop_host(host) if host is not None else None)
    for kind in ("readiness-held", "readiness-held-error"):
        root = state / kind
        root.mkdir(mode=0o700)
        store, log, release = (root / name for name in ("store", "probe.log", "release"))
        # Save queued work without an execution adapter, then restart it under
        # the native readiness gate. No live raw Store reads or new hooks.
        seed = fixture.start_host(store, None)
        try:
            session = fixture.configure(root, store, "config", None, "gpt-6-sol")
            fixture.message(root, store, "queued", session, "READY-ANSWER")
        finally:
            fixture.stop_host(seed)
        endpoint = fixture.SuccessEndpoint([
            fixture.sse_answer("ready-a", "ready-r", "ready-m", "READY-ANSWER")[0]])
        server = threading.Thread(target=endpoint.serve_forever)
        server.start()
        result = []
        env = {**os.environ,
            os_semantics.PRELOAD: str(library),
            "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": kind,
            "RUI_DIAGNOSTIC_RELEASE": str(release)}

        def start():
            try:
                result.append(start_ready_process(fixture.host_arguments(store,
                    f"http://127.0.0.1:{endpoint.server_port}/responses", "--test-phase-trace"),
                    env=env, required_fields={"execution": "enabled", "nghttp2": "1.70.0"}))
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
            def retire_started_host():
                nonlocal host
                if host is None and result and isinstance(result[0], tuple): host = result[0][0]
                if host is not None: fixture.stop_host(host)

            def join_server():
                server.join(timeout=5)
                assert not server.is_alive() and not starter.is_alive()

            dispose_all(release.touch, lambda: starter.join(timeout=10), retire_started_host,
                        endpoint.shutdown, endpoint.server_close, join_server)
    for kind in ("readiness-alias", "readiness-error"):
        root = state / kind
        root.mkdir(mode=0o700)
        log = root / "probe.log"
        env = {**os.environ,
            os_semantics.PRELOAD: str(library),
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
                session = fixture.configure(root, root / "store", "alias-config", None, "gpt-6-sol")
                assert fixture.command("session", "inspect", "--store", root / "store", "--session", session)["session"]
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
        ("diagnostic-contention-host", "response-acquire"),
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
        host = None
        inspectors = []
        contention_complete = False
        env = {**os.environ,
            os_semantics.PRELOAD: str(library),
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
                *(["--test-phase-trace"] if fault == "success" or credit in ("diagnostic-contention-host", "diagnostic-partial") else [])), env=env, stderr_pipe=(reader, write_fd),
                observations="control" if credit == "diagnostic-contention-host" else None,
                required_fields={"execution": "enabled", "nghttp2": "1.70.0"})
            session = fixture.configure(root, store, "config", None, "gpt-6-sol")
            if credit == "diagnostic-contention-host":
                other_session = fixture.configure(root, store, "config-other", None, "gpt-6-sol")
                contention_inspections = [other_session, session, session]
            status = subprocess.run([str(fixture.RUI), "host", "status", "--store", str(store)],
                capture_output=True, text=True, timeout=8)
            assert status.returncode == 0, status
            reported = json.loads(status.stdout)
            assert reported["type"] == "host_status" and reported["status"] == "ready", status
            instance = reported["instance"]
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
                    dispose_all(lambda: fcntl.fcntl(write_fd, fcntl.F_SETFL, flags))
                assert filled > 0
            if credit == "closed":
                reader.close()
            contention_deadline = time.monotonic() + 8 if credit == "diagnostic-contention-host" else None
            if credit.startswith("diagnostic-"):
                arm.touch()
            if credit == "diagnostic-partial":
                fixture.command("session", "inspect", "--store", store, "--session", session)
                # The Host writes the inspection's trace beside its reply, so
                # the reply can arrive first.
                fixture.wait_for(lambda: "diagnostic-partial\n" in log.read_text(), "the armed partial trace write")
                arm.unlink()
            if credit == "diagnostic-contention-host":
                # The forwarding driver proves the exact inspection matcher.
                # Here unrelated optional custody cannot gate canonical reads.
                def control_remaining():
                    remaining = contention_deadline - time.monotonic()
                    assert remaining > 0, "contention exceeded original 8s deadline"
                    return min(3, remaining)

                fixture.wait_for(lambda: log.exists() and "diagnostic-held-lifecycle\n" in log.read_text(),
                    "native lifecycle fd2 held", deadline=contention_deadline)
                captured = [json.loads(line) for line in log.read_text().splitlines() if line.startswith("{")]
                assert len(captured) == 1, captured
                held = captured[0]
                assert held["rui_test_phase"] == "lifecycle_boundary", held
                assert held["process"] == str(host.pid) and int(held["run"]) > 0 and int(held["sequence"]) > 0 and held["clock"] == "awake_ns", held
                status = subprocess.run([str(fixture.RUI), "host", "status", "--store", str(store)],
                    capture_output=True, text=True, timeout=control_remaining())
                assert status.returncode == 0, status
                unrelated = fixture.start_command("session", "inspect", "--store", store, "--session", other_session)
                inspectors.append(unrelated)
                out, err = unrelated.communicate(timeout=control_remaining())
                assert unrelated.returncode == 0 and json.loads(out)["session"]["reference"] == other_session, (out, err)
                pending = fixture.start_command("session", "inspect", "--store", store, "--session", session)
                inspectors.append(pending)
                native = host.rui_observations
                inspection = fixture.wait_for(lambda: next((record for record in native.snapshot()["records"]
                    if record["rui_test_phase"] == "inspection_captured" and record.get("subject_kind") == "session" and record.get("subject") == session), None),
                    "exact native capture under optional contention", deadline=contention_deadline)
                assert inspection["process"] == held["process"] and inspection["run"] == held["run"], inspection
                out, err = pending.communicate(timeout=control_remaining())
                reply = json.loads(out)
                assert pending.returncode == 0 and reply["type"] == "session_report" and reply["profile"] == "current" and reply["session"]["reference"] == session, (out, err)
                concurrent = fixture.start_command("session", "inspect", "--store", store, "--session", session)
                inspectors.append(concurrent)
                out, err = concurrent.communicate(timeout=control_remaining())
                assert concurrent.returncode == 0 and json.loads(out)["session"]["reference"] == session, (out, err)
                assert time.monotonic() < contention_deadline and not release.exists() and host.poll() is None
                assert log.read_text().count("diagnostic-held-lifecycle\n") == 1 and "diagnostic-held-inspection\n" not in log.read_text()
                prefix = fixture.wait_for(lambda: (value if len((value := native.snapshot())["records"]) >= 4 else None),
                    "complete held inspection population", deadline=contention_deadline)["records"]
                assert [(record["rui_test_phase"], record.get("subject")) for record in prefix] == [
                    ("lifecycle_boundary", None),
                    *[("inspection_captured", subject) for subject in contention_inspections]], prefix
                preserve_failure_metadata(root / "contention-capture.json", lambda: {
                    "held": held, "inspection": inspection, "reply": reply,
                    "remaining_seconds": contention_deadline - time.monotonic(), "native": native.snapshot()})
                release.touch()
                fixture.wait_for(lambda: "diagnostic-restored\n" in log.read_text().split("diagnostic-held-lifecycle\n", 1)[1],
                    "held native write restored flags", deadline=contention_deadline)
                arm.unlink()
            for index in range(count):
                key = f"message-{index}"
                # The original regression payload: exactly 156000 decoded bytes.
                text = 'é中🙂\n\\"/' * 12000
                assert len(text.encode()) == 156000
                fixture.message(root, store, key, session, text)
                retirement_deadline = time.monotonic() + 8
                if fault == "response-commit":
                    fixture.wait_for(lambda: host.poll() is not None, "canonical fence exits")
                    assert host.returncode != 0
                    with sqlite3.connect(f"file:{store / 'rui.sqlite3'}?mode=ro", uri=True) as database:
                        assert database.execute("SELECT (resolution_code IS NULL AND retry_due_at_ms IS 0),resolution_code FROM model_operation").fetchone() == (1, None)
                        assert database.execute("SELECT count(*) FROM model_output_item").fetchone() == (0,)
                    break
                if fault == "response-unlink":
                    resources = fixture.wait_for(lambda: (value if (value := fixture.command(
                        "session", "inspect", "--store", store, "--session", session,
                        timeout=max(0, retirement_deadline - time.monotonic()))["execution"])["dispatch_fenced"]
                        and value["custody_occupied"] == "1" and value["scratch_used_bytes"] == "0" else None),
                        "retained response cleanup", deadline=retirement_deadline)
                    assert resources["custody_occupied"] == "1", resources
                    leftovers = list((store / "scratch").glob("response-[0-9]*.tmp"))
                    assert len(leftovers) == 1, leftovers
                    # This existing acquisition fault retains an empty named
                    # file before provider launch, so its correct charge is 0.
                    assert int(resources["scratch_used_bytes"]) == leftovers[0].stat().st_size == 0, resources
                    assert not endpoint.requests, endpoint.requests
                    # Retained cleanup keeps the lease, so pause waits out its
                    # whole retirement bound and reports it unconfirmed.
                    stopped = subprocess.run([str(fixture.RUI), "host", "pause", "--store", str(store), "--instance", instance],
                        capture_output=True, text=True, timeout=30)
                    (root / "host-stop.stdout").write_text(stopped.stdout)
                    (root / "host-stop.stderr").write_text(stopped.stderr)
                    assert stopped.returncode == 0, stopped
                    stop_reply = json.loads(stopped.stdout)
                    assert {key: stop_reply[key] for key in ("type", "status", "instance", "retirement")} == {
                        "type": "host_pause", "status": "acknowledged", "instance": instance, "retirement": "unconfirmed"}, stopped
                    assert "pause interrupts all work in this Store" in stopped.stderr, stopped
                    assert f"still holds this Store after {DEFAULTS.host_shutdown_seconds} seconds" in stopped.stderr, stopped
                    print(f"Host diagnostics: retained response file, charge=0, custody=1; stop reply={stopped.stdout!r}", flush=True)
                    # A stop acknowledgement is not cleanup completion: the
                    # injected unlink refusal remains active during shutdown.
                    assert host.poll() is None, "stop falsely completed retained cleanup"
                    (root / "retained-resources.json").write_text(json.dumps(resources, indent=2) + "\n")
                    host.kill()
                    assert host.wait(timeout=8) == -signal.SIGKILL
                    assert leftovers[0].exists()
                    with sqlite3.connect(f"file:{store / 'rui.sqlite3'}?mode=ro", uri=True) as database:
                        assert database.execute("SELECT (resolution_code IS NULL AND retry_due_at_ms IS 0),resolution_code FROM model_operation").fetchone() == (1, None)
                        assert database.execute("SELECT count(*) FROM model_output_item").fetchone() == (0,)
                    fresh = fixture.start_host(store, None)
                    try:
                        assert not leftovers[0].exists()
                        clean = fixture.command("session", "inspect", "--store", store, "--session", session)["execution"]
                        assert clean["scratch_used_bytes"] == "0", clean
                        (root / "fresh-resources.json").write_text(json.dumps(clean, indent=2) + "\n")
                    finally:
                        fixture.stop_host(fresh)
                    break
                def diagnostic_resources(remaining):
                    if credit == "diagnostic-contention-host":
                        contention_inspections.append(session)
                    return fixture.command("session", "inspect", "--store", store, "--session", session,
                        timeout=remaining)["execution"]

                observation, saved_answer, resources = fixture.wait_for_result_release(
                    store, key, session, retirement_deadline, inspect=diagnostic_resources)
                if fault == "success":
                    assert observation["result"]["status"] == "completed", observation
                    assert saved_answer == b"ANSWER"
                else:
                    expected = {"response-acquire": "response_capture_failed", "response-metadata": "response_metadata_failed",
                        "response-write": "response_write_failed"}[fault]
                    assert observation["result"]["code"] == expected, observation
                if credit == "diagnostic-contention-host":
                    population = fixture.wait_for(lambda: (value if len((value := native.snapshot())["records"]) >= len(contention_inspections) + 2 else None),
                        "complete contention owner population", deadline=retirement_deadline)["records"]
                    assert Counter(record["rui_test_phase"] for record in population) == {
                        "lifecycle_boundary": 1, "inspection_captured": len(contention_inspections), "cleanup_completed": 1}, population
                    assert Counter(record.get("subject") for record in population if record["rui_test_phase"] == "inspection_captured") == Counter(contention_inspections), population
                    cleanup = [record for record in population if record["rui_test_phase"] == "cleanup_completed"]
                    assert [(record["turn"], record["operation"], record["attempt"]) for record in cleanup] == [("1", "1", "1")], cleanup
                    contention_complete = True
                if index == 0 and credit in ("diagnostic-enable", "diagnostic-enable-unmutated"):
                    arm.unlink()
            # A trace reaches the observation channel before its borrowed
            # stderr write restores the flags, so wait for the restoration.
            expected_flags = flags | os.O_NONBLOCK if credit.startswith("diagnostic-restore") else flags
            restored = fixture.wait_for(lambda: fcntl.fcntl(write_fd, fcntl.F_GETFL), "stderr flags restored after the last trace",
                ready=lambda actual: os_semantics.user_file_flags(actual) == os_semantics.user_file_flags(expected_flags))
            assert_file_flags(restored, expected_flags)
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
            if credit in ("diagnostic-contention-host", "diagnostic-partial"):
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
                if credit == "diagnostic-contention-host":
                    assert not any(record.get("at_ns") == inspection["at_ns"] and record.get("subject") == session for record in records), "dropped inspection was retried"
            warnings = [line for line in errors.splitlines() if line.startswith(b"rui:")]
            print(f"Host diagnostics: {credit}/{fault}: public outcome checked, flags checked; warnings={warnings!r}", flush=True)
        finally:
            incoming_error = sys.exc_info()[1]
            cleanup_errors = []
            if host is not None and credit == "diagnostic-contention-host":
                preserve_failure_metadata(root / "contention-pre-kill.json", host.rui_observations.snapshot)
            try:
                release.touch()
            except Exception as error:
                cleanup_errors.append(error)
            inspector_deadline = time.monotonic() + 5
            for inspector in inspectors:
                try:
                    stop_process(inspector, timeout=max(0, inspector_deadline - time.monotonic()))
                except Exception as error:
                    cleanup_errors.append(error)
            try:
                if host is not None:
                    try:
                        # This is disposal, not a semantic crash cut. The
                        # canonical owner seals/drains before kill within the
                        # same eight seconds; stderr assertions ran above.
                        stop_process(host, timeout=8)
                    except Exception as error:
                        cleanup_errors.append(error)
                    if credit == "diagnostic-contention-host":
                        preserve_failure_metadata(root / "contention-final.json", lambda: {
                            "returncode": host.returncode, "state": host.rui_observations.final_state,
                            "records": host.rui_observations.records})
                        if contention_complete:
                            try:
                                assert host.returncode == -signal.SIGKILL
                            except Exception as error:
                                cleanup_errors.append(error)
                            try:
                                assert host.rui_observations.records == population, "native population changed after complete census"
                            except Exception as error:
                                cleanup_errors.append(error)
                elif not reader.closed: reader.close()
            except Exception as error:
                cleanup_errors.append(error)
            finally:
                try:
                    os.close(write_fd)
                except Exception as error:
                    cleanup_errors.append(error)
                try:
                    endpoint.shutdown()
                except Exception as error:
                    cleanup_errors.append(error)
                try:
                    endpoint.server_close()
                except Exception as error:
                    cleanup_errors.append(error)
                try:
                    thread.join(timeout=5)
                    assert not thread.is_alive()
                except Exception as error:
                    cleanup_errors.append(error)
            if cleanup_errors:
                preserve_failure_metadata(root / "contention-cleanup.json", lambda: {
                    "original_error": type(incoming_error).__name__ if incoming_error else None,
                    "cleanup_errors": [cleanup_failure(error) for error in cleanup_errors]})
                if incoming_error is None:
                    raise cleanup_errors[0]
                try:
                    incoming_error.add_note("Fixture diagnostic cleanup failed: " + ", ".join(cleanup_failure(error) for error in cleanup_errors))
                except BaseException:
                    pass  # Optional reporting cannot replace the original failure.


def app_terminal_cases():
    binary = pathlib.Path(os.environ["RUI_TEST_TERMINAL_NOTICE"]).resolve()
    master, slave = open_pty()
    caller = None
    original = termios.tcgetattr(slave)
    try:
        caller = spawn([str(binary), "app-init-oom"], stdin=slave,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        output, diagnostic = caller.communicate(timeout=5)
        assert caller.returncode == 0, (caller.returncode, diagnostic)
        assert output == b"", output
        assert diagnostic == b"App.init: OutOfMemory\n", diagnostic
        assert termios.tcgetattr(slave) == original, "App left terminal settings changed"
        print("App.init OutOfMemory: terminal restored and process exited", flush=True)
    finally:
        dispose_all(lambda: stop_process(caller, timeout=5) if caller is not None else None,
                    lambda: close_pty(master), lambda: close_pty(slave))


def app_signal_cases():
    binary = pathlib.Path(os.environ["RUI_TEST_TERMINAL_NOTICE"]).resolve()
    # "late": the shell's hangup reaches Rui only after App released the
    # terminal, which then exits as it would have without it.
    for sent in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, *([None] * 8), "late"):
        master, slave = open_pty()
        caller = None
        original = termios.tcgetattr(slave)
        try:
            caller = spawn([str(binary), "app-late-hangup" if sent == "late" else "app-signal"], stdin=slave,
                           stdout=slave, stderr=subprocess.PIPE)
            opening = bytearray()
            answered = False

            def frame_drawn():
                nonlocal answered
                if select.select([master], [], [], 0)[0]:
                    opening.extend(os.read(master, 65536))
                    assert len(opening) < 1024 * 1024, "unbounded App startup output"
                if not answered and b"\x1b[c" in opening:
                    os.write(master, b"\x1b[?1;2c")
                    answered = True
                return b"fixture" in opening and b"\x1b[?2026l" in opening

            try:
                fixture.wait_for(frame_drawn, "App's first frame", timeout=5)
            except BaseException as error:
                error.add_note(f"App startup bytes: {bytes(opening)!r}; exit: {caller.poll()}")
                raise
            assert not termios.tcgetattr(slave)[3] & termios.ICANON
            if sent in (None, "late"):
                close_pty(master)
                master = None
                _, diagnostic = caller.communicate(timeout=5)
                assert caller.returncode == 0, (caller.returncode, diagnostic)
                assert b"EndOfStream" not in diagnostic, diagnostic
                assert b"error reading tty" not in diagnostic, diagnostic
                assert caller.poll() == 0, "App survived terminal hangup"
                print("App closed master: hangup exit; no terminal restoration claimed", flush=True)
                continue
            caller.send_signal(sent)
            output, diagnostic = human.terminal_exit(caller, master)
            assert caller.returncode == 0, (sent, caller.returncode, diagnostic)
            assert diagnostic == b"", diagnostic
            assert termios.tcgetattr(slave) == original, (sent, "terminal not restored")
            for reset in (b"\x1b[?1049l", b"\x1b[?2004l", b"\x1b[?1002;1003;1004;1006;1016l"):
                assert reset in output, (sent, reset, output)
            print(f"App {sent.name}: terminal settings and enabled modes restored", flush=True)
        finally:
            dispose_all(lambda: stop_process(caller, timeout=5) if caller is not None else None,
                        lambda: close_pty(master) if master is not None else None, lambda: close_pty(slave))


def app_full_pty_case():
    binary = pathlib.Path(os.environ["RUI_TEST_TERMINAL_NOTICE"]).resolve()
    master, slave = open_pty()
    caller = None
    original = termios.tcgetattr(slave)
    flags = fcntl.fcntl(slave, fcntl.F_GETFL)
    try:
        caller = spawn([str(binary), "app-signal"], stdin=slave,
                       stdout=slave, stderr=subprocess.PIPE)
        opening = bytearray()
        answered = False

        def frame_drawn():
            nonlocal answered
            if select.select([master], [], [], 0)[0]:
                opening.extend(os.read(master, 65536))
                assert len(opening) < 1024 * 1024, "unbounded App startup output"
            if not answered and b"\x1b[c" in opening:
                os.write(master, b"\x1b[?1;2c")
                answered = True
            return b"fixture" in opening and b"\x1b[?2026l" in opening

        fixture.wait_for(frame_drawn, "App's first frame", timeout=5)
        filled = 0
        fcntl.fcntl(slave, fcntl.F_SETFL, flags | os.O_NONBLOCK)
        try:
            while True:
                try:
                    filled += os.write(slave, b"x" * 1024)
                    assert filled < 1024 * 1024, "unbounded fixture output"
                except BlockingIOError:
                    break
        finally:
            fcntl.fcntl(slave, fcntl.F_SETFL, flags)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        caller.send_signal(signal.SIGWINCH)
        caller.send_signal(signal.SIGTERM)
        # Simulate a terminal that stops reading before it catches up.
        select.select([], [], [], 1)
        _, diagnostic = human.terminal_exit(caller, master)
        assert caller.returncode == 0, (caller.returncode, diagnostic)
        assert os_semantics.user_termios(termios.tcgetattr(slave)) == os_semantics.user_termios(original), "terminal not restored"
        assert_file_flags(fcntl.fcntl(slave, fcntl.F_GETFL), flags)
        print("App full PTY SIGTERM: exited and terminal restored after draining resumed", flush=True)
    finally:
        dispose_all(lambda: stop_process(caller, timeout=5) if caller is not None else None,
                    lambda: close_pty(master), lambda: close_pty(slave))


def app_resize_cases():
    from terminal_screen import ScreenCapture

    binary = pathlib.Path(os.environ["RUI_TEST_TERMINAL_NOTICE"]).resolve()
    for columns, rows in ((0, 1), (1, 0)):
        master, slave = open_pty(columns=columns, rows=rows)
        caller = None
        try:
            caller = spawn([str(binary), "app-resize"], stdin=slave,
                           stdout=slave, stderr=subprocess.PIPE)
            output, diagnostic = bytearray(), bytearray()
            screen = ScreenCapture(columns=80, rows=24)
            answered = False

            def collect():
                nonlocal answered
                ready = select.select([master, caller.stderr], [], [], 0)[0]
                if master in ready:
                    chunk = os.read(master, 65536)
                    output.extend(chunk)
                    screen.feed(chunk)
                if caller.stderr in ready:
                    diagnostic.extend(os.read(caller.stderr.fileno(), 65536))
                assert len(output) + len(diagnostic) < 1024 * 1024
                assert caller.poll() is None, (caller.returncode, bytes(diagnostic))
                if not answered and b"\x1b[c" in output:
                    os.write(master, b"\x1b[?1;2c")
                    answered = True

            def empty_drawn():
                collect()
                return f"empty={columns}x{rows}\n".encode() in diagnostic

            fixture.wait_for(empty_drawn, "App draws an empty terminal without exiting", timeout=5)
            output.clear()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
            caller.send_signal(signal.SIGWINCH)

            def positive_drawn():
                collect()
                return "App resize restored" in screen.completed

            fixture.wait_for(positive_drawn, "App redraws after a nonzero resize", timeout=5)
            os.write(master, b"\r")
            _, remaining = human.terminal_exit(caller, master)
            assert caller.returncode == 0, (caller.returncode, remaining)
            assert remaining == b"", remaining
            assert diagnostic == f"empty={columns}x{rows}\n".encode(), diagnostic
            restored = termios.tcgetattr(slave)[3]
            assert restored & termios.ICANON and restored & termios.ECHO
            print(f"App {columns}x{rows} → 80x24: redrawn, input accepted, terminal usable", flush=True)
        finally:
            dispose_all(lambda: stop_process(caller, timeout=5) if caller is not None else None,
                        lambda: close_pty(master), lambda: close_pty(slave))


def app_consent_cases():
    binary = pathlib.Path(os.environ["RUI_TEST_TERMINAL_NOTICE"]).resolve()
    for replaced, keys, expected in (
        (True, b"\r", b"decision=none\n"),
        (False, b"\r", b"decision=17:allow_once\n"),
        (False, b"\x1b[13;0u", b"decision=none\n"),
    ):
        master, slave = open_pty()
        ready_read, ready_write = os.pipe()
        caller = None
        try:
            caller = spawn([str(binary), "consent-replaced" if replaced else "consent-live"],
                           stdin=slave, stdout=slave, stderr=subprocess.PIPE,
                           pass_fds=(ready_write,),
                           env={**os.environ, "RUI_TEST_ACTION_READY_FD": str(ready_write)})
            opening = bytearray()
            answered = 0

            def enter_sent():
                nonlocal answered
                if select.select([master], [], [], 0)[0]:
                    opening.extend(os.read(master, 65536))
                    assert len(opening) < 1024 * 1024, "unbounded consent fixture output"
                while opening.count(b"\x1b[c") > answered:
                    answered += 1
                    os.write(master, b"\x1b[?1;2c")
                if select.select([ready_read], [], [], 0)[0]:
                    assert os.read(ready_read, 1) == b"x"
                    os.write(master, keys)
                    return True
                return False

            fixture.wait_for(enter_sent, "Enter after the card draws its request", timeout=5)
            _, diagnostic = human.terminal_exit(caller, master)
            assert caller.returncode == 0, (replaced, caller.returncode, diagnostic)
            assert diagnostic == expected, (replaced, diagnostic)
            print(f"App consent: request-replaced={replaced}, keys={keys!r}, {diagnostic.decode().strip()}", flush=True)
        finally:
            dispose_all(lambda: stop_process(caller, timeout=5) if caller is not None else None,
                        lambda: close_pty(master), lambda: close_pty(slave),
                        lambda: os.close(ready_read), lambda: os.close(ready_write))


def app_ready_failure_case():
    binary = pathlib.Path(os.environ["RUI_TEST_TERMINAL_NOTICE"]).resolve()
    master, slave = open_pty()
    ready_read, ready_write = os.pipe()
    os.close(ready_read)
    caller = None
    try:
        caller = spawn([str(binary), "consent-live"], stdin=slave, stdout=slave,
                       stderr=subprocess.PIPE, pass_fds=(ready_write,),
                       env={**os.environ, "RUI_TEST_ACTION_READY_FD": str(ready_write)})
        _, diagnostic = human.terminal_exit(caller, master)
        assert caller.returncode == 1, (caller.returncode, diagnostic)
        assert b"error: BrokenPipe" in diagnostic, diagnostic
        assert b"decision=" not in diagnostic, diagnostic
        restored = termios.tcgetattr(slave)[3]
        assert restored & termios.ICANON and restored & termios.ECHO
        print("App readiness write failure: run returned BrokenPipe and terminal is usable", flush=True)
    finally:
        dispose_all(lambda: stop_process(caller, timeout=5) if caller is not None else None,
                    lambda: close_pty(master), lambda: close_pty(slave),
                    lambda: os.close(ready_write))


def main(selected=None):
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-terminal-restoration."))
    home = state / "home"
    home.mkdir()
    store = state / "store"
    host = None
    completed = False
    try:
        if selected in (None, "app-init"):
            app_terminal_cases()
        if selected == "app-init":
            completed = True
            return
        if selected in (None, "app-signals"):
            app_signal_cases()
        if selected == "app-signals":
            completed = True
            return
        if selected in (None, "app-full-pty"):
            app_full_pty_case()
        if selected == "app-full-pty":
            completed = True
            return
        if selected in (None, "app-resize"):
            app_resize_cases()
        if selected == "app-resize":
            completed = True
            return
        if selected in (None, "app-consent"):
            app_consent_cases()
        if selected == "app-consent":
            completed = True
            return
        if selected in (None, "app-ready-error"):
            app_ready_failure_case()
        if selected == "app-ready-error":
            completed = True
            return
        source, library = state / "probe.c", state / "probe.so"
        source.write_text(PROBE)
        subprocess.run(os_semantics.shared_library_command(source, library), check=True)
        check_forwarding(state, library)
        if selected == "forwarding":
            completed = True
            return
        if selected in (None, "stop-receipt"):
            stop_receipt_case(state, library)
        if selected == "stop-receipt":
            completed = True
            return
        if selected in (None, "host-diagnostics"):
            host_diagnostic_cases(state, library)
        if selected == "host-diagnostics":
            completed = True
            return
        if selected in (None, "secret-entry"):
            secret_entry_restore_case(state, library)
        if selected == "secret-entry":
            completed = True
            return
        if selected in (None, "consent"):
            consent_boundary_cases(state)
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
        completed = True
    finally:
        if host is not None:
            fixture.stop_host(host)
        if completed and selected != "host-diagnostics":
            shutil.rmtree(state)
        else:
            retain_failure_state(f"terminal restoration state (completed={completed})", state)
