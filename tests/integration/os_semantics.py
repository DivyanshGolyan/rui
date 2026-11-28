import asyncio
import ctypes
import fcntl
import os
import pathlib
import platform
import re
import shlex
import shutil
import socket
import socketserver
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
    # descriptor_capacity.ordinary_exchange_descriptors: protocol.max_request_contents (4) + 2, on every platform.
    ORDINARY_EXCHANGE_DESCRIPTORS = 4 + 2

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


def file_access_tracer():
    return shutil.which("strace") if _module.PROC_FS else None


# sun_path holds 104 bytes on Darwin and 108 on Linux, the NUL included. Every fixture
# refuses a path of UNIX_PATH_LIMIT bytes or more on every platform, so a Linux run
# fails where Darwin would refuse the bind or connect (#1948). See docs/verification/testing.md.
UNIX_PATH_LIMIT = 104


class UnixPathTooLong(ValueError):
    def __init__(self, path):
        self.path = os.fsdecode(path)
        self.length = len(os.fsencode(path))
        super().__init__(f"AF_UNIX path is {self.length} bytes, at or over the {UNIX_PATH_LIMIT}-byte "
                         f"limit (Darwin's sun_path): {self.path!r}")


def check_unix_path(path):
    if len(os.fsencode(path)) >= UNIX_PATH_LIMIT:
        raise UnixPathTooLong(path)
    return path


class _UnixStream(socket.socket):
    def bind(self, address):
        super().bind(check_unix_path(address))

    def connect(self, address):
        super().connect(check_unix_path(address))

    def connect_ex(self, address):
        return super().connect_ex(check_unix_path(address))


class UnixStreamServer(socketserver.UnixStreamServer):
    def server_bind(self):
        check_unix_path(self.server_address)
        super().server_bind()


async def start_unix_server(client_connected_cb, path, **kwargs):
    return await asyncio.start_unix_server(client_connected_cb, path=check_unix_path(path), **kwargs)


async def open_unix_connection(path, **kwargs):
    return await asyncio.open_unix_connection(check_unix_path(path), **kwargs)


def unix_stream():
    stream = _UnixStream(socket.AF_UNIX, socket.SOCK_STREAM)
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
            ("Linux", "x86_64"): "linux-x86_64",
            ("Linux", "aarch64"): "linux-arm64"}.get((_module.SYSTEM, platform.machine()))


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


# Linux keeps one record per process here; Darwin has none, so every reader
# below is Linux-only unless it says otherwise.
PROCESS_RECORDS = pathlib.Path("/proc")


def descriptor_links(pid):
    """One link per descriptor pid holds open, named by its number: os.readlink names the open file.
    Raises FileNotFoundError once pid has no record."""
    return list((PROCESS_RECORDS / str(pid) / "fd").iterdir())


def descriptor_link(pid, descriptor):
    return PROCESS_RECORDS / str(pid) / "fd" / str(descriptor)


def working_directory_link(pid):
    return PROCESS_RECORDS / str(pid) / "cwd"


def process_memory(pid):
    """pid's resident and peak resident memory as {"rss_kib", "peak_kib"}, holding only what the kernel
    reports (an exited, unreaped process reports neither); None where pid has no record (Darwin, or reaped)."""
    status = PROCESS_RECORDS / str(pid) / "status"
    if not status.exists():
        return None
    fields = {"VmRSS": "rss_kib", "VmHWM": "peak_kib"}
    memory = {}
    for line in status.read_text().splitlines():
        name, _, value = line.partition(":")
        if name in fields:
            amount, unit = value.split()
            assert unit == "kB", line
            memory[fields[name]] = int(amount)
    return memory


def socket_table(name):
    """The rows of the kernel's socket table name ("tcp", "tcp6", "unix"), split into fields without the
    header, or None when this kernel keeps no such table."""
    table = PROCESS_RECORDS / "net" / name
    try:
        return [line.split() for line in table.read_text().splitlines()[1:]]
    except FileNotFoundError:
        return None


def open_descriptor_names(pid):
    """One name per descriptor pid holds open: the open file's link target from procfs, or its lsof row on
    Darwin. A descriptor that closes while it is read is left out."""
    if _module.PROC_FS:
        names = []
        for link in descriptor_links(pid):
            try:
                names.append(os.readlink(link))
            except FileNotFoundError:
                pass
        return names
    rows = subprocess.check_output(["/usr/sbin/lsof", "-n", "-P", "-p", str(pid)], text=True).splitlines()
    return [row for row in rows[1:] if re.fullmatch(r"\d+[rwu]?", row.split()[3])]


def process_cpu_seconds(pid):
    value = subprocess.check_output(["ps", "-o", "time=", "-p", str(pid)], text=True).strip()
    return sum(float(part) * 60 ** index for index, part in enumerate(reversed(value.split(":"))))


def process_resident_kib(pid):
    return int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)]))


def physical_footprint_peak(pid):
    """pid's peak physical footprint in bytes where the kernel accounts one (Darwin), otherwise None."""
    if not _module.FOOTPRINT:
        return None
    report = subprocess.run(["/usr/bin/footprint", "-f", "bytes", "-p", str(pid)],
                            capture_output=True, text=True, check=True, timeout=30).stdout
    return int(re.search(r"^\s*phys_footprint_peak: (\d+) B$", report, re.M).group(1))


def launch_records(pid):
    """pid's argument and environment records as {"cmdline": bytes, "environ": bytes}, for checking that a
    secret never reached them; None where the kernel exposes neither to a reader (Darwin)."""
    if not _module.PROC_FS:
        return None
    return {name: (PROCESS_RECORDS / str(pid) / name).read_bytes() for name in ("cmdline", "environ")}


def process_commands():
    """(pid, argv) for every process the census can read. A process that ends while it is read is left
    out; any other read failure propagates, so a caller never acts on an incomplete census."""
    candidates = []
    if _module.PROC_FS:
        for entry in PROCESS_RECORDS.iterdir():
            if not entry.name.isdigit():
                continue
            try:
                argv = (entry / "cmdline").read_bytes().split(b"\0")
                candidates.append((int(entry.name), [part.decode() for part in argv if part]))
            except (FileNotFoundError, ProcessLookupError, PermissionError, UnicodeDecodeError):
                continue
        return candidates
    listing = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True, timeout=5, check=True)
    for line in listing.stdout.splitlines():
        try:
            pid_text, command = line.strip().split(maxsplit=1)
            candidates.append((int(pid_text), shlex.split(command)))
        except (ValueError, IndexError):
            continue
    return candidates


# Rui's Store lease and credential locks are flock locks, whose release on
# process exit differs across kernels; fixtures contend for them only here.
def try_lock(file, *, shared=False):
    """Take file's lock without waiting; False when another open description holds it."""
    try:
        fcntl.flock(file, (fcntl.LOCK_SH if shared else fcntl.LOCK_EX) | fcntl.LOCK_NB)
    except BlockingIOError:
        return False
    return True


def take_lock(file, *, shared=False):
    """Take file's lock, waiting for any holder to release it."""
    fcntl.flock(file, fcntl.LOCK_SH if shared else fcntl.LOCK_EX)


def release_lock(file):
    fcntl.flock(file, fcntl.LOCK_UN)


def process_state(pid, *, env=None):
    """pid's process-table state letters ("S", "Z+", ...), or None once the table has no entry for it."""
    observed = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], env=env, capture_output=True, text=True, timeout=5)
    if observed.returncode == 1 and not observed.stdout and not observed.stderr:
        return None
    assert observed.returncode == 0 and observed.stdout.strip(), observed
    return observed.stdout.strip()


def describe_processes(pids):
    """A process-table listing of pids (group, terminal group, state, command) for a failure message."""
    return subprocess.run(["ps", "-o", "pid,pgid,tpgid,stat,command", "-p", ",".join(map(str, pids))],
                          capture_output=True, text=True).stdout


def process_environment(pid, *, env):
    if _module.PROC_FS:
        return pathlib.Path(f"/proc/{pid}/environ").read_bytes().decode()
    return subprocess.check_output(["ps", "eww", "-p", str(pid), "-o", "command="],
                                   env=env, text=True, timeout=5)
