#!/usr/bin/env python3
"""Real editor handoff, queued input and independently failed cleanup effects."""
import json
import os
import pathlib
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import termios
import threading

import canonical_failure_integration as canonical
import dispatch_integration as fixture
import human_cli_integration as human


PROBE = r"""
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
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
    ssize_t (*real_writev)(int, const struct iovec *, int) = dlsym(RTLD_NEXT, "writev");
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

static int probe_tcdrain(int fd) {
    int (*real_tcdrain)(int) = dlsym(RTLD_NEXT, "tcdrain");
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
    int (*real_tcsetattr)(int, int, const struct termios *) = dlsym(RTLD_NEXT, "tcsetattr");
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
INTERPOSE(probe_tcdrain, tcdrain)
INTERPOSE(probe_tcsetattr, tcsetattr)
#else
ssize_t writev(int fd, const struct iovec *iov, int count) { return probe_writev(fd, iov, count); }
int tcdrain(int fd) { return probe_tcdrain(fd); }
int tcsetattr(int fd, int action, const struct termios *attrs) { return probe_tcsetattr(fd, action, attrs); }
#endif
"""


def main(selected=None):
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-terminal-restoration.")).resolve()
    home = state / "home"
    home.mkdir()
    store = state / "store"
    host = None
    completed = False
    try:
        host = fixture.start_host(store, None)
        human.run(home, "configure", "--store", store, "--session", "terminal/restoration",
            "--workspace", state, "--provider", "codex", "--model", "model-a")
        source, library = state / "probe.c", state / "probe.so"
        source.write_text(PROBE)
        subprocess.run(["cc", "-dynamiclib" if sys.platform == "darwin" else "-shared",
            "-fPIC", str(source), "-o", str(library)], check=True)
        cases = ("queued", "exit", "interrupt", "incomplete", "disable", "restore", "both",
            "disable-incomplete", "restore-incomplete", "both-incomplete", "output",
            "drain", "drain-both", "drain-incomplete", "drain-eintr", "drain-held")
        assert selected is None or selected in cases, selected
        for case in cases if selected is None else (selected,):
            master, slave = pty.openpty()
            original = termios.tcgetattr(slave)
            separate = case.startswith("drain")
            output_master, output_slave = pty.openpty() if separate else (master, slave)
            log = state / f"probe-{case}.log"
            drain_release = state / f"drain-{case}.release"
            records = home / ".config/rui/requests"
            before = set(records.glob("*.json"))
            env = {**os.environ, "HOME": str(home)}
            fault = case if separate else case.split("-", 1)[0]
            injected = separate or fault in ("disable", "restore", "both", "output")
            if injected:
                env.update({"DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
                    "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": fault,
                    "RUI_TERMINAL_DRAIN_RELEASE": str(drain_release)})
            received, release = threading.Event(), threading.Event()

            def hold_reply(response):
                received.set()
                assert release.wait(15), "terminal witness did not release reply"
                return response

            output = bytearray()
            reader_stop = threading.Event()
            reader_errors = []
            reader = None

            def drain_output():
                try:
                    while not reader_stop.is_set() or select.select([output_master], [], [], 0)[0]:
                        if select.select([output_master], [], [], 0.05)[0]:
                            output.extend(os.read(output_master, 65536))
                            assert len(output) < 1024 * 1024, "unbounded prompt output"
                except BaseException as error:
                    reader_errors.append(error)

            def stop_reader():
                if reader is not None:
                    reader_stop.set()
                    reader.join(timeout=5)
                    assert not reader.is_alive(), "terminal output reader did not join"
                    assert not reader_errors, reader_errors

            caller = None
            proxy = None
            try:
                caller = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
                    "--session", "terminal/restoration"], env=env,
                    stdin=slave, stdout=output_slave, stderr=subprocess.PIPE)
                human.read_terminal(output_master, "rui> ")
                # A terminal consumes output while Rui drains it. Withholding
                # PTY reads here would conflate peer credit with finalization.
                reader = threading.Thread(target=drain_output)
                reader.start()
                proxy = canonical.ReplyProxy(host, "/v1/configure", hold_reply)
                payload = {"exit": b"/exit\n", "interrupt": b"\x03", "incomplete": b"\xc3"}.get(
                    case, b"/configure --permission-mode ask\nSTALE")
                if case.endswith("-incomplete"):
                    payload = b"\xc3"
                os.write(master, payload)
                if separate:
                    fixture.wait_for(lambda: received.is_set() or (log.exists() and "drain" in log.read_text()),
                        "stdout drain or premature handoff")
                    assert log.exists() and "drain" in log.read_text(), "accepted input bypassed stdout drain"
                if case == "drain-held":
                    fixture.wait_for(lambda: "drain-held" in log.read_text(), "injected stdout drain wait")
                    assert caller.poll() is None and not received.is_set() and not proxy.exchanges
                    assert set(records.glob("*.json")) == before and not termios.tcgetattr(slave)[3] & termios.ICANON
                    drain_release.touch()
                if case == "output":
                    fixture.wait_for(lambda: log.exists() and "output-stopped" in log.read_text(),
                        "cleanup output flow stopped")
                    assert caller.poll() is None and not received.is_set() and not proxy.exchanges
                    assert set(records.glob("*.json")) == before, "blocked cleanup released accepted input"
                    assert not termios.tcgetattr(slave)[3] & termios.ICANON
                    termios.tcflow(slave, termios.TCOON)
                if case in ("queued", "output", "drain-eintr", "drain-held"):
                    assert received.wait(15), "post-cleanup request did not reach Host"
                    assert termios.tcgetattr(slave) == original, "handoff did not restore exact attributes"
                    os.write(master, b"\n")
                    assert select.select([slave], [], [], 5)[0], "canonical input did not resume"
                    assert os.read(slave, 4096) == b"\n", "restoration retained old queued typeahead"
                    after = set(records.glob("*.json"))
                    assert len(after - before) == 1
                    saved = json.loads((after - before).pop().read_text())
                    assert saved["kind"] == "configure" and saved["session"] == "terminal/restoration", saved
                    assert json.loads(proxy.exchanges[0][0]) == saved, "Host received different captured bytes"
                    stop_reader()  # Transfer the sole output-reader role before the held reply is released.
                    assert b"\x1b[?2004l" in output, "paste disable did not reach terminal"
                    release.set()
                    human.read_terminal(output_master, "rui> ")
                    os.write(master, b"/exit\n")
                    human.read_terminal(output_master, "Detached.")
                    assert caller.wait(timeout=5) == 0
                    if injected:
                        first = (["output-stopped", "disable", "drain", "restore-flush"] if case == "output"
                            else ["disable", "drain", "drain", "restore-flush"] if case == "drain-eintr"
                            else ["disable", "drain", "drain-held", "restore-flush"])
                        last = ["disable", "drain"] + (["drain-held"] if case == "drain-held" else []) + ["restore-flush"]
                        assert log.read_text().splitlines() == first + last, log.read_text()
                else:
                    assert caller.wait(timeout=7) == (0 if case in ("exit", "interrupt") else 1)
                    errors = caller.stderr.read().decode()
                    stop_reader()
                    assert b"rui> " not in output and b"Configured." not in output, output
                    if fault not in ("disable", "both"):
                        assert b"\x1b[?2004l" in output, "paste disable did not reach terminal"
                    expected = {"incomplete": "IncompleteTerminalInput", "disable": "TerminalCleanupFailed",
                        "restore": "TerminalRestoreFailed", "both": "TerminalRestoreFailed",
                        "drain": "TerminalCleanupFailed", "drain-both": "TerminalRestoreFailed",
                        "drain-incomplete": "TerminalCleanupFailed"}.get(fault)
                    if expected:
                        assert expected in errors, errors
                    assert set(records.glob("*.json")) == before, "failed/empty prompt captured a request"
                    assert not received.is_set() and not proxy.exchanges, "failed cleanup sent to Host"
                    if injected:
                        assert log.read_text().splitlines() == ["disable"] + (
                            [] if fault in ("disable", "both") else ["drain"]) + ["restore-flush"], log.read_text()
                    if fault not in ("restore", "both", "drain-both"):
                        assert termios.tcgetattr(slave) == original, "exit did not restore exact attributes"
                print(f"terminal restoration: {case} passed", flush=True)
            finally:
                termios.tcflow(slave, termios.TCOON)
                drain_release.touch()
                release.set()
                if proxy is not None:
                    proxy.close()
                if caller is not None:
                    if caller.poll() is None:
                        caller.kill()
                        caller.wait(timeout=5)
                    caller.stderr.close()
                # Dispose only after owned writers stop. Discard residual
                # fixture output rather than waiting for its transmission.
                termios.tcflush(output_slave, termios.TCOFLUSH)
                termios.tcflush(slave, termios.TCOFLUSH)
                termios.tcsetattr(slave, termios.TCSAFLUSH, original)
                stop_reader()
                os.close(master)
                os.close(slave)
                if separate:
                    os.close(output_master)
                    os.close(output_slave)
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
