#!/usr/bin/env python3
"""Real editor handoff, queued input and independently failed cleanup effects."""
import fcntl
import json
import os
import pathlib
import pty
from terminal_process import open_pty
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

import canonical_failure_integration as canonical
import model_fixture as fixture
import human_cli_integration as human
from host_process import HostDiagnostics, HostStartError, ReleaseGate, canonical_fixture_root, cleanup_failure, dispose_all, preserve_failure_metadata, start_ready_process, stop_process


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
#include <signal.h>
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

/* The Session screen writes through a private duplicate of stdout, and
   commands borrow fd 1 for their page. Screen probes match the terminal
   that was fd 1 at load, by identity, rather than the descriptor number. */
static int screen_known = 0;
static dev_t screen_dev;
static ino_t screen_ino;

__attribute__((constructor)) static void screen_identity(void) {
    struct stat st;
    if (isatty(1) && !fstat(1, &st)) {
        screen_dev = st.st_dev;
        screen_ino = st.st_ino;
        screen_known = 1;
    }
}

static int screen_fd(int fd) {
    struct stat st;
    if (fd == 1) return 1;
    if (fd > 2 && screen_known && !fstat(fd, &st) && st.st_dev == screen_dev && st.st_ino == screen_ino) return 1;
    return fd;
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
    if (command_page && (!strcmp(fault, "configure-admitted") || !strcmp(fault, "configure-presentation")))
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

static void consent_hold(int fd, const void *bytes, size_t count, int last) {
    const int screen = screen_fd(fd);
    const char *fault = getenv("RUI_TERMINAL_FAULT");
    static int choice = 0, choice_held = 0;
    if (screen != 1 || !fault || strncmp(fault, "consent-", 8)) return;
    /* The renderer writes only changed cells, so whole status text never
       appears; "Type" starts the choice status ("Type a + Enter to allow
       once..."). Hold after the frame that draws it completes. */
    static size_t matched = 0;  /* Writes may split the word. */
    for (size_t i = 0; !choice && i < count; ++i) {
        char byte = ((const char *)bytes)[i];
        matched = byte == "Type"[matched] ? matched + 1 : (byte == 'T' ? 1 : 0);
        if (matched == 4) choice = 1;
    }
    if (last && choice && !choice_held && count >= 8 &&
        !memcmp((const char *)bytes + count - 8, "\033[?2026l", 8)) {
        choice_held = 1;
        record("choice-output-complete\n");
        while (access(getenv("RUI_TERMINAL_CHOICE_RELEASE"), F_OK)) usleep(1000);
    }
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
    ssize_t written = real_writev(fd, iov, count);
    size_t total = 0;
    for (int i = 0; i < count; ++i) total += iov[i].iov_len;
    if (written >= 0 && (size_t)written == total) {
        int saved = errno;
        for (int i = 0; i < count; ++i) consent_hold(fd, iov[i].iov_base, iov[i].iov_len, i == count - 1);
        errno = saved;
    }
    return written;
}

static ssize_t probe_write(int fd, const void *bytes, size_t count) {
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
        const char subject[] = ",\"subject_kind\":\"session\",\"subject\":\"diagnostic/session\"";
        static atomic_int contention_claimed = 0;
        int selected = 0;
        if ((lifecycle || !strcmp(fault, "diagnostic-contention")) && count >= strlen(phase) &&
            !memcmp(bytes, phase, strlen(phase)) && count >= 2 &&
            !memcmp((const char *)bytes + count - 2, "}\n", 2)) {
            selected = lifecycle;
            for (size_t i = 0; !lifecycle && i + sizeof(subject) - 1 < count; ++i) {
                if (!memcmp((const char *)bytes + i, subject, sizeof(subject) - 1) &&
                    (((const char *)bytes)[i + sizeof(subject) - 1] == ',' ||
                     ((const char *)bytes)[i + sizeof(subject) - 1] == '}')) selected = 1;
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
    if (result == (ssize_t)count) consent_hold(fd, bytes, count, 1);
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
INTERPOSE(probe_pthread_create, pthread_create)
#else
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
#include <errno.h>
#include <fcntl.h>
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

int main(int argc, char **argv) {
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
        dispose_all(
            lambda: stop_process(caller, timeout=5) if caller is not None else None,
            lambda: termios.tcflush(slave, termios.TCOFLUSH),
            lambda: termios.tcflush(slave, termios.TCIFLUSH),
            lambda: termios.tcsetattr(slave, termios.TCSANOW, original),
            lambda: os.close(master), lambda: os.close(slave),
        )

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
        dispose_all(release.touch, lambda: stop_process(caller, timeout=5))


def capture_receipt_case(state, library):
    """Required writer entry survives real, unrelated optional stderr custody."""
    root = state / "capture-receipt"
    root.mkdir(mode=0o700)
    store = root / "store"
    arm, release, log = (root / name for name in ("arm", "release", "probe.log"))
    answer = b"exact capture answer"
    provider_release = threading.Event()
    endpoint = fixture.SuccessEndpoint([
        (fixture.sse_answer("capture", "reason", "message", answer.decode())[0], provider_release)])
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    gate = ReleaseGate(root / "capture-gate")
    host = diagnostics = inspector = None
    try:
        host, _ = start_ready_process(fixture.host_arguments(store,
            f"http://127.0.0.1:{endpoint.server_port}/responses", "--test-phase-trace",
            "--test-response-capture-gate-path", gate.path), env={**os.environ,
            "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
            "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": "diagnostic-contention",
            "RUI_DIAGNOSTIC_DROP_FIRST_INSPECTION": "1",
            "RUI_DIAGNOSTIC_ARM": str(arm), "RUI_DIAGNOSTIC_RELEASE": str(release)})
        diagnostics = HostDiagnostics(host)
        fixture.configure(root, store, "capture-config", "diagnostic/session", "model-a")
        # Admission uses the ordinary worker; complete it before that worker
        # holds optional stderr. Only provider capture must progress under hold.
        fixture.message(root, store, "capture-message", "diagnostic/session", "hello")
        fixture.wait_for(lambda: len(endpoint.requests) == 1, "held provider request", timeout=3)
        arm.touch()
        # A specific optional write may lose custody or output credit. Seek an
        # actual hold without requiring delivery of any one inspection trace.
        # The first eligible write deliberately fails to exercise that case.
        acquisition_deadline = time.monotonic() + 3
        while True:
            remaining = acquisition_deadline - time.monotonic()
            assert remaining > 0, "actual optional inspection custody exhausted original deadline"
            inspector = fixture.start_command("session", "inspect", "--store", store, "--session", "diagnostic/session")
            fixture.wait_for(lambda: (log.exists() and "diagnostic-held-inspection\n" in log.read_text())
                or inspector.poll() is not None, "optional inspection hold or completed caller", timeout=remaining)
            assert time.monotonic() < acquisition_deadline, "actual optional inspection custody exceeded original deadline"
            if log.exists() and "diagnostic-held-inspection\n" in log.read_text():
                break
            out, err = inspector.communicate(timeout=max(0, acquisition_deadline - time.monotonic()))
            assert inspector.returncode == 0, (out, err)
            assert json.loads(out)["session"]["reference"] == "diagnostic/session", out
        assert log.read_text().count("diagnostic-dropped-inspection\n") == 1
        held = [json.loads(line) for line in log.read_text().splitlines() if line.startswith("{")]
        assert len(held) == 1 and held[0]["process"] == str(host.pid) and held[0]["subject"] == "diagnostic/session", held
        provider_release.set()
        event = diagnostics.wait("capture_write_gate_entered", timeout=15)[0]
        assert event["process"] == held[0]["process"] and event["run"] == held[0]["run"], (event, held)
        assert event["written_bytes"] == "0" and gate.path.exists() and not release.exists(), event
        assert b"capture_write_gate_entered" not in diagnostics.tail(), "optional output supplied required receipt"
        release.touch()
        out, err = inspector.communicate(timeout=3)
        assert inspector.returncode == 0, (out, err)
        gate.release()
        deadline = time.monotonic() + 10
        observation, saved_answer, _ = fixture.wait_for_result_release(
            store, "capture-message", "diagnostic/session", deadline)
        assert observation["result"]["status"] == "completed", observation
        assert saved_answer == answer
        print("native capture receipt: optional inspection drop tolerated within original deadline; writer entry under actual stderr contention; exact answer and simultaneous zero custody/scratch", flush=True)
    finally:
        incoming_error = sys.exc_info()[1]
        if diagnostics is not None:
            diagnostics.snapshot_failure(lambda: {"case": "capture-receipt",
                "capture_gate_exists": gate.path.exists(), "optional_released": release.exists()})

        def retire_inspector():
            if inspector is not None and inspector.poll() is None:
                try:
                    inspector.communicate(timeout=3)
                except subprocess.TimeoutExpired:
                    inspector.kill()
                    inspector.communicate(timeout=3)
                    raise  # Mandatory reap does not accept the timed-out caller.

        errors = []
        for dispose in (provider_release.set, release.touch, retire_inspector,
                        lambda: diagnostics.dispose_capture(gate, lambda: {"case": "capture-receipt",
                            "capture_gate_exists": gate.path.exists(), "optional_released": release.exists()})
                            if diagnostics is not None else gate.release(),
                        endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5)):
            try:
                dispose()
            except BaseException as error:
                errors.append(error)
        if thread.is_alive():
            errors.append(AssertionError("Capture endpoint thread did not retire"))
        if errors:
            if incoming_error is None:
                raise errors[0]
            try:
                incoming_error.add_note("Capture cleanup failed: " + ", ".join(cleanup_failure(error) for error in errors))
            except BaseException:
                pass  # Secondary reporting cannot replace the primary failure.


def persistent_cases(state, library, home, store, host):
    """Real synchronous capture custody and actual nonblocking output credit."""
    records = home / ".config/rui/requests"
    records.mkdir(mode=0o700, parents=True, exist_ok=True)
    # The departure owner covers interruption at every decision cut. Keep a
    # real INT during join here; configure-commit-term covers the TERM adapter.
    # Deliberate large backpressure inputs stay last: unrelated decoder and
    # restoration cases must not inherit their opening-transcript workload.
    for case in ("sync-exit", "sync-handoff", "sync-command-int",
                 "admission-interrupt", "disable", "restore", "both",
                 "incomplete-disable", "incomplete-restore", "incomplete-both",
                 "backpressure", "backpressure-command"):
        master, slave = open_pty()
        output_master, output_slave = open_pty()
        original = termios.tcgetattr(slave)
        # probe.log under a case directory is retained on failure.
        (state / f"persistent-{case}").mkdir()
        log, release = state / f"persistent-{case}" / "probe.log", state / f"persistent-{case}.release"
        caller = proxy = None
        reply_release = threading.Event()
        before = set(records.glob("*.json"))
        try:
            fault = "backpressure" if case.startswith("backpressure") else case.removeprefix("incomplete-")
            environment = {**os.environ, "HOME": str(home),
                "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
                "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": fault,
                "RUI_TERMINAL_BACKPRESSURE_ARM": str(state / f"persistent-{case}" / "arm")}
            if case.startswith("sync-"):
                environment["RUI_CAPTURE_SYNC_RELEASE"] = str(release)
                if case == "sync-handoff":
                    environment["RUI_CAPTURE_SYNC_ERROR"] = "1"
            caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
                "--", "terminal/restoration"], env=environment,
                stdin=slave, stdout=output_slave, stderr=subprocess.PIPE)
            human.read_terminal(output_master, "› ")
            if fault in ("disable", "both"):
                # The terminal reports alternate scroll reset, so Rui owns
                # enabling it and must reset it even when paste disable fails.
                os.write(master, b"\x1b[?1007;2$y")
                fixture.wait_for(lambda: log.exists() and "scroll-enabled\n" in log.read_text(), "owned alternate scroll")
            if case.startswith("sync-"):
                os.write(master, b"original synchronously captured\n")
                fixture.wait_for(lambda: log.exists() and "capture-sync-held" in log.read_text(), "real capture directory sync")
                record, = set(records.glob("*.json")) - before
                saved = record.read_bytes()
                key = json.loads(saved)["key"]
                assert fixture.command("request", "inspect", "--store", store, "--key", key)["observation"]["status"] == "absent"
                if case == "sync-handoff":
                    os.write(master, b"/inspect-action\nSTALE")
                elif case.startswith("sync-command-"):
                    os.write(master, b"/configure --permission-mode ask\n")
                else:
                    os.write(master, b"/exit\nSTALE")
                if case.startswith("sync-command-"):
                    # Commands run inside the screen; INT restores first.
                    caller.send_signal(signal.SIGINT)
                if case != "sync-handoff":
                    fixture.wait_for(lambda: termios.tcgetattr(slave)[3] & termios.ICANON, "restoration before synchronous capture join")
                assert caller.poll() is None, "synchronous capture was reported reaped before its gate released"
                release.touch()
                if case == "sync-handoff":
                    human.read_terminal(output_master, "No actionable permission")
                    resumed = human.await_screen(output_master, "Not confirmed", composer=True)
                    assert "No actionable permission" in resumed, resumed
                    # Queued suffix text stays an unsent draft, never input.
                    assert "\n› STALE" in resumed and set(records.glob("*.json")) - before == {record}, resumed
                    os.write(master, b"\x15")
                    human.read_terminal(output_master, "› ", composer=True)
                    resumed = human.return_to_live(output_master, input_fd=master)
                    assert "STALE" not in resumed, resumed
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
                # After opening, the next screen write stops and fills stdout's
                # PTY; an external caller's large content then keeps the
                # frontend's actual activity reader writing into it.
                (state / f"persistent-{case}" / "arm").touch()
                human.run(home, "session", "send", "--store", store, "--session", "terminal/restoration", "z" * 50000)
                fixture.wait_for(lambda: log.exists() and "output-blocked" in log.read_text(), "actual terminal EAGAIN")
                if case == "backpressure-command":
                    # Blocked output defers the command; it is no
                    # cancellation trigger. Ctrl-C then retires without it.
                    with log.open("a") as marks:
                        marks.write("test-command-sent\n")
                    os.write(master, b"/configure --permission-mode ask\n")
                    time.sleep(0.5)
                    with log.open("a") as marks:
                        marks.write(f"test-interrupt-sent records={len(set(records.glob('*.json')) - before)}\n")
                    # A drained queue lets the deferred command run legitimately;
                    # that is a lost fixture precondition, not a product result.
                    assert "output-progressed\n" not in log.read_text(), ("terminal output drained before the interrupt", log.read_text())
                    assert caller.poll() is None, "blocked output turned a command into cancellation"
                os.write(master, b"\x03")
            elif case.startswith("incomplete-"):
                os.write(master, b"\xc3")
            else:
                os.write(master, b"\x03")
            expected = 1 if fault in ("backpressure", "disable", "restore", "both") else 0
            assert caller.wait(timeout=5) == expected, caller.stderr.read()
            errors = caller.stderr.read().decode()
            if expected:
                assert ("TerminalRestoreFailed" if fault in ("restore", "both") else "TerminalCleanupFailed") in errors, errors
            if fault in ("disable", "both"):
                assert log.read_text().count("scroll-reset\n") == 1, ("failed paste disable skipped the owned scroll reset", log.read_text())
            if case.startswith("incomplete-"):
                assert set(records.glob("*.json")) == before, "incomplete input created a capture"
            if case == "backpressure-command":
                assert all(json.loads(record.read_bytes())["kind"] == "message"
                    for record in set(records.glob("*.json")) - before), "failed cleanup captured pending configuration"
                assert fixture.command("session", "inspect", "--store", store,
                    "--session", "terminal/restoration")["session"]["permission_mode"] == "bypass", "failed cleanup executed pending configuration"
            if case.startswith("sync-command-"):
                assert set(records.glob("*.json")) - before == {record}, "interrupt during join captured a pending configuration"
                assert record.read_bytes() == saved, "interrupt replaced original capture"
                assert fixture.command("session", "inspect", "--store", store,
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
                assert f"Message not confirmed. Use rui request recover {request['key']}" in errors, errors
            reply_release.set()
            if proxy is not None:
                proxy.close()
                proxy = None
            # Detachment never cancels or restarts the actual owning Host.
            answer = human.admit(home, "session", "send", "--store", store, "--session", "terminal/restoration", f"valid after {case}")
            assert answer["admission"]["answer"]["status"] == "accepted", answer
            print(f"persistent terminal: {case} passed", flush=True)
        finally:
            dispose_all(
                release.touch, reply_release.set,
                lambda: stop_process(caller, timeout=5) if caller is not None else None,
                lambda: proxy.close() if proxy is not None else None,
                lambda: termios.tcflush(output_slave, termios.TCOFLUSH),
                # Discard and restore independently; do not wait for unread
                # Darwin canonical echo on the separate input terminal.
                lambda: termios.tcflush(slave, termios.TCIFLUSH),
                lambda: termios.tcsetattr(slave, termios.TCSANOW, original),
                *(lambda fd=fd: os.close(fd) for fd in (master, slave, output_master, output_slave)),
            )


def preserve_renderer_comparison(state, before, after, screen_start, events, omitted_events):
    """Keep exact synthetic-fixture operands outside disposal's temporary root.

    Hex is lossless encoding, not redaction. This case has only fixture-owned
    configuration text, no model request/response or user-provided content.
    Never generalize this capture to other terminal journeys. Existing whole-
    file/job caps refuse oversized evidence rather than truncating operands.
    """
    try:
        root = state / "renderer-comparison"
        root.mkdir(mode=0o700)
        difference = next((index for index, (left, right) in enumerate(zip(before, after))
                           if left != right), min(len(before), len(after)))
        path = root / "pty-failure.json"
        if not preserve_failure_metadata(path, lambda: {
            "case": "renderer-backpressure", "phase": "idle-after-configure",
            "retained_at_ns": time.monotonic_ns(), "screen_start": screen_start,
            "equal": before == after, "before_hex": before.hex(), "after_hex": after.hex(),
            "first_difference": difference,
            "before_delta_hex": before[difference:].hex(),
            "after_delta_hex": after[difference:].hex(),
            "events": events, "omitted_events": omitted_events,
        }):
            return
        ci = str(pathlib.Path(__file__).resolve().parents[1] / "ci")
        sys.path.insert(0, ci)
        try:
            from run_selected import retain_failure_logs
            destination = pathlib.Path(os.environ.get("RUI_FAILURE_ARTIFACTS", ".amp/failure-artifacts"))
            destination.mkdir(mode=0o700, parents=True, exist_ok=True)
            retain_failure_logs([root], destination)
            print(f"renderer comparison destination: {destination}", file=sys.stderr, flush=True)
        finally:
            sys.path.remove(ci)
    except Exception as error:
        # Optional evidence cannot replace the assertion or prevent disposal.
        try:
            print(f"Renderer comparison unavailable: {type(error).__name__}", file=sys.stderr, flush=True)
        except Exception:
            pass


def renderer_backpressure_case(state, library, home, store):
    """A real blocked frame defers a command; it never becomes cancellation."""
    from terminal_screen import ScreenCapture

    session = "terminal/renderer-backpressure"
    human.run(home, "session", "configure", "--store", store, "--session", session,
        "--workspace", state, "--provider", "codex", "--model", "model-a")
    master, slave = open_pty()
    output_master, output_slave = open_pty()
    original = termios.tcgetattr(slave)
    original[6][termios.VERASE] = b"\x08"
    termios.tcsetattr(slave, termios.TCSANOW, original)
    flags = {fd: fcntl.fcntl(fd, fcntl.F_GETFL) for fd in (slave, output_slave)}
    fcntl.ioctl(output_slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    log = state / "renderer-backpressure.log"
    arm = state / "renderer-backpressure-arm"
    records = home / ".config/rui/requests"
    before = set(records.glob("*.json"))
    caller = None
    output, errors = bytearray(), bytearray()
    echo_bytes = 0
    stderr_open = True
    events, omitted_events = [], 0
    comparison = None

    def event(phase, **facts):
        nonlocal omitted_events
        if len(events) < 256:
            events.append({"at_ns": time.monotonic_ns(), "phase": phase, **facts})
        else:
            omitted_events += 1

    def append_output(chunk, phase):
        event(phase, channel="output", start=len(output), end=len(output) + len(chunk))
        output.extend(chunk)

    def drain_until(predicate, description, timeout=15):
        nonlocal echo_bytes, stderr_open
        deadline = time.monotonic() + timeout
        # Retained event phases are JSON text; a description may carry the
        # live screen for assertion context.
        phase = description if isinstance(description, str) else description[0]
        while not predicate():
            remaining = deadline - time.monotonic()
            assert remaining > 0, (description, caller.poll(), bytes(output[-4096:]), bytes(errors))
            ready = select.select([master, output_master, *([caller.stderr] if stderr_open else [])], [], [], remaining)[0]
            assert ready, (description if not isinstance(description, tuple) else (description[0], description[1].completed), caller.poll(), bytes(output[-4096:]), bytes(errors))
            for fd in ready:
                chunk = os.read(fd if isinstance(fd, int) else fd.fileno(), 65536)
                if not chunk and fd is caller.stderr:
                    # Exit can close stderr in the same readiness batch as the
                    # final PTY bytes; the predicate still decides after them.
                    stderr_open = False
                    continue
                assert chunk, (description, caller.poll(), bytes(output[-4096:]), bytes(errors))
                if fd == master:
                    # Fresh Enter echoes on the separate input PTY after
                    # restoration. Darwin's next TCSAFLUSH waits for its peer.
                    event(phase, channel="input-echo", count=len(chunk))
                    echo_bytes += len(chunk)
                elif fd == output_master:
                    append_output(chunk, phase)
                else:
                    event(phase, channel="stderr", count=len(chunk))
                    errors.extend(chunk)
            assert len(output) + len(errors) + echo_bytes < 1024 * 1024, "unbounded renderer witness"

    try:
        environment = {**os.environ, "HOME": str(home), "TERM": "xterm-256color",
            "RUI_TERMINAL_FAULT": "renderer-backpressure",
            "RUI_TERMINAL_PROBE": str(log),
            "RUI_TERMINAL_BACKPRESSURE_ARM": str(arm),
            "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library)}
        caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
            "--", session], env=environment,
            stdin=slave, stdout=output_slave, stderr=subprocess.PIPE)
        screen = ScreenCapture()
        consumed = 0
        def composer_ready():
            nonlocal consumed
            screen.feed(bytes(output[consumed:]))
            consumed = len(output)
            return screen.draft("", 2)
        drain_until(composer_ready, "opening alternate-screen composer")
        arm.touch()
        event("arm-backpressure")
        assert os.write(master, b"x") == 1
        fixture.wait_for(lambda: log.exists() and "output-blocked\n" in log.read_text(),
            "renderer actual kernel EAGAIN")
        command = b"\x15/configure --permission-mode ask\n"
        event("send-configure")
        assert os.write(master, command) == len(command)
        # The command waits for the blocked frame; output credit returns
        # before cleanup, never as a cancellation or a terminal handoff.
        time.sleep(0.5)
        assert caller.poll() is None and "output-blocked\n" in log.read_text()
        termios.tcflow(output_slave, termios.TCOON)
        event("restore-output-credit")
        def configured_page():
            composer_ready()
            # Short command output is a status notice, not a page.
            return "Configured." in screen.completed.split("\n") and not screen.completed.startswith("Browsing")
        drain_until(configured_page, ("Configure notice", screen))
        assert b"\x1b[?1049l" not in output, "command left the alternate screen"
        def refreshed_composer():
            composer_ready()
            return not screen.completed.startswith("Browsing") and screen.draft("", 2)
        drain_until(refreshed_composer, "refreshed empty composer")
        # Without input, the shown screen never changes: no replayed command,
        # second notice or redraw. Freeze both operands before asserting so
        # retention keeps them losslessly across disposal.
        screen_start = output.rfind(b"\x1b[?1049h")
        assert screen_start >= 0, bytes(output[-4096:])
        shown_output = bytes(output[screen_start:])
        event("first-snapshot", output_end=len(output), screen_start=screen_start)
        captured, = set(records.glob("*.json")) - before
        saved = captured.read_bytes()
        record = json.loads(saved)
        assert record["kind"] == "configure", record
        observed = fixture.command("request", "inspect", "--store", store, "--key", record["key"])
        assert observed["observation"]["status"] == "accepted", observed
        assert observed["observation"]["revision"] == "2", observed
        assert fixture.command("session", "inspect", "--store", store,
            "--session", session)["session"]["permission_mode"] == "ask"
        # Canonical reads above provide work while no input is sent.
        event("canonical-reads-complete")
        assert caller.poll() is None
        while select.select([output_master], [], [], 0)[0]:
            append_output(os.read(output_master, 65536), "no-input-drain")
        compared_output = bytes(output[screen_start:])
        event("second-snapshot", output_end=len(output))
        comparison = (shown_output, compared_output, screen_start, tuple(events), omitted_events)
        assert compared_output == shown_output, "alternate-screen output changed without input"
        refresh_start = len(output)
        event("interrupt")
        assert os.write(master, b"\x03") == 1
        drain_until(lambda: b"\x1b[?1049l" in output[refresh_start:], "final alternate-screen exit")
        assert caller.wait(timeout=5) == 0, caller.stderr.read()
        assert not errors and not caller.stderr.read(), bytes(errors)
        actual = termios.tcgetattr(slave)
        if sys.platform == "darwin":
            mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
            actual[3] &= ~mask
            original[3] &= ~mask
        assert actual == original, (actual, original)
        for fd, expected in flags.items():
            assert_file_flags(fcntl.fcntl(fd, fcntl.F_GETFL), expected)
        assert set(records.glob("*.json")) - before == {captured}
        assert captured.read_bytes() == saved
        assert log.read_text().count("output-blocked\n") == 1
        print("renderer backpressure: actual EAGAIN; deferred command ran once; accepted Configure notice on the alternate screen; refreshed composer; exact termios/fd restoration", flush=True)
    finally:
        try:
            dispose_all(
                lambda: termios.tcflow(output_slave, termios.TCOON),
                lambda: stop_process(caller, timeout=5) if caller is not None else None,
                lambda: termios.tcflush(output_slave, termios.TCOFLUSH),
                lambda: termios.tcflush(slave, termios.TCIFLUSH),
                lambda: termios.tcsetattr(slave, termios.TCSANOW, original),
                *(lambda fd=fd: os.close(fd) for fd in (master, slave, output_master, output_slave)))
        finally:
            # Operands were frozen before assertion/disposal, including when
            # disposal itself fails. No live PTY or process sampling is needed.
            # Ordinary successful gates do not collect terminal content.
            if comparison is not None and (sys.exception() is not None or
                    os.environ.get("RUI_RENDERER_RETAIN_COMPARISON") == "1"):
                preserve_renderer_comparison(state, *comparison)


def consent_boundary_cases(state, library):
    """Input arriving during final presentation cannot consent or lose Ctrl-C."""
    for case in ("cancel", "paste", "escape-allow", "escape-deny"):
        root = state / f"consent-{case}"
        root.mkdir()
        home, store = root / "home", root / "store"
        home.mkdir(mode=0o700)
        endpoint = fixture.SuccessEndpoint([
            fixture.sse_tool_calls("consent-call", [("bash", "consent-id",
                json.dumps({"cmd": "printf forbidden > effect", "timeout_ms": None, "description": "Write consent effect marker"}))]),
            fixture.sse_answer("consent-answer", "consent-reason", "consent-message",
                "Allowed." if case == "escape-allow" else "Denied.")[0],
        ])
        thread = threading.Thread(target=endpoint.serve_forever)
        thread.start()
        host = caller = None
        master, slave = open_pty()
        original = termios.tcgetattr(slave)
        read_ready, write_ready = os.pipe()
        release, drain, log = root / "choice.release", root / "drain.release", root / "probe.log"
        try:
            host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
            human.run(home, "session", "configure", "--store", store, "--session", "consent/boundary",
                "--workspace", root, "--provider", "codex", "--model", "model-a", "--permission-mode", "ask")
            caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
                "--", "consent/boundary"], stdin=slave, stdout=slave, stderr=subprocess.PIPE,
                env={**os.environ, "HOME": str(home), "NO_COLOR": "1",
                    "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
                    "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": f"consent-{case}",
                    "RUI_TERMINAL_CHOICE_RELEASE": str(release), "RUI_TERMINAL_DRAIN_RELEASE": str(drain),
                    "RUI_TEST_ACTION_READY_FD": str(write_ready)}, pass_fds=(write_ready,))
            human.read_terminal(master, "› ")
            os.write(master, b"propose command\n")
            presentation = human.read_terminal(master, "Type a + Enter to allow once · d + Enter to deny")
            assert "Time limit: Host default" in presentation, presentation
            fixture.wait_for(lambda: log.exists() and "choice-output-complete" in log.read_text(), "final choice write")
            records = home / ".config/rui/requests"
            before = set(records.glob("*.json"))
            stale = b"\x03" if case == "cancel" else (
                b"a\n\x1b" if case.startswith("escape-") else b"\x1b[200~")
            os.write(master, stale)
            assert not select.select([read_ready], [], [], 0)[0], "held presentation opened consent"
            release.touch()
            if case == "cancel":
                fixture.wait_for(lambda: termios.tcgetattr(slave)[3] & termios.ICANON,
                    "restoration without releasing consent drain", timeout=3)
                assert not drain.exists(), "fixture released the drain"
                assert not select.select([read_ready], [], [], 0)[0], "cancelled choice became ready"
            elif case.startswith("escape-"):
                assert set(records.glob("*.json")) == before, "stale input captured permission"
                presentation += human.action_ready(read_ready, master)
                assert set(records.glob("*.json")) == before, "expiry captured stale permission"
                assert not (root / "effect").exists(), "stale input ran Bash"
                os.write(master, b"a\n" if case == "escape-allow" else b"d\n")
                human.read_terminal(master, "Allowed." if case == "escape-allow" else "• Write consent effect marker — Denied")
                assert len(set(records.glob("*.json")) - before) == 1, "first fresh choice was not captured"
                os.write(master, b"\x03")
            else:
                assert not select.select([read_ready], [], [], 0.2)[0], "paste prefix opened consent"
                os.write(master, b"a\n")
                assert not select.select([read_ready], [], [], 0.2)[0], "unfinished paste authorized"
                assert set(records.glob("*.json")) == before
                os.write(master, b"\x1b[201~")
                presentation += human.action_ready(read_ready, master)
                os.write(master, b"d\n")
                human.read_terminal(master, "• Write consent effect marker — Denied")
                os.write(master, b"\x03")
            output, errors = human.terminal_exit(caller, master)
            assert caller.wait(timeout=5) == 0, (output, errors)
            actual = termios.tcgetattr(slave)
            if sys.platform == "darwin":
                mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                actual[3] &= ~mask
                original[3] &= ~mask
            assert actual == original
            if case == "escape-allow":
                assert (root / "effect").read_bytes() == b"forbidden", "fresh Allow was swallowed"
            else:
                assert not (root / "effect").exists(), "pre-boundary or denied input ran Bash"
            if case == "cancel":
                assert set(records.glob("*.json")) == before, "cancel captured permission"
            print(f"persistent consent boundary: {case} passed", flush=True)
        finally:
            if sys.exc_info()[0] is not None:
                preserve_failure_metadata(root / "pty-failure.json", lambda: {
                    "case": case, "error": sys.exc_info()[0].__name__,
                    "caller_returncode": caller.poll() if caller is not None else None,
                    "ready_pending": bool(select.select([read_ready], [], [], 0)[0]),
                    "terminal_pending": bool(select.select([master], [], [], 0)[0]),
                    "drain_released": drain.exists(),
                })
            dispose_all(
                release.touch, drain.touch,
                lambda: stop_process(caller, timeout=5) if caller is not None else None,
                lambda: fixture.stop_host(host) if host is not None else None,
                endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
                lambda: termios.tcflush(slave, termios.TCOFLUSH),
                lambda: termios.tcflush(slave, termios.TCIFLUSH),
                lambda: termios.tcsetattr(slave, termios.TCSANOW, original),
                *(lambda fd=fd: os.close(fd) for fd in (master, slave, read_ready, write_ready)),
            )


def unread_input(slave):
    """Bytes written to the terminal that the caller has not read yet."""
    return struct.unpack("i", fcntl.ioctl(slave, termios.FIONREAD, b"\0" * 4))[0]


def command_interruption_cases(state, library):
    """Foreground signals cancel actual handoff sockets, not committed intent."""
    root = state / "command-interruption"
    root.mkdir()
    home, store = root / "home", root / "store"
    home.mkdir(mode=0o700)
    endpoint = fixture.SuccessEndpoint([
        fixture.sse_answer("command-answer", "command-reason", "command-message", "Saved answer.")[0],
        fixture.sse_tool_calls("command-tool", [("bash", "command-id",
            json.dumps({"cmd": "printf forbidden > effect", "timeout_ms": None, "description": "Write interruption effect marker"}))]),
    ])
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = caller = proxy = None
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        human.run(home, "session", "configure", "--store", store, "--session", "command/signals",
            "--workspace", root, "--provider", "codex", "--model", "model-a", "--permission-mode", "ask")
        message = human.admit(home, "session", "send", "--store", store, "--session", "command/signals", "saved answer")
        fixture.wait_for(lambda: fixture.completed_observation(store, message["request"]), "saved command result")
        human.admit(home, "session", "send", "--store", store, "--session", "command/signals", "propose tool")
        records = home / ".config/rui/requests"
        for case, command, route, signal_number in (
                ("requests", "/requests", "", signal.SIGINT),
                ("configure-before", "/configure --permission-mode ask", None, signal.SIGINT),
                ("configure-stopped-stderr", "/configure --permission-mode ask", None, signal.SIGINT),
                ("configure-full-stderr", "/configure --permission-mode ask", None, signal.SIGINT),
                ("configure-inflight", "/configure --permission-mode ask", "/v1/configure", signal.SIGINT),
                ("configure-commit-int", "/configure --permission-mode ask", "/v1/configure", signal.SIGINT),
                ("configure-commit-term", "/configure --permission-mode ask", "/v1/configure", signal.SIGTERM),
                ("configure-admitted", "/configure --permission-mode ask", "", signal.SIGINT),
                ("configure-presentation", "/configure --permission-mode ask", "", signal.SIGINT),
                ("configure-rejected", "/configure --model model-b", "", signal.SIGINT),
                ("configure-canonical", "/configure --permission-mode ask", "", signal.SIGINT),
                ("result-observe", f"/result {message['request']}", "/v1/observe-command", signal.SIGINT),
                ("result-content", f"/result {message['request']}", "/v1/read-result", signal.SIGINT),
                ("inspect-current", "/inspect-action", "/v1/inspect-session", signal.SIGINT),
                ("inspect-arguments", "/inspect-action", "/v1/read-action-arguments", signal.SIGINT),
                ("inspect-full-stderr", "/inspect-action", "/v1/read-action-arguments", signal.SIGINT)):
            master, slave = open_pty()
            original = termios.tcgetattr(slave)
            ready_read, ready_write = os.pipe()
            # Exit guidance is optional: a stopped terminal or a full blocking
            # pipe on stderr drops it and never holds the restored caller.
            stopped = case.endswith(("-stopped-stderr", "-full-stderr"))
            error_master, error_slave = (open_pty() if case.endswith("-stopped-stderr")
                else os.pipe() if stopped else (None, None))
            if case.endswith("-full-stderr"):
                os.set_blocking(error_slave, False)
                try:
                    while os.write(error_slave, b"x" * 65536):
                        pass
                except BlockingIOError:
                    pass
                os.set_blocking(error_slave, True)
            unread_read, unread_write = os.pipe() if stopped else (None, None)
            release = root / f"{case}.release"
            log = root / f"{case}.log"
            received, reply_release = threading.Event(), threading.Event()
            transmitted = []
            before = set(records.glob("*.json"))
            try:
                environment = {**os.environ, "HOME": str(home), "NO_COLOR": "1",
                    "RUI_TEST_ACTION_READY_FD": str(ready_write)}
                if not route:
                    environment.update({"DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
                        "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": case})
                    if route is None:
                        environment["RUI_CAPTURE_SYNC_RELEASE"] = str(release)
                caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
                    "--", "command/signals"], env=environment, stdin=slave, stdout=slave,
                    stderr=error_slave if stopped else subprocess.PIPE, pass_fds=(ready_write,),
                    preexec_fn=lambda: (signal.signal(signal.SIGINT, signal.SIG_DFL),
                        signal.signal(signal.SIGTERM, signal.SIG_DFL)))
                human.action_ready(ready_read, master)
                if route:
                    def hold(response):
                        received.set()
                        assert reply_release.wait(15), "command reply never released"
                        return None  # Cancellation must finish before peer release.
                    def before_forward(body):
                        transmitted.append(body)
                        hold(body)
                        return False
                    proxy = canonical.ReplyProxy(host, route, hold,
                        before_forward=before_forward if case == "configure-inflight" else None)
                elif case == "configure-canonical":
                    proxy = canonical.ReplyProxy(host, "/v1/configure")
                os.write(master, command.encode() + b"\n")
                if route is None:
                    fixture.wait_for(lambda: log.exists() and "capture-sync-held" in log.read_text(), "Configure pre-send sync")
                elif route:
                    assert received.wait(10), (case, "command route not reached")
                else:
                    fixture.wait_for(lambda: log.exists() and "command-return-signal" in log.read_text(), "decoded command return signal")
                if route != "":  # The probe signals at a "" command's return; nothing holds it.
                    # The command is held on the reader worker. The pending
                    # Action owns the input field and nothing is fresh until
                    # the command completes: neither a Message nor a + Enter
                    # is captured, sent or authorizes the Action.
                    for typed in (b"hello\r", b"a\r"):
                        os.write(master, typed)
                        fixture.wait_for(lambda: unread_input(slave) == 0, f"{case} read {typed!r} while held")
                    shown = human.settle_screen(master, quiet=0.5)
                    composer = shown.splitlines()[human.terminal_capture(master).screen.cursor.y]
                    assert composer.strip() in (">", "›") and "hello" not in shown, (case, shown)
                    assert "Type a + Enter to allow once" not in shown, (case, "choice offered while command held", shown)
                    held = set(records.glob("*.json")) - before
                    # Only the held Configure's own record (its capture may
                    # still be syncing); exact identity is checked after exit.
                    assert len(held) <= (1 if case.startswith("configure") else 0), (case, held)
                    assert all(json.loads(path.read_bytes())["kind"] == "configure" for path in held), (case, held)
                    assert len(endpoint.requests) == 2 and not (root / "effect").exists(), (case, "held command sent input")
                # Commands run inside the Session screen; the terminal stays
                # raw until the signal's restoration (checked after exit).
                if route != "":
                    caller.send_signal(signal_number)
                if case.endswith("-stopped-stderr"):
                    termios.tcflow(error_slave, termios.TCOOFF)
                if route is None:
                    # kill() returns before delivery. The canonical terminal
                    # is restored only after the handler sets the command's
                    # cancellation, so it orders the signal before the release.
                    fixture.wait_for(lambda: termios.tcgetattr(slave)[3] & termios.ICANON, f"{case} signal restoration")
                    release.touch()  # File custody is nonpreemptible, transport is cancellable.
                if stopped:  # Never readable: exit cannot depend on stderr credit.
                    caller.stderr = open(os.dup(unread_read), "rb", buffering=0)
                output, errors = human.terminal_exit(caller, master)
                if case.endswith("-stopped-stderr"):
                    termios.tcflow(error_slave, termios.TCOON)
                if case == "configure-canonical":
                    assert caller.returncode == 1 and b"error: CanonicalStoreFailure" in errors and b"Resume: " in errors, (case, output, errors)
                else:
                    assert caller.returncode == 0, (case, caller.returncode, output, errors)
                if case == "requests" or case.startswith("inspect-"):
                    # INT while a page is prepared detaches before showing
                    # it; the restored main screen names exact recovery.
                    assert b"Cancelled" not in errors, (output, errors)
                    assert b"\x1b[?1049l\r\nDetached. Host work continues.\r\nResume: rui session resume --store " in output, output
                    assert b"rui action inspect --store " in output and b" --action 1\r\n" in output, output
                assert not reply_release.is_set(), "command needed peer release to exit"
                added = set(records.glob("*.json")) - before
                if case.startswith("configure"):
                    record, = added
                    saved = record.read_bytes()
                    identity = json.loads(saved)
                    key = identity["key"]
                    if case == "configure-inflight":
                        assert transmitted == [saved], "in-flight send changed captured request bytes"
                    assert identity["store"] == str(store) and identity["session"] == "command/signals"
                    if stopped:
                        assert b"rui request" not in errors, errors  # Dropped, not delayed.
                    else:
                        assert f"rui request inspect {key}".encode() in errors, (case, errors, output[-1500:])
                        assert b"rui: Interrupted command output:\n" in errors, (case, errors)
                    if stopped:
                        pass
                    elif case in ("configure-admitted", "configure-presentation", "configure-rejected"):
                        assert (b"rejected" if case == "configure-rejected" else b"accepted; do not resubmit it") in errors and b"not confirmed" not in errors, errors
                        if case == "configure-presentation":
                            assert b"InputOutput" in errors, errors
                    else:
                        assert b"not confirmed" in errors and f"rui request recover {key}".encode() in errors, errors
                else:
                    assert not added, "read command captured a mutation"
                actual = termios.tcgetattr(slave)
                if sys.platform == "darwin":
                    mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                    actual[3] &= ~mask
                    original[3] &= ~mask
                assert actual == original and not (root / "effect").exists()
                reply_release.set()
                if proxy is not None:
                    proxy.close()
                    proxy = None
                if case.startswith("configure"):
                    observed = fixture.command("request", "inspect", "--store", store, "--key", key)
                    expected = "rejected" if case == "configure-rejected" else "accepted"
                    not_admitted = route is None or case == "configure-inflight"
                    assert observed["observation"]["status"] == ("absent" if not_admitted else expected), observed
                    recovered = json.loads(human.run(home, "request", "recover", key,
                        success=case != "configure-rejected"))
                    assert recovered["answer"]["status"] == expected
                    assert recovered["answer"]["replayed"] is (not not_admitted)
                    assert record.read_bytes() == saved and set(records.glob("*.json")) - before == {record}
                assert len(endpoint.requests) == 2, "command signal replaced provider work"
                print(f"synchronous command interruption: {case} passed", flush=True)
            finally:
                dispose_all(
                    release.touch, reply_release.set,
                    lambda: stop_process(caller, timeout=5) if caller is not None else None,
                    lambda: proxy.close() if proxy is not None else None,
                    *(lambda fd=fd: os.close(fd) for fd in (master, slave, ready_read, ready_write)
                        + ((error_master, error_slave, unread_read, unread_write) if stopped else ())),
                )
                proxy = None
    finally:
        dispose_all(
            lambda: fixture.stop_host(host) if host is not None else None,
            endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
        )


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
        human.run(home, "session", "configure", "--store", store, "--session", "fatal/original",
            "--workspace", root, "--provider", "codex", "--model", "model-a")
        diagnostics = [
            (["session", "resume", "--store", str(store), "missing/fatal"], b"SessionNotConfigured"),
            (["defaults", "configure", "--provider", "unsupported"], b"UnsupportedPreferenceProvider"),
            (["--store", str(store), "--provider", "unsupported", "--model", "model-a"], b"UnsupportedSelectionProvider"),
        ]
        for args, error, stopped in ((args, error, stopped) for args, error in diagnostics for stopped in (False, True)):
            master, slave = open_pty()
            error_master, error_slave = open_pty()
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
                dispose_all(
                    lambda: stop_process(caller, timeout=5) if caller is not None else None,
                    lambda: termios.tcflow(error_slave, termios.TCOON),
                    *(lambda fd=fd: os.close(fd) for fd in (master, slave, error_master, error_slave)),
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
                caller = subprocess.Popen([str(fixture.RUI), *args],
                    env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave, stderr=write_error)
                assert caller.wait(timeout=3) == 1, "disconnected stderr replaced the real exit"
                assert termios.tcgetattr(slave) == original
                assert_file_flags(fcntl.fcntl(write_error, fcntl.F_GETFL), error_flags)
                print(f"fatal reporting: {error.decode()} disconnected stderr passed", flush=True)
            finally:
                dispose_all(
                    lambda: stop_process(caller, timeout=5) if caller is not None else None,
                    *(lambda fd=fd: os.close(fd) for fd in (master, slave, write_error)),
                )
        master, slave = open_pty()
        original = termios.tcgetattr(slave)
        try:
            caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store), "fatal/original"],
                env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            human.read_terminal(master, "› ")
            proxy = canonical.ReplyProxy(host, "/v1/message",
                lambda response: b"" if len(proxy.exchanges) == 2 else response)
            records = home / ".config/rui/requests"
            before = {path: path.read_bytes() for path in records.glob("*.json")}
            os.write(master, b"accepted A\n")
            human.read_terminal(master, "ACCEPTED-A", composer=True)
            human.terminal_step(master, "/status", "Session: ", composer=True)
            os.write(master, b"uncertain B\n")
            human.read_terminal(master, "Not confirmed")
            first, second = [json.loads(body) for body, _ in proxy.exchanges]
            saved = (home / ".config/rui/requests" / f"{second['key']}.json").read_bytes()
            os.write(master, b"\x1b[")
            output, errors = human.terminal_exit(caller, master, timeout=6)
            assert caller.returncode == 1, (output, errors)
            assert second["key"].encode() in errors and first["key"].encode() not in errors, errors
            assert b"not confirmed" in errors and b"rui request recover" in errors and b"IncompleteTerminalInput" in errors, errors
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
            dispose_all(
                lambda: stop_process(caller, timeout=5) if caller is not None else None,
                lambda: os.close(master), lambda: os.close(slave),
            )
        master, slave = open_pty()
        read_error, write_error = os.pipe()
        os.close(read_error)
        original = termios.tcgetattr(slave)
        error_flags = fcntl.fcntl(write_error, fcntl.F_GETFL)
        records_before = {path: path.read_bytes() for path in records.glob("*.json")}
        try:
            caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store), "fatal/original"],
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
            assert fixture.command("session", "inspect", "--store", store, "--session", "fatal/original")["session"]
            print("fatal reporting: acquired terminal disconnected stderr passed", flush=True)
        finally:
            dispose_all(
                lambda: stop_process(caller, timeout=5) if caller is not None else None,
                *(lambda fd=fd: os.close(fd) for fd in (master, slave, write_error)),
            )
    finally:
        dispose_all(
            lambda: proxy.close() if proxy is not None else None,
            lambda: fixture.stop_host(host) if host is not None else None,
            endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
        )


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
            fixture.sse_tool_calls(name, [("bash", name, json.dumps({"cmd": f"printf once >> effect-{name}", "timeout_ms": 1000, "description": f"Append effect-{name} marker"}))]),
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
            human.run(home, "session", "configure", "--store", store, "--session", session,
                "--workspace", root, "--provider", "codex", "--model", "model-a", "--permission-mode", "ask")
            before = {path: path.read_bytes() for path in (home / ".config/rui/requests").glob("*.json")}
            master, slave = open_pty()
            read_ready, write_ready = os.pipe()
            original = termios.tcgetattr(slave)
            reply_release, received = threading.Event(), threading.Event()
            try:
                caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store), session],
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
                proposal = human.read_terminal(master, "Type a + Enter to allow once · d + Enter to deny")
                proposal += human.action_ready(read_ready, master)
                os.write(master, b"a\n" if decision == "allow_once" else b"d\n")
                if lost:
                    assert received.wait(10)
                    caller.send_signal(signal.SIGINT)
                else:
                    human.read_terminal(master, f"SETTLED-{name}", composer=True)
                    status = human.terminal_step(master, "/status", "Session: ", composer=True)
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
                assert (b"rui request recover " if lost else b"rui request inspect ") + request["key"].encode() in errors, errors
                assert b"rui request read-result" not in errors, errors
                assert (b"Decision not confirmed" if lost else b"Decision accepted; do not repeat it") in errors, errors
                if not lost:
                    assert b"IncompleteTerminalInput" in errors and b"not confirmed" not in errors, errors
                if lost:
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
                actual = termios.tcgetattr(slave)
                if sys.platform == "darwin":
                    mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                    actual[3] &= ~mask
                    original[3] &= ~mask
                assert actual == original
                print(f"decision reporting: {name} passed", flush=True)
            finally:
                if sys.exc_info()[0] is not None:
                    preserve_failure_metadata(root / "pty-failure.json", lambda: {
                        "case": name, "error": sys.exc_info()[0].__name__,
                        "caller_returncode": caller.poll() if caller is not None else None,
                        "ready_pending": bool(select.select([read_ready], [], [], 0)[0]),
                        "terminal_pending": bool(select.select([master], [], [], 0)[0]),
                        "reply_released": reply_release.is_set(),
                        "exchanges": len(proxy.exchanges) if proxy is not None else 0,
                    })
                dispose_all(
                    reply_release.set,
                    lambda: stop_process(caller, timeout=5) if caller is not None else None,
                    lambda: proxy.close() if proxy is not None else None,
                    *(lambda fd=fd: os.close(fd) for fd in (master, slave, read_ready, write_ready)),
                )
                proxy = None
    finally:
        dispose_all(
            lambda: fixture.stop_host(host) if host is not None else None,
            endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
        )


def entry_enable_cases(state, library):
    """Failed acquisition restores each attempted descriptor, without alias masking."""
    root = state / "entry-enable"
    root.mkdir()
    home, store = root / "home", root / "store"
    home.mkdir(mode=0o700)
    host = fixture.start_host(store, None)
    try:
        human.run(home, "session", "configure", "--store", store, "--session", "entry/enable",
            "--workspace", root, "--provider", "codex", "--model", "model-a")
        before = {path: path.read_bytes() for path in (home / ".config/rui/requests").glob("*.json")}
        for target in (0, 1):
            for mode in ("mutated", "unmutated", "mutated-reset"):
                name = f"entry-{target}-{mode}"
                input_master, input_slave = open_pty()
                output_master, output_slave = open_pty()
                slaves = (input_slave, output_slave)
                flags = [fcntl.fcntl(fd, fcntl.F_GETFL) for fd in slaves]
                original = termios.tcgetattr(input_slave)
                log = root / f"{name}.log"
                caller = None
                try:
                    caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store), "entry/enable"],
                        env={**os.environ, "HOME": str(home),
                            "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
                            "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": name},
                        stdin=input_slave, stdout=output_slave, stderr=subprocess.PIPE)
                    _, errors = caller.communicate(timeout=6)
                    assert caller.returncode == 1 and b"TerminalCleanupFailed" in errors, errors
                    assert b"Detached" not in errors and b"accepted" not in errors, errors
                    assert termios.tcgetattr(input_slave) == original
                    for fd, saved, index in zip(slaves, flags, (0, 1)):
                        assert_file_flags(fcntl.fcntl(fd, fcntl.F_GETFL),
                            saved | os.O_NONBLOCK if index == target and mode == "mutated-reset" else saved)
                    events = log.read_text()
                    assert events.count("entry-enable\n") == 1 and events.count("entry-restore\n") == 1, events
                    assert events.count("entry-mutated\n") == (mode != "unmutated"), events
                    assert events.count("entry-restored\n") == (mode != "mutated-reset"), events
                    assert {path: path.read_bytes() for path in (home / ".config/rui/requests").glob("*.json")} == before
                    print(f"entry enable: {name} exact flags, unchanged termios, no intent and cleanup error passed", flush=True)
                finally:
                    if sys.exc_info()[0] is not None:
                        preserve_failure_metadata(root / "pty-failure.json", lambda: {
                            "case": name, "caller_returncode": caller.poll() if caller else None,
                            "flags": [fcntl.fcntl(fd, fcntl.F_GETFL) for fd in slaves],
                            "saved_flags": flags, "termios_unchanged": termios.tcgetattr(input_slave) == original})
                    dispose_all(
                        lambda: stop_process(caller, timeout=5) if caller is not None else None,
                        *(lambda fd=fd: os.close(fd) for fd in (input_master, input_slave, output_master, output_slave)),
                    )
    finally:
        fixture.stop_host(host)


def detach_reporting_cases(state, library):
    """A post-restoration notice error cannot erase an accepted intent."""
    root = state / "detach-reporting"
    root.mkdir()
    home, store = root / "home", root / "store"
    home.mkdir(mode=0o700)
    # Syscall permutations live with SessionTerminal. These cases own the
    # frontend handoff: exact accepted identity, no resend and saved recovery.
    # Departure and guide tests cover reporting policy for both intent kinds.
    # Retain both notice outcomes, both guide kinds and both actual decisions,
    # without repeating their Cartesian product through a Host and PTY.
    cases = [("message", "detach-enable-mutated-reset"), ("message", "detach-write-full"),
             ("allow_once", "detach-enable-mutated-reset"), ("deny", "detach-write-full")]
    responses = []
    for kind, fault in cases:
        name = f"{kind}-{fault}"
        if kind != "message":
            responses.append(fixture.sse_tool_calls(name, [("bash", name, json.dumps({"cmd": f"printf once >> effect-{name}", "timeout_ms": 1000, "description": f"Append effect-{name} marker"}))]))
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
            human.run(home, "session", "configure", "--store", store, "--session", session,
                "--workspace", root, "--provider", "codex", "--model", "model-a", "--permission-mode", "ask")
            master, slave = open_pty()
            read_ready, write_ready = os.pipe()
            original, flags = termios.tcgetattr(slave), fcntl.fcntl(slave, fcntl.F_GETFL)
            log, arm = root / f"{name}.log", root / f"{name}.arm"
            try:
                caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store), session],
                    env={**os.environ, "HOME": str(home), "RUI_TEST_ACTION_READY_FD": str(write_ready),
                        "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
                        "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": fault, "RUI_TERMINAL_DETACH_ARM": str(arm)},
                    pass_fds=(write_ready,), stdin=slave, stdout=slave, stderr=subprocess.PIPE)
                human.read_terminal(master, "› ")
                proxy = canonical.ReplyProxy(host, "/v1/message", lambda response: response)
                os.write(master, b"accepted original\n")
                if kind != "message":
                    proposal = human.read_terminal(master, "Type a + Enter to allow once · d + Enter to deny")
                    proposal += human.action_ready(read_ready, master)
                    os.write(master, b"a\n" if kind == "allow_once" else b"d\n")
                human.read_terminal(master, f"SETTLED-{name}", composer=True)
                status = human.terminal_step(master, "/status", "Session: ", composer=True)
                assert "Original reserved request:" not in status, status
                before = {path: path.read_bytes() for path in (home / ".config/rui/requests").glob("*.json")}
                records = [path for path in before if json.loads(before[path]).get("session") == session]
                intent_kind = "message" if kind == "message" else "permission_decision"
                record, = [path for path in records if json.loads(before[path])["kind"] == intent_kind]
                request = json.loads(before[record])
                arm.touch()
                os.write(master, b"\x03")
                output, errors = human.terminal_exit(caller, master)
                guide = b"Message accepted; do not resubmit it" if kind == "message" else b"Decision accepted; do not repeat it"
                if fault == "detach-write-full":
                    assert caller.returncode == 0 and not errors, (output, errors)
                    assert b"Detached. Host work continues." in output and session.encode() in output, output
                else:
                    assert caller.returncode == 1 and b"TerminalCleanupFailed" in errors, (output, errors)
                    assert guide in errors and request["key"].encode() in errors, errors
                    assert (b"rui request read-result " if kind == "message" else b"rui request inspect ") + request["key"].encode() in errors
                assert "cleanup-flags-restored\ndetach-enable\n" in log.read_text(), log.read_text()
                assert log.read_text().count("detach-enable\n") == 1
                if fault.startswith("detach-write-"):
                    assert log.read_text().count("detach-write\n") == 1, "notice write was retried"
                    assert "detach-write-blocking" not in log.read_text(), log.read_text()
                assert_file_flags(fcntl.fcntl(slave, fcntl.F_GETFL),
                    flags | os.O_NONBLOCK if fault.endswith("reset") else flags)
                assert log.read_text().count("detach-reset\n") == 1
                if fault.startswith("detach-enable"):
                    assert b"Detached. Host work continues." not in output, output
                if "mutated" in fault:
                    assert log.read_text().count("detach-mutated\n") == 1
                actual = termios.tcgetattr(slave)
                if sys.platform == "darwin":
                    mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                    actual[3] &= ~mask
                    original[3] &= ~mask
                assert actual == original
                assert {path: path.read_bytes() for path in (home / ".config/rui/requests").glob("*.json")} == before
                messages = [before[path] for path in records if json.loads(before[path])["kind"] == "message"]
                assert proxy.mutations == [("/v1/message", messages[0])] + ([] if kind == "message" else [("/v1/control/permission-decision", before[record])])
                proxy.close()
                proxy = None
                assert json.loads(human.run(home, "request", "recover", request["key"]))["answer"]["replayed"] is True
                effect = root / f"effect-{name}"
                assert (effect.read_bytes() if effect.exists() else b"") == (b"once" if kind == "allow_once" else b"")
                print(f"detach reporting: {name} exact accepted guide, restored termios and saved replay passed", flush=True)
            finally:
                if sys.exc_info()[0] is not None:
                    preserve_failure_metadata(root / "pty-failure.json", lambda: {
                        "case": name, "error": sys.exc_info()[0].__name__,
                        "caller_returncode": caller.poll() if caller is not None else None,
                        "ready_pending": bool(select.select([read_ready], [], [], 0)[0]),
                        "terminal_pending": bool(select.select([master], [], [], 0)[0]),
                        "flags": fcntl.fcntl(slave, fcntl.F_GETFL), "saved_flags": flags,
                        "exchanges": len(proxy.exchanges) if proxy is not None else 0,
                    })
                dispose_all(
                    lambda: stop_process(caller, timeout=5) if caller is not None else None,
                    lambda: proxy.close() if proxy is not None else None,
                    *(lambda fd=fd: os.close(fd) for fd in (master, slave, read_ready, write_ready)),
                )
                proxy = None
    finally:
        dispose_all(
            lambda: fixture.stop_host(host) if host is not None else None,
            endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
        )


def startup_reporting_cases(state, library):
    """Initial launch is definitely unsent; failed retry retains uncertainty."""
    for kind in ("message", "allow_once", "deny", "message-restore", "retry"):
        root = state / f"startup-{kind}"
        root.mkdir()
        home, store = root / "home", root / "store"
        home.mkdir(mode=0o700)
        responses = [fixture.sse_answer("seed", "seed-r", "seed-m", "SEED-ACCEPTED")[0]]
        if kind in ("allow_once", "deny"):
            responses.append(fixture.sse_tool_calls("choice", [("bash", "choice-call", json.dumps({"cmd": "touch must-not-run", "timeout_ms": 1000, "description": "Create must-not-run marker"}))]))
        elif kind == "retry":
            responses.append(fixture.sse_answer("retry", "retry-r", "retry-m", "ORIGINAL-ACCEPTED")[0])
        endpoint = fixture.SuccessEndpoint(responses)
        thread = threading.Thread(target=endpoint.serve_forever)
        thread.start()
        host = caller = proxy = None
        held, release = threading.Event(), threading.Event()
        master, slave = open_pty()
        ready_read, ready_write = os.pipe()
        original = termios.tcgetattr(slave)
        arm, log = root / "arm", root / "probe.log"
        try:
            host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
            human.run(home, "session", "configure", "--store", store, "--session", "startup/case",
                "--workspace", root, "--provider", "codex", "--model", "model-a", "--permission-mode", "ask")
            caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store), "startup/case"],
                env={**os.environ, "HOME": str(home), "RUI_TEST_ACTION_READY_FD": str(ready_write),
                    "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
                    "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": "startup-restore" if kind == "message-restore" else "startup",
                    "RUI_TERMINAL_STARTUP_ARM": str(arm)},
                pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            human.read_terminal(master, "› ")
            os.write(master, b"seed accepted original\n")
            human.read_terminal(master, "SEED-ACCEPTED", composer=True)
            assert "Original reserved request:" not in human.terminal_step(master, "/status", "Session: ", composer=True)
            human.return_to_live(master)
            if kind in ("allow_once", "deny"):
                os.write(master, b"propose exact Action\n")
                proposal = human.read_terminal(master, "Type a + Enter to allow once · d + Enter to deny")
                proposal += human.action_ready(ready_read, master)
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
                assert b"rui request recover " not in errors and b"rui request read-result " not in errors and b"reserved key" not in errors, errors
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
                assert json.loads(human.run(home, "request", "recover", request["key"]))["answer"]["replayed"] is True
            print(f"startup reporting: {kind} exact custody, publication/mutation conservation and cleanup precedence passed", flush=True)
        finally:
            if sys.exc_info()[0] is not None:
                preserve_failure_metadata(root / "pty-failure.json", lambda: {
                    "case": kind, "error": sys.exc_info()[0].__name__,
                    "caller_returncode": caller.poll() if caller is not None else None,
                    "ready_pending": bool(select.select([ready_read], [], [], 0)[0]),
                    "terminal_pending": bool(select.select([master], [], [], 0)[0]),
                    "reply_released": release.is_set(),
                    "exchanges": len(proxy.exchanges) if proxy is not None else 0,
                })
            dispose_all(
                release.set,
                lambda: stop_process(caller, timeout=5) if caller is not None else None,
                lambda: proxy.close() if proxy is not None else None,
                lambda: termios.tcsetattr(slave, termios.TCSANOW, original),
                *(lambda fd=fd: os.close(fd) for fd in (master, slave, ready_read, ready_write)),
                lambda: fixture.stop_host(host) if host is not None else None,
                endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
            )


def visible_stream_handoff_cases(state, library):
    """A command during held visible output waits, then runs once."""
    marker = "VISIBLE-CANCEL-PREFIX"
    # The marker opens and closes the content: views from the top (history,
    # details) and from the end (opening, live) both draw it first.
    long = marker + "\n" + "complete saved content\n" * 240 + marker + "\nVISIBLE-END"
    for phase in ("opening", "activity", "history", "details", "interrupt", "completion", "permission"):
        root = state / f"visible-{phase}"
        root.mkdir()
        home, store = root / "home", root / "store"
        home.mkdir(mode=0o700)
        text = json.dumps({"cmd": "echo " + marker + " # " + "x" * 6000, "timeout_ms": 1000, "description": "Print visible permission marker"})
        responses = [fixture.sse_tool_calls("visible", [("bash", "visible-call", text)])] if phase == "permission" else [
            fixture.sse_answer("visible", "visible-r", "visible-m", long)[0]]
        if phase == "history":
            responses += [fixture.sse_answer(f"short-{i}", f"short-{i}-r", f"short-{i}-m", "OPENING-READY")[0] for i in range(8)]
        endpoint = fixture.SuccessEndpoint(responses)
        thread = threading.Thread(target=endpoint.serve_forever)
        thread.start()
        host = caller = None
        master, slave = open_pty()
        original = termios.tcgetattr(slave)
        flags = fcntl.fcntl(slave, fcntl.F_GETFL)
        arm, log = root / "arm", root / "probe.log"
        try:
            host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
            human.run(home, "session", "configure", "--store", store, "--session", "visible/stream",
                "--workspace", root, "--provider", "codex", "--model", "model-a", "--permission-mode", "ask")
            if phase not in ("activity", "permission", "interrupt", "completion"):
                for i in range(len(responses)):
                    admission = human.admit(home, "session", "send", "--store", store, "--session", "visible/stream", f"saved input {i}")
                    fixture.wait_for(lambda: fixture.completed_observation(store, admission["request"]), "saved stream content")
            if phase == "opening": arm.touch()
            caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store), "visible/stream"],
                env={**os.environ, "HOME": str(home), "NO_COLOR": "1",
                    "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
                    "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": "visible-stream", "RUI_TERMINAL_STREAM_ARM": str(arm)},
                stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            if phase != "opening":
                ready = "VISIBLE-END" if phase == "details" else "OPENING-READY" if phase == "history" else "› "
                human.read_terminal(master, ready, composer=True)
                arm.touch()
                os.write(master, (f"/{phase}\n" if phase in ("history", "details") else "produce content\n").encode())
            human.read_terminal(master, marker)
            before = {path: path.read_bytes() for path in (home / ".config/rui/requests").glob("*.json")}
            if phase == "completion":
                # A live page shows whole: its marker frame already ends the
                # content. The typed input's own redraw is the first held
                # write, and the command runs only once that output completes.
                human.await_screen(master, "VISIBLE-END", composer=True)
                os.write(master, b"/configure --permission-mode bypass\nUNREAD suffix\n")
                fixture.wait_for(lambda: log.exists() and "visible-stream-held" in log.read_text(), "post-page output gate")
                time.sleep(0.5)
                assert fixture.command("session", "inspect", "--store", store,
                    "--session", "visible/stream")["session"]["permission_mode"] == "ask"
                arm.unlink()
                human.read_terminal(master, "Configured.", composer=True)
                human.await_screen(master, "› UNREAD suffix", composer=True)
                records = {path: path.read_bytes() for path in (home / ".config/rui/requests").glob("*.json")}
                assert all(records.get(path) == value for path, value in before.items())
                added = [json.loads(value) for path, value in records.items() if path not in before]
                assert len(added) == 1 and "configuration" in added[0], "completed command captured its suffix"
                assert fixture.command("session", "inspect", "--store", store,
                    "--session", "visible/stream")["session"]["permission_mode"] == "bypass"
                os.write(master, b"\x03")
                tail, errors = human.terminal_exit(caller, master)
                assert caller.returncode == 0, (tail, errors)
            else:
                command = b"/inspect-action\n" if phase == "permission" else b"/status\n"
                os.write(master, command)
                # An unchanged frame writes nothing, so the typed command's
                # own redraw may be the first held write.
                fixture.wait_for(lambda: log.exists() and "visible-stream-held" in log.read_text(), "post-prefix output gate")
                # Held output owns the terminal: the command stays pending,
                # with no dispatch, capture or provider work meanwhile.
                time.sleep(0.5)
                assert caller.poll() is None, (phase, caller.stderr.read())
                assert {path: path.read_bytes() for path in (home / ".config/rui/requests").glob("*.json")} == before
                assert len(endpoint.requests) == len(responses)
                if phase == "interrupt":
                    os.write(master, b"\x03")
                    tail, errors = human.terminal_exit(caller, master)
                    # Without output credit, cleanup cannot claim delivery: an
                    # explicit failure that still names exact recovery.
                    assert caller.returncode == 1 and b"error: TerminalCleanupFailed" in errors, (phase, tail, errors)
                    assert b"Use rui request read-result " in errors and b"Resume: rui session resume --store " in errors, errors
                    assert b"Session: visible/stream" not in tail, "interrupted pending command ran"
                else:
                    arm.unlink()
                    # Long pages open at their top; the exact Action's inspection starts there.
                    expected = "Bash arguments: " if phase == "permission" else "Session: visible/stream"
                    page = human.read_terminal(master, expected)
                    shown = human.current_screen(master)
                    assert expected in shown or expected in page, (phase, shown)
                    os.write(master, b"\x03")
                    tail, errors = human.terminal_exit(caller, master)
                    assert caller.returncode == 0, (phase, tail, errors)
                assert b"Cancelled" not in errors, (phase, errors)
                assert {path: path.read_bytes() for path in (home / ".config/rui/requests").glob("*.json")} == before
            actual = termios.tcgetattr(slave)
            if sys.platform == "darwin":
                mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                actual[3] &= ~mask
                original[3] &= ~mask
            assert actual == original
            assert_file_flags(fcntl.fcntl(slave, fcntl.F_GETFL), flags)
            assert "restore-other" in log.read_text() and "disable" in log.read_text()
            assert len(endpoint.requests) == len(responses), "held output restarted Host work"
            print(f"visible {phase}: " + ("completed output permits one command; suffix stays a draft" if phase == "completion"
                else "Ctrl-C while held restores and the pending command never runs" if phase == "interrupt"
                else "pending command waits for held output, then runs once without capture or provider work"), flush=True)
        finally:
            def join_endpoint():
                thread.join(timeout=5)
                assert not thread.is_alive()

            dispose_all(
                lambda: stop_process(caller, timeout=5) if caller is not None else None,
                lambda: termios.tcsetattr(slave, termios.TCSANOW, original),
                lambda: os.close(master), lambda: os.close(slave),
                lambda: fixture.stop_host(host) if host is not None else None,
                endpoint.shutdown, endpoint.server_close, join_endpoint,
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
                assert fixture.command("session", "inspect", "--store", root / "store", "--session", "alias/session")["session"]
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
        contention_inspections = ["diagnostic/session-extra", "diagnostic/session", "diagnostic/session"]
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
                *(["--test-phase-trace"] if fault == "success" or credit in ("diagnostic-contention-host", "diagnostic-partial") else [])), env=env, stderr_pipe=(reader, write_fd),
                observations="control" if credit == "diagnostic-contention-host" else None,
                required_fields={"execution": "enabled", "curl": "8.22.0"})
            session = "diagnostic/session"
            fixture.configure(root, store, "config", session, "model-a")
            if credit == "diagnostic-contention-host":
                fixture.configure(root, store, "config-other", "diagnostic/session-extra", "model-a")
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
                assert "diagnostic-partial\n" in log.read_text()
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
                unrelated = fixture.start_command("session", "inspect", "--store", store, "--session", "diagnostic/session-extra")
                inspectors.append(unrelated)
                out, err = unrelated.communicate(timeout=control_remaining())
                assert unrelated.returncode == 0 and json.loads(out)["session"]["reference"] == "diagnostic/session-extra", (out, err)
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
                        assert database.execute("SELECT uncertain,resolution_code FROM model_operation").fetchone() == (1, None)
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
                    stopped = subprocess.run([str(fixture.RUI), "host", "stop", "--store", str(store), "--instance", instance],
                        capture_output=True, text=True, timeout=8)
                    (root / "host-stop.stdout").write_text(stopped.stdout)
                    (root / "host-stop.stderr").write_text(stopped.stderr)
                    assert stopped.returncode == 0, stopped
                    stop_reply = json.loads(stopped.stdout)
                    assert {key: stop_reply[key] for key in ("type", "status", "instance", "retirement")} == {
                        "type": "host_stop", "status": "acknowledged", "instance": instance, "retirement": "unconfirmed"}, stopped
                    assert "stop affects all work in this Store" in stopped.stderr, stopped
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


def native_notice_cases(state):
    """Exercise the public notice's libc adapter without a Host or interposer."""
    binary = pathlib.Path(os.environ["RUI_TEST_TERMINAL_NOTICE"]).resolve()
    expected = b"\nDetached. Host work continues.\nResume: rui session resume --store $'/tmp/a\\' path' -- $'--session'\n"
    for transport, full in (("pipe", False), ("pipe", True), ("pty", False)):
        # PTY EAGAIN is not persistent: internal delivery can make space without
        # a reader. A full pipe with no reader owns the backpressure witness.
        reader, writer = os.pipe() if transport == "pipe" else open_pty()
        try:
            if transport == "pty":
                attrs = termios.tcgetattr(writer)
                attrs[1] &= ~termios.OPOST
                termios.tcsetattr(writer, termios.TCSANOW, attrs)
            flags = fcntl.fcntl(writer, fcntl.F_GETFL)
            filled = 0
            if full:
                fcntl.fcntl(writer, fcntl.F_SETFL, flags | os.O_NONBLOCK)
                while True:
                    try:
                        filled += os.write(writer, b"x" * 1024)
                        assert filled < 1024 * 1024, "unbounded fixture output"
                    except BlockingIOError:
                        break
                fcntl.fcntl(writer, fcntl.F_SETFL, flags)
            result = subprocess.run([str(binary)], stdout=writer, stderr=subprocess.PIPE, timeout=5)
            assert_file_flags(fcntl.fcntl(writer, fcntl.F_GETFL), flags)
            assert result.returncode == (1 if full else 0), result.stderr
            if full:
                assert b"TerminalCleanupFailed" in result.stderr, result.stderr
            else:
                assert not result.stderr, result.stderr
            # Read only after the actor exits. Bound reads even on a broken
            # adapter, and reject extra/missing bytes, not just a prefix.
            fcntl.fcntl(reader, fcntl.F_SETFL, fcntl.fcntl(reader, fcntl.F_GETFL) | os.O_NONBLOCK)
            actual = bytearray()
            while True:
                try:
                    chunk = os.read(reader, 4096)
                    if not chunk:
                        break
                    actual.extend(chunk)
                    assert len(actual) <= max(filled, len(expected)), "extra notice bytes"
                except BlockingIOError:
                    break
            assert actual == (b"x" * filled if full else expected), actual
            print(f"native notice: {transport} full={full}, exact bytes and restored flags passed", flush=True)
        finally:
            dispose_all(lambda: os.close(reader), lambda: os.close(writer))


def main(selected=None):
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-terminal-restoration."))
    home = state / "home"
    home.mkdir()
    store = state / "store"
    host = None
    completed = False
    try:
        if selected in (None, "input-replay"):
            from terminal_input_replay import input_replay_cases
            input_replay_cases()
        if selected == "input-replay":
            completed = True
            return
        if selected in (None, "notice", "detach"):
            native_notice_cases(state)
        if selected == "notice":
            completed = True
            return
        source, library = state / "probe.c", state / "probe.so"
        source.write_text(PROBE)
        subprocess.run(["cc", "-dynamiclib" if sys.platform == "darwin" else "-shared",
            "-fPIC", str(source), *(["-ldl"] if sys.platform == "linux" else []), "-o", str(library)], check=True)
        check_forwarding(state, library)
        if selected == "forwarding":
            completed = True
            return
        if selected in (None, "capture-receipt"):
            capture_receipt_case(state, library)
        if selected == "capture-receipt":
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
        if selected in (None, "commands"):
            command_interruption_cases(state, library)
        if selected == "commands":
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
        if selected in (None, "entry-enable"):
            entry_enable_cases(state, library)
        if selected == "entry-enable":
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
        human.run(home, "session", "configure", "--store", store, "--session", "terminal/restoration",
            "--workspace", state, "--provider", "codex", "--model", "model-a")
        if selected in (None, "renderer-backpressure"):
            renderer_backpressure_case(state, library, home, store)
        if selected == "renderer-backpressure":
            completed = True
            return
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
