#!/usr/bin/env python3
"""Production persistent capture, read and fresh-choice cancellation custody.

Directory-sync and tcdrain gates inject native waits, not disk/kernel drainage
stalls or end-to-end cancellation bounds. Legacy #423 is tested separately.
"""
import fcntl
import json
import os
import pathlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

import dispatch_integration as host
from canonical_failure_integration import ReplyProxy
from host_process import canonical_fixture_root, assert_persistent_terminal_restored
from session_opening_integration import Terminal, configure


PROBE = r"""
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <termios.h>
#include <unistd.h>

static int probe_fsync(int fd) {
#ifdef __APPLE__
    int (*forward)(int) = fsync;
#else
    int (*forward)(int) = dlsym(RTLD_NEXT, "fsync");
#endif
    if (!forward || forward == probe_fsync) _exit(90);
    struct stat value;
    char path[4096];
    static int held = 0;
    if (fstat(fd, &value)) _exit(91);
    if (S_ISDIR(value.st_mode)) {
#ifdef __APPLE__
        if (fcntl(fd, F_GETPATH, path)) _exit(92);
#else
        char link[64];
        snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
        ssize_t n = readlink(link, path, sizeof(path) - 1);
        if (n < 0) _exit(92);
        path[n] = 0;
#endif
        if (!held && getenv("RUI_CANCEL_RECORDS") && !strcmp(path, getenv("RUI_CANCEL_RECORDS"))) {
            held = 1;
            char ready[4096], release[4096];
            snprintf(ready, sizeof(ready), "%s.ready", getenv("RUI_CANCEL_GATE"));
            snprintf(release, sizeof(release), "%s.release", getenv("RUI_CANCEL_GATE"));
            int marker = open(ready, O_WRONLY | O_CREAT | O_EXCL, 0600);
            if (marker < 0 || close(marker)) _exit(93);
            while (access(release, F_OK)) usleep(1000);
            if (!strcmp(getenv("RUI_CANCEL_FAULT"), "sync")) { errno = EIO; return -1; }
        }
    }
    return forward(fd);
}

static int probe_tcsetattr(int fd, int action, const struct termios *attrs) {
#ifdef __APPLE__
    int (*forward)(int, int, const struct termios *) = tcsetattr;
#else
    int (*forward)(int, int, const struct termios *) = dlsym(RTLD_NEXT, "tcsetattr");
#endif
    if (!forward || forward == probe_tcsetattr) _exit(94);
    if (fd == 0 && action == TCSANOW && (attrs->c_lflag & ICANON) &&
        !strcmp(getenv("RUI_CANCEL_FAULT"), "restore")) { errno = ENOTTY; return -1; }
    return forward(fd, action, attrs);
}

static int probe_tcdrain(int fd) {
#ifdef __APPLE__
    int (*forward)(int) = tcdrain;
#else
    int (*forward)(int) = dlsym(RTLD_NEXT, "tcdrain");
#endif
    if (!forward || forward == probe_tcdrain) _exit(95);
    const char *gate = getenv("RUI_CANCEL_DRAIN_GATE");
    static int held = 0;
    if (gate && fd == 1 && !held) {
        held = 1;
        char ready[4096], release[4096];
        snprintf(ready, sizeof(ready), "%s.ready", gate);
        snprintf(release, sizeof(release), "%s.release", gate);
        int marker = open(ready, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (marker < 0 || close(marker)) _exit(96);
        while (access(release, F_OK)) usleep(1000);
    }
    // This is an injected native wait, not evidence of kernel drainage.
    // Always perform the actual drain; never manufacture fresh-choice success.
    return forward(fd);
}

#ifdef __APPLE__
#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *new_fn; const void *old_fn; } \
    pair_##original __attribute__((section("__DATA,__interpose"))) = \
        { (const void *)&replacement, (const void *)&original };
INTERPOSE(probe_fsync, fsync)
INTERPOSE(probe_tcsetattr, tcsetattr)
INTERPOSE(probe_tcdrain, tcdrain)
#else
int fsync(int fd) { return probe_fsync(fd); }
int tcsetattr(int fd, int action, const struct termios *attrs) { return probe_tcsetattr(fd, action, attrs); }
int tcdrain(int fd) { return probe_tcdrain(fd); }
#endif
"""


def cases(state, home, store, workspace, owner):
    source, library = state / "cancel-probe.c", state / "cancel-probe.so"
    source.write_text(PROBE)
    subprocess.run(["cc", "-dynamiclib" if sys.platform == "darwin" else "-shared",
        "-fPIC", str(source), *(["-ldl"] if sys.platform == "linux" else []),
        "-o", str(library)], check=True)
    configure(home, store, workspace, "opening/cancel")
    records = home / ".config/rui/requests"
    for case in ("release", "interrupt", "incomplete", "resize", "restore", "sync"):
        gate = state / ("cancel-" + case)
        before = set(records.glob("*.json"))
        terminal = Terminal(home, store, "opening/cancel", environment={
            "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
            "RUI_CANCEL_RECORDS": str(records), "RUI_CANCEL_GATE": str(gate),
            "RUI_CANCEL_FAULT": case}, stderr=subprocess.PIPE)
        try:
            terminal.until("rui> ", 0)
            terminal.send("ORIGINAL-CANCEL-é🙂\n")
            host.wait_for(lambda: pathlib.Path(str(gate) + ".ready").exists(), "capture directory sync held")
            created = set(records.glob("*.json")) - before
            assert len(created) == 1, created
            record = created.pop()
            original = record.read_bytes()
            saved = json.loads(original)
            assert saved["session"] == "opening/cancel" and saved["kind"] == "message", saved
            assert saved["text"] == {"state": "value", "value": "ORIGINAL-CANCEL-é🙂"}, saved
            start = len(terminal.transcript)
            terminal.send("NEXT-é🙂\x1b[DKEPT")
            # Capture services logical edits without rendering the borrowed
            # sealed bank. Observe native consumption, not an invented echo.
            def consumed():
                return struct.unpack("I", fcntl.ioctl(terminal.slave, termios.FIONREAD, struct.pack("I", 0)))[0] == 0
            host.wait_for(consumed, "next composition consumed during held capture")
            assert terminal.process.poll() is None, "capture borrower ended before release"
            if case == "release":
                pathlib.Path(str(gate) + ".release").touch()
                terminal.until("NEXT-éKEPT🙂", start)
                # Require a settled footer carrying THIS next draft, not the
                # unread initial idle footer or a still-submitting repaint.
                settled = rb"\rRui: (?!submitting|unconfirmed|rejected|capture failed)[^\r\n]*\r\r\nrui> NEXT-" + "éKEPT🙂".encode() + rb"\r\x1b\["
                while not re.search(settled, terminal.transcript[start:]):
                    assert terminal.read(), terminal.transcript
                terminal.send("\n")
                host.wait_for(lambda: len(set(records.glob("*.json")) - before) == 2, "next draft captured after exact join")
                next_record = (set(records.glob("*.json")) - before - {record}).pop()
                assert json.loads(next_record.read_bytes())["text"] == {"state": "value", "value": "NEXT-éKEPT🙂"}
                terminal.send("\x03")
                terminal.finish()
                assert record.read_bytes() == original
                print("persistent capture: release preserved sealed original and next Unicode draft/cursor")
                continue
            # Hold actual output credit, not a fake tcdrain return. Cancellation
            # must restore while this flow and the capture worker remain held.
            termios.tcflow(terminal.slave, termios.TCOOFF)
            if case == "resize":
                fcntl.ioctl(terminal.slave, termios.TIOCSWINSZ, struct.pack("HHHH", 1, 1, 0, 0))
            # Logical next-bank edits need not paint during capture. A resize
            # must not prevent cancellation; partial-frame resize failure is
            # independently exercised by session_opening_integration.
            os.write(terminal.master, b"\x1b[" if case == "incomplete" else b"\x03")
            def restored():
                flags = fcntl.fcntl(terminal.slave, fcntl.F_GETFL)
                # Darwin may retain kernel-owned FWASWRITTEN (xnu fcntl.h).
                ignored = 0x10000 if sys.platform == "darwin" else 0
                if (flags ^ terminal.original_flags) & ~ignored: return False
                if case != "restore":
                    try: assert_persistent_terminal_restored(terminal.slave, terminal.original)
                    except AssertionError: return False
                return True
            deadline = time.monotonic() + 5
            while not restored() and time.monotonic() < deadline:
                time.sleep(.01)
            assert restored(), "persistent restoration waited for output or borrower release"
            assert terminal.process.poll() is None, "held capture borrower was abandoned"
            assert record.read_bytes() == original, "cancellation rewrote captured intent"
            facts = host.command("observe-command", "--store", store, "--key", saved["key"])
            assert facts["observation"]["status"] == "absent", "cancelled capture was sent"
            pathlib.Path(str(gate) + ".release").touch()
            # Successful cancellation must reap even with output still stopped.
            terminal.process.wait(timeout=5)
            termios.tcflow(terminal.slave, termios.TCOON)
            if case == "restore":
                assert not termios.tcgetattr(terminal.slave)[3] & termios.ICANON
                # The asserted failed restore is fatal. Repair only this
                # disposable PTY after the writer was reaped, for teardown.
                termios.tcsetattr(terminal.slave, termios.TCSANOW, terminal.original)
            terminal.finish(nonzero=case not in ("interrupt", "resize"))
            output = terminal.process.stderr.read()
            if case == "restore": assert b"TerminalRestoreFailed" in output, output
            if case == "sync": assert b"RecordDirectorySyncFailed" in output, output
            if case == "incomplete": assert b"IncompleteTerminalInput" in output, output
            assert record.read_bytes() == original, "worker finalization replaced original record"
            print("persistent cancellation:", case, "restored before held worker release; joined before exit")
        finally:
            pathlib.Path(str(gate) + ".release").touch()
            termios.tcflow(terminal.slave, termios.TCOON) if terminal.slave is not None else None
            terminal.close()
    custody_controls(state, home, store, owner, library, records)


def wait_local(terminal, predicate, label):
    deadline = time.monotonic() + min(5, terminal.remaining())
    while not predicate() and time.monotonic() < deadline:
        time.sleep(.01)
    assert predicate(), label


def restored(terminal):
    try:
        assert_persistent_terminal_restored(terminal.slave, terminal.original, terminal.original_flags)
    except AssertionError:
        return False
    return True


def custody_controls(state, home, store, owner, library, records):
    for case, cancel in (("interrupt", "\x03"), ("incomplete", "\x1b[")):
        gate = state / ("drain-" + case)
        before = {path: path.read_bytes() for path in records.glob("*.json")}
        terminal = Terminal(home, store, "opening/cancel", environment={
            "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
            "RUI_CANCEL_DRAIN_GATE": str(gate), "RUI_CANCEL_FAULT": "none"}, stderr=subprocess.PIPE)
        try:
            terminal.until("rui> ", 0)
            terminal.send("/login\nd\n")
            wait_local(terminal, lambda: pathlib.Path(str(gate) + ".ready").exists(),
                       "production fresh-choice tcdrain not reached")
            termios.tcflow(terminal.slave, termios.TCOOFF)
            terminal.send(cancel)
            wait_local(terminal, lambda: restored(terminal),
                       "approval drain restoration waited for native gate release")
            assert terminal.process.poll() is None, "native drain borrower abandoned instead of joined"
            assert not os.path.exists(str(gate) + ".release")
            pathlib.Path(str(gate) + ".release").touch()
            terminal.process.wait(timeout=terminal.remaining())
            assert restored(terminal), "native drain join changed restored configuration/flags"
            termios.tcflow(terminal.slave, termios.TCOON)
            terminal.finish(nonzero=case == "incomplete")
            if case == "incomplete":
                assert b"IncompleteTerminalInput" in terminal.process.stderr.read()
            assert b"Login deferred" not in terminal.transcript, "typeahead bypassed fresh choice"
            assert not (home / ".config/rui/codex.json").exists()
            assert {path: path.read_bytes() for path in records.glob("*.json")} == before
            print("persistent approval drain:", case,
                  "restored before injected native wait release; real tcdrain forwarded; reaped with TCOOFF")
        finally:
            pathlib.Path(str(gate) + ".release").touch()
            if terminal.slave is not None: termios.tcflow(terminal.slave, termios.TCOON)
            terminal.close()

    for case, cancel in (("interrupt", "\x03"), ("incomplete", "\x1b[")):
        terminal = Terminal(home, store, "opening/cancel", stderr=subprocess.PIPE)
        release, ready = threading.Event(), threading.Event()
        proxy = None
        before = {path: path.read_bytes() for path in records.glob("*.json")}
        def hold_reply(response):
            ready.set()  # Real Host request forwarded and entire reply drained.
            assert release.wait(terminal.remaining()), "read proxy release budget exhausted"
            return response
        try:
            terminal.until("rui> ", 0)
            proxy = ReplyProxy(owner, "/v1/inspect-session", hold_reply)
            original_handle_error = proxy.handle_error
            def handle_error(request, address):
                # Delivering the withheld reply after local cancellation may
                # encounter the deliberately closed peer. Other proxy faults
                # retain the canonical fixture's diagnostic behavior.
                if (isinstance(sys.exc_info()[1], BrokenPipeError) and
                        release.is_set() and terminal.process.poll() is not None):
                    return
                original_handle_error(request, address)
            proxy.handle_error = handle_error
            terminal.send("/status\n")
            wait_local(terminal, ready.is_set, "real Current read response not held")
            assert len(proxy.exchanges) == 1, proxy.exchanges
            assert b"200 OK" in proxy.exchanges[0][1].split(b"\r\n", 1)[0]
            termios.tcflow(terminal.slave, termios.TCOOFF)
            terminal.send(cancel)
            wait_local(terminal, lambda: restored(terminal),
                       "read cancellation did not restore configuration/flags with response held")
            wait_local(terminal, lambda: terminal.process.poll() is not None,
                       "local read cancellation waited for peer response release")
            assert not release.is_set(), "read custody fixture released reply before reap"
            termios.tcflow(terminal.slave, termios.TCOON)
            terminal.finish(nonzero=case == "incomplete")
            if case == "incomplete":
                assert b"IncompleteTerminalInput" in terminal.process.stderr.read()
            assert {path: path.read_bytes() for path in records.glob("*.json")} == before
            assert len(proxy.exchanges) == 1, "cancelled read duplicated Host request"
            print("persistent read custody:", case,
                  "real Current reply held; local read cancelled/reaped with TCOOFF without peer release")
        finally:
            release.set()
            if terminal.slave is not None: termios.tcflow(terminal.slave, termios.TCOON)
            terminal.close()
            if proxy is not None: proxy.close()  # Join before socket restoration/Host shutdown.


def main():
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-persistent-cancel-"))
    home, store = state / "home", state / "store"
    home.mkdir(mode=0o700)
    owner = host.start_host(store, None)
    try:
        cases(state, home, store, state, owner)
    finally:
        host.stop_host(owner)
        shutil.rmtree(state)


if __name__ == "__main__": main()
