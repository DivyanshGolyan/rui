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
        if (!strcmp(fault, "disable") || !strcmp(fault, "both")) {
            errno = EIO;
            return -1;
        }
    }
    return real_writev(fd, iov, count);
}

static int probe_tcsetattr(int fd, int action, const struct termios *attrs) {
    int (*real_tcsetattr)(int, int, const struct termios *) = dlsym(RTLD_NEXT, "tcsetattr");
    if (fd == 0 && (attrs->c_lflag & ICANON)) {
        record(action == TCSAFLUSH ? "restore-flush\n" : "restore-other\n");
        const char *fault = getenv("RUI_TERMINAL_FAULT");
        if (!strcmp(fault, "restore") || !strcmp(fault, "both")) {
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
INTERPOSE(probe_tcsetattr, tcsetattr)
#else
ssize_t writev(int fd, const struct iovec *iov, int count) { return probe_writev(fd, iov, count); }
int tcsetattr(int fd, int action, const struct termios *attrs) { return probe_tcsetattr(fd, action, attrs); }
#endif
"""


def main():
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
        for case in ("queued", "exit", "interrupt", "incomplete", "disable", "restore", "both",
                "disable-incomplete", "restore-incomplete", "both-incomplete", "output"):
            master, slave = pty.openpty()
            original = termios.tcgetattr(slave)
            log = state / f"probe-{case}.log"
            records = home / ".config/rui/requests"
            before = set(records.glob("*.json"))
            env = {**os.environ, "HOME": str(home)}
            fault = case.split("-", 1)[0]
            injected = fault in ("disable", "restore", "both", "output")
            if injected:
                env.update({"DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD": str(library),
                    "RUI_TERMINAL_PROBE": str(log), "RUI_TERMINAL_FAULT": fault})
            received, release = threading.Event(), threading.Event()

            def hold_reply(response):
                received.set()
                assert release.wait(15), "terminal witness did not release reply"
                return response

            caller = None
            proxy = None
            try:
                caller = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
                    "--session", "terminal/restoration"], env=env,
                    stdin=slave, stdout=slave, stderr=subprocess.PIPE)
                human.read_terminal(master, "rui> ")
                proxy = canonical.ReplyProxy(host, "/v1/configure", hold_reply)
                payload = {"exit": b"/exit\n", "interrupt": b"\x03", "incomplete": b"\xc3"}.get(
                    case, b"/configure --permission-mode ask\nSTALE")
                if case.endswith("-incomplete"):
                    payload = b"\xc3"
                os.write(master, payload)
                if case == "output":
                    fixture.wait_for(lambda: log.exists() and "output-stopped" in log.read_text(),
                        "cleanup output flow stopped")
                    assert caller.poll() is None and not received.is_set() and not proxy.exchanges
                    assert set(records.glob("*.json")) == before, "blocked cleanup released accepted input"
                    assert not termios.tcgetattr(slave)[3] & termios.ICANON
                    termios.tcflow(slave, termios.TCOON)
                if case in ("queued", "output"):
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
                    release.set()
                    human.read_terminal(master, "rui> ")
                    human.terminal_step(master, "/exit", "Detached.")
                    assert caller.wait(timeout=5) == 0
                    if injected:
                        assert log.read_text().splitlines() == ["output-stopped", "disable", "restore-flush",
                            "disable", "restore-flush"], log.read_text()
                else:
                    assert caller.wait(timeout=7) == (0 if case in ("exit", "interrupt") else 1)
                    errors = caller.stderr.read().decode()
                    output = b""
                    while select.select([master], [], [], 0)[0]:
                        output += os.read(master, 65536)
                        assert len(output) < 1024 * 1024, "unbounded failed-prompt output"
                    assert b"rui> " not in output and b"Configured." not in output, output
                    if fault not in ("disable", "both"):
                        assert b"\x1b[?2004l" in output, "paste disable did not reach terminal"
                    expected = {"incomplete": "IncompleteTerminalInput", "disable": "TerminalCleanupFailed",
                        "restore": "TerminalRestoreFailed", "both": "TerminalRestoreFailed"}.get(fault)
                    if expected:
                        assert expected in errors, errors
                    assert set(records.glob("*.json")) == before, "failed/empty prompt captured a request"
                    assert not received.is_set() and not proxy.exchanges, "failed cleanup sent to Host"
                    if injected:
                        assert log.read_text().splitlines() == ["disable", "restore-flush"], log.read_text()
                    if fault not in ("restore", "both"):
                        assert termios.tcgetattr(slave) == original, "exit did not restore exact attributes"
                print(f"terminal restoration: {case} passed", flush=True)
            finally:
                termios.tcflow(slave, termios.TCOON)
                release.set()
                if proxy is not None:
                    proxy.close()
                if caller is not None:
                    if caller.poll() is None:
                        caller.kill()
                        caller.wait(timeout=5)
                    caller.stderr.close()
                # Failed-restoration cases intentionally leave raw mode behind.
                termios.tcsetattr(slave, termios.TCSAFLUSH, original)
                os.close(master)
                os.close(slave)
        completed = True
    finally:
        if host is not None:
            fixture.stop_host(host)
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained terminal restoration failure state: {state}", file=sys.stderr)


if __name__ == "__main__":
    main()
