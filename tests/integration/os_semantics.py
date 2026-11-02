"""Every way the fixtures' host OS changes what they may assert.

Linux CI predicts Mac CI because each Linux/Darwin difference is named here
once, with its reason, instead of in a `sys.platform` branch at the call site.
tests/ci/platform_boundary.py lets no other fixture read the platform, and a
PR that changes this file runs Mac Selected.
"""
import os
import pathlib
import platform
import subprocess
import sys
import termios
from unittest import mock


def semantics(platform_name):
    """The fixture facts for `platform_name`, a `sys.platform` value."""
    DARWIN = platform_name == "darwin"

    # For fixture reports: the kernel, and the kernel with release and machine.
    SYSTEM = "Darwin" if DARWIN else "Linux"
    DESCRIPTION = f"{SYSTEM} {platform.release()} {platform.machine()}"

    # Linux exposes per-process descriptors and status under /proc; Darwin has no
    # procfs, so descriptor and resource censuses are Linux-only evidence.
    PROC_FS = platform_name.startswith("linux")

    # The dynamic loader variable that injects a fixture's fault or probe library.
    PRELOAD = "DYLD_INSERT_LIBRARIES" if DARWIN else "LD_PRELOAD"

    # Darwin keeps kernel-owned history flags (PENDIN, FLUSHO) in c_lflag. Rui
    # restores user configuration, never the kernel's input history.
    _TERMIOS_HISTORY = (getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)) if DARWIN else 0

    # XNU xnu-11417.140.69 exposes kernel-only FWASWRITTEN through F_GETFL. A
    # positive write sets it; a successful F_SETFL cannot clear write history.
    FILE_FLAG_HISTORY = 0x00010000 if DARWIN else 0

    # Each h2 Client has one waker: an eventfd on Linux, a pipe (two
    # descriptors) on Darwin. These mirror descriptor_capacity.zig
    # independently.
    TRANSPORT_WAKE_DESCRIPTORS = 2 if DARWIN else 1
    # Lease(2), SQLite(4), listener(1) and the transport waker.
    HOST_FIXED_DESCRIPTORS = 2 + 4 + 1 + TRANSPORT_WAKE_DESCRIPTORS
    # Credential parent and lock (2), the refresh Client's waker, one
    # connection socket and two trust-loading handles.
    AUTHENTICATION_DESCRIPTORS = 2 + TRANSPORT_WAKE_DESCRIPTORS + 1 + 2

    # Darwin's libmalloc may open one socket before Host ownership begins; it
    # counts as inherited beside stdio.
    INHERITED_DESCRIPTORS = {3, 4} if DARWIN else {3}

    # Only Darwin `rui host` re-execs itself with MallocMaxMagazines and
    # MallocSpaceEfficient defaults (cli.zig configureHostAllocator).
    HOST_MALLOC_REEXEC = DARWIN

    # Linux enforces a Unix socket's mode bits on connect for unprivileged callers.
    SOCKET_MODE_ENFORCED = not DARWIN

    # The capture directory-sync fault shim interposes fsync through Linux's
    # RTLD_NEXT preload; no Darwin adapter exists for it.
    SYNC_FAULT_PRELOAD = not DARWIN

    # Darwin's /usr/bin/footprint reports a process's physical footprint peak.
    FOOTPRINT = DARWIN

    # A Host's system trust is OpenSSL's on Linux, which SSL_CERT_FILE extends,
    # and Apple SecTrust on Darwin, which ignores it (src/h2/tests.zig). So
    # only Linux can trust a self-signed fixture without --provider-ca-file.
    SSL_CERT_FILE_TRUST = not DARWIN

    # GNU time (`/usr/bin/time -f`) measures a caller's peak RSS on Linux.
    GNU_TIME = not DARWIN and pathlib.Path("/usr/bin/time").exists()
    return {name: value for name, value in locals().items() if name != "platform_name"}


# Callers and the helpers below read facts through this module at call time,
# so simulate() reaches them.
_module = sys.modules[__name__]
vars(_module).update(semantics(sys.platform))


def simulate(platform_name):
    """Patch these facts to `platform_name`'s, so Linux tests check Darwin arithmetic."""
    return mock.patch.multiple(_module, **semantics(platform_name))


def user_termios(attributes):
    """A copy of termios attributes without kernel-owned history flags."""
    copy = list(attributes)
    copy[3] &= ~_module._TERMIOS_HISTORY
    return copy


def user_file_flags(flags):
    """F_GETFL flags without kernel-owned write history."""
    return flags & ~_module.FILE_FLAG_HISTORY


def shared_library_command(source, library):
    """The compiler command that builds a preloadable fixture library."""
    darwin = _module.DARWIN
    return ["cc", "-dynamiclib" if darwin else "-shared", "-fPIC", str(source),
            *([] if darwin else ["-ldl"]), "-o", str(library)]


def processes_executing(executable):
    """Pids of live processes whose executed image is `executable`, whatever they are called."""
    image = os.stat(executable)
    if _module.PROC_FS:
        pids = set()
        for entry in pathlib.Path("/proc").iterdir():
            if entry.name.isdigit():
                try:
                    running = os.stat(entry / "exe")
                except (FileNotFoundError, PermissionError, ProcessLookupError):
                    continue
                if (running.st_dev, running.st_ino) == (image.st_dev, image.st_ino):
                    pids.add(int(entry.name))
        return pids
    # Darwin has no procfs; lsof matches the file's text mappings by device and inode.
    mapped = subprocess.run(["/usr/sbin/lsof", "-w", "-n", "-P", "-a", "-d", "txt", "-Fp", "--", str(executable)],
                            capture_output=True, text=True, timeout=10)
    # lsof exits 1 both when no process maps the file and when it fails. With
    # warnings off (-w), only a failure writes to stderr.
    assert mapped.returncode == 0 or (mapped.returncode == 1 and not mapped.stderr), mapped
    return {int(field[1:]) for field in mapped.stdout.splitlines() if field.startswith("p")}
