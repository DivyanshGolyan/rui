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
import subprocess
import sys
import tempfile
import termios
import threading
import time

import canonical_failure_integration as canonical
import dispatch_integration as fixture
import human_cli_integration as human
from host_process import canonical_fixture_root


PROBE = r"""
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <termios.h>
#include <unistd.h>

static int disabled = 0;

static void record(const char *text) {
    int fd = open(getenv("RUI_TERMINAL_PROBE"), O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0 || write(fd, text, strlen(text)) != (ssize_t)strlen(text)) _exit(90);
    if (close(fd)) _exit(91);
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
    ssize_t result = real_write(fd, bytes, count);
    int saved_errno = errno;
    static int choice = 0, choice_held = 0;
    const char *fault = getenv("RUI_TERMINAL_FAULT");
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
        if (!strcmp(fault, "restore") || !strcmp(fault, "both") || !strcmp(fault, "drain-both")) {
            errno = ENOTTY;
            return -1;
        }
    }
    return real_tcsetattr(fd, action, attrs);
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
#else
ssize_t writev(int fd, const struct iovec *iov, int count) { return probe_writev(fd, iov, count); }
ssize_t write(int fd, const void *bytes, size_t count) { return probe_write(fd, bytes, count); }
int fsync(int fd) { return probe_fsync(fd); }
int tcdrain(int fd) { return probe_tcdrain(fd); }
int tcsetattr(int fd, int action, const struct termios *attrs) { return probe_tcsetattr(fd, action, attrs); }
#endif
"""


FORWARD_DRIVER = r"""
#include <sys/uio.h>
#include <termios.h>
#include <unistd.h>

int main(void) {
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
        assert log.read_text().splitlines() == ["restore-flush", "restore-flush", "disable", "disable", "drain"]
        assert termios.tcgetattr(slave) == original, "fixture forwarder did not restore attributes"
        print("terminal fixture forwarding: write/writev/tcdrain/tcsetattr passed", flush=True)
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
        for stopped in (False, True):
            master, slave = pty.openpty()
            error_master, error_slave = pty.openpty()
            original = termios.tcgetattr(slave)
            error_flags = fcntl.fcntl(error_slave, fcntl.F_GETFL)
            try:
                if stopped:
                    termios.tcflow(error_slave, termios.TCOOFF)
                caller = subprocess.Popen([str(fixture.RUI), "resume", "--store", str(store), "missing/fatal"],
                    env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave, stderr=error_slave)
                assert caller.wait(timeout=3) == 1, "fatal diagnostic did not exit"
                assert termios.tcgetattr(slave) == original
                assert fcntl.fcntl(error_slave, fcntl.F_GETFL) == error_flags
                if not stopped:
                    assert select.select([error_master], [], [], 1)[0]
                    assert b"SessionNotConfigured" in os.read(error_master, 65536)
                print(f"fatal reporting: stopped stderr={stopped} passed", flush=True)
            finally:
                if caller is not None and caller.poll() is None:
                    caller.kill()
                    caller.wait(timeout=5)
                termios.tcflow(error_slave, termios.TCOON)
                for fd in (master, slave, error_master, error_slave):
                    os.close(fd)
        master, slave = pty.openpty()
        original = termios.tcgetattr(slave)
        try:
            caller = subprocess.Popen([str(fixture.RUI), "resume", "--store", str(store), "fatal/original"],
                env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            human.read_terminal(master, "› ")
            proxy = canonical.ReplyProxy(host, "/v1/message",
                lambda response: b"" if len(proxy.exchanges) == 2 else response)
            os.write(master, b"accepted A\n")
            human.read_terminal(master, "ACCEPTED-A")
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
    finally:
        if proxy is not None:
            proxy.close()
        if host is not None:
            fixture.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)


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
        host = fixture.start_host(store, None)
        human.run(home, "configure", "--store", store, "--session", "terminal/restoration",
            "--workspace", state, "--provider", "codex", "--model", "model-a")
        assert selected in (None, "persistent"), selected
        persistent_cases(state, library, home, store, host)
        completed = True
    finally:
        if host is not None:
            fixture.stop_host(host)
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained terminal restoration failure state: {state}", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[2] if len(sys.argv) == 3 else None)
