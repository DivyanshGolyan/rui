#!/usr/bin/env python3
"""Linux one-shot login signal-installation witness, without provider traffic.

Queue SIGINT at the real handler installation and deny/record native DNS and
Internet connect attempts. This proves the production dispatcher, not a
synthetic exchange; it does not qualify stalled device exchange or macOS.
"""
import hashlib
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile


def run(binary):
    assert sys.platform == "linux", "This loader witness qualifies Linux only"
    binary = pathlib.Path(binary).resolve()
    with tempfile.TemporaryDirectory(prefix="rui-login-signal-") as root:
        root = pathlib.Path(root)
        source = root / "signal.c"
        library = root / "signal.so"
        source.write_text(r"""
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <netdb.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

static int witness = -1;
static void mark(int offset) {
    if (witness < 0 || pwrite(witness, "1", 1, offset) != 1) _exit(122);
}
__attribute__((constructor)) static void loaded(void) {
    const char *fd = getenv("RUI_LOGIN_WITNESS_FD");
    if (!fd || !*fd) _exit(122);
    witness = atoi(fd);
    mark(0);
}
int getaddrinfo(const char *node, const char *service,
                const struct addrinfo *hints, struct addrinfo **result) {
    (void)node; (void)service; (void)hints;
    mark(1);
    *result = NULL;
    return EAI_FAIL;
}
int connect(int fd, const struct sockaddr *address, socklen_t size) {
    if (address && (address->sa_family == AF_INET || address->sa_family == AF_INET6)) {
        mark(2);
        errno = ECONNREFUSED;
        return -1;
    }
    int (*real_connect)(int, const struct sockaddr *, socklen_t) =
        dlsym(RTLD_NEXT, "connect");
    return real_connect(fd, address, size);
}
int sigaction(int signal, const struct sigaction *action, struct sigaction *old) {
    int (*real_action)(int, const struct sigaction *, struct sigaction *) =
        dlsym(RTLD_NEXT, "sigaction");
    if (signal == SIGINT && action && action->sa_handler != SIG_DFL &&
        action->sa_handler != SIG_IGN) {
        sigset_t mask;
        sigprocmask(SIG_SETMASK, NULL, &mask);
        dprintf(2, "scope-signal blocked=%d\n", sigismember(&mask, SIGINT));
        kill(getpid(), SIGINT);
    }
    return real_action(signal, action, old);
}
""")
        subprocess.run(["cc", "-shared", "-fPIC", str(source), "-ldl", "-o", str(library)], check=True)
        environment = {
            key: value for key, value in os.environ.items()
            if not key.startswith("RUI_") and not any(
                word in key.upper() for word in ("TOKEN", "SECRET", "CREDENTIAL", "API_KEY")
            )
        }
        # Parent-owned monotonic bytes, not optional stderr, are the effect oracle.
        with tempfile.TemporaryFile(dir=root) as witness:
            witness.write(b"000")
            witness.flush()
            environment.update(HOME=str(root), TMPDIR=str(root), LD_PRELOAD=str(library),
                               RUI_LOGIN_WITNESS_FD=str(witness.fileno()))
            child = subprocess.run([str(binary), "login", "codex"], env=environment,
                                   capture_output=True, timeout=10, pass_fds=(witness.fileno(),),
                                   preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
            witness.seek(0)
            observed = witness.read()
        print(json.dumps({"binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                          "exit": child.returncode,
                          "blocked": b"scope-signal blocked=1" in child.stderr,
                          "cancelled": b"LoginInterrupted" in child.stderr,
                          "network_witness": observed.decode("ascii"),
                          "device_prompt_displayed": b"auth.openai.com/codex/device" in child.stderr}))
        assert len(observed) == 3 and observed[0:1] == b"1" and set(observed) <= {48, 49}, "missing/malformed native witness"
        assert child.returncode == 1, "SIGINT must report invocation failure, not signal termination"
        assert b"scope-signal blocked=1" in child.stderr, "handler installation must be signal-masked"
        assert b"LoginInterrupted" in child.stderr, "queued interruption must win before exchange/publication"
        assert b"auth.openai.com/codex/device" not in child.stderr
        assert not (root / ".config/rui/codex.json").exists()
        assert not (root / ".config/rui/preferences").exists()
        assert observed[1:] == b"00", "queued SIGINT must prevent network attempts"


if __name__ == "__main__":
    run(sys.argv[1])
