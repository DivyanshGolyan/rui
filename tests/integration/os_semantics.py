import ctypes
import os
import pathlib
import platform
import socket
import struct
import subprocess
import sys
import termios
from unittest import mock


def semantics(platform_name):
    DARWIN = platform_name == "darwin"

    SYSTEM = "Darwin" if DARWIN else "Linux"
    DESCRIPTION = f"{SYSTEM} {platform.release()} {platform.machine()}"

    PROC_FS = platform_name.startswith("linux")

    PRELOAD = "DYLD_INSERT_LIBRARIES" if DARWIN else "LD_PRELOAD"

    _TERMIOS_HISTORY = (getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)) if DARWIN else 0

    FILE_FLAG_HISTORY = 0x00010000 | 0x00001000 if DARWIN else 0

    TRANSPORT_WAKE_DESCRIPTORS = 2 if DARWIN else 1
    HOST_FIXED_DESCRIPTORS = 2 + 4 + 1 + TRANSPORT_WAKE_DESCRIPTORS + 1
    AUTHENTICATION_DESCRIPTORS = 2 + TRANSPORT_WAKE_DESCRIPTORS + 1 + 2

    INHERITED_DESCRIPTORS = {3, 4} if DARWIN else {3}

    HOST_MALLOC_REEXEC = DARWIN

    SOCKET_MODE_ENFORCED = not DARWIN

    SYNC_FAULT_PRELOAD = not DARWIN

    FOOTPRINT = DARWIN

    SSL_CERT_FILE_TRUST = not DARWIN

    GNU_TIME = not DARWIN and pathlib.Path("/usr/bin/time").exists()
    return {name: value for name, value in locals().items() if name != "platform_name"}


_module = sys.modules[__name__]
vars(_module).update(semantics(sys.platform))


def simulate(platform_name):
    return mock.patch.multiple(_module, **semantics(platform_name))


def unix_stream():
    stream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        if _module.PROC_FS:
            stream.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4096)
        return stream
    except BaseException:
        stream.close()
        raise


TRUST_VARIABLES = ("SSL_CERT_FILE", "SSL_CERT_DIR")


def system_trust(certificate):
    assert _module.SSL_CERT_FILE_TRUST, "Darwin system trust ignores SSL_CERT_FILE; pass the CA explicitly"
    return {"SSL_CERT_FILE": str(certificate)}


def user_termios(attributes):
    copy = list(attributes)
    copy[3] &= ~_module._TERMIOS_HISTORY
    return copy


def user_file_flags(flags):
    return flags & ~_module.FILE_FLAG_HISTORY


def terminal_bash_reads_login_files():
    return _module.DARWIN


def shared_library_command(source, library):
    darwin = _module.DARWIN
    return ["cc", "-dynamiclib" if darwin else "-shared", "-fPIC", str(source),
            *([] if darwin else ["-ldl"]), "-o", str(library)]


def processes_executing(executable):
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
    mapped = subprocess.run(["/usr/sbin/lsof", "-w", "-n", "-P", "-a", "-d", "txt", "-Fp", "--", str(executable)],
                            capture_output=True, text=True, timeout=10)
    assert mapped.returncode == 0 or (mapped.returncode == 1 and not mapped.stderr), mapped
    return {int(field[1:]) for field in mapped.stdout.splitlines() if field.startswith("p")}


def native_release_target():
    return {("Darwin", "arm64"): "darwin-arm64",
            ("Linux", "x86_64"): "linux-x86_64"}.get((_module.SYSTEM, platform.machine()))


def socket_peer_pid(connection):
    if _module.DARWIN:
        return connection.getsockopt(0, 2)  
    credentials = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
    pid, uid, _ = struct.unpack("3i", credentials)
    assert uid == os.geteuid(), "Unix peer belongs to a different user"
    return pid


def process_executable(pid):
    if _module.PROC_FS:
        return pathlib.Path(f"/proc/{pid}/exe").resolve(strict=True)
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    buffer = ctypes.create_string_buffer(4096)
    count = library.proc_pidpath(pid, buffer, len(buffer))
    assert count > 0, "native process path unavailable"
    return pathlib.Path(os.fsdecode(buffer.value))


def process_environment(pid, *, env):
    if _module.PROC_FS:
        return pathlib.Path(f"/proc/{pid}/environ").read_bytes().decode()
    return subprocess.check_output(["ps", "eww", "-p", str(pid), "-o", "command="],
                                   env=env, text=True, timeout=5)
