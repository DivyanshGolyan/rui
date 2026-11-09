"""Probes for the terminal leader prototype. Prints one verdict per question.

    python3 tests/integration/terminal_leader_probe.py [probe ...]

VERIFIED: every expectation held. NOT VERIFIED: one failed. INCONCLUSIVE: the
probe could not decide. Each verdict carries the measured values.
"""

import errno
import json
import resource
import os
import platform
import pty
import select
import signal
import statistics
import subprocess
import sys
import tempfile
import termios
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from terminal_leader import spawn  # noqa: E402

PY = [sys.executable, "-I", "-S", "-c"]
REPORT = 37
FD_DIR = "/proc/self/fd" if os.path.isdir("/proc/self/fd") else "/dev/fd"

# Reports what the command sees of its terminal, sets termios it can be told
# apart by, writes three bytes nobody reads, and exits.
OWNER = """
import json, os, termios, time
r = {}
try:
    tty = os.open("/dev/tty", os.O_RDWR)
    r["dev_tty"] = "opened"
    r["foreground"] = os.tcgetpgrp(tty) == os.getpgrp()
    a = termios.tcgetattr(tty)
    a[3] &= ~termios.ECHO
    a[6][termios.VMIN] = 7
    termios.tcsetattr(tty, termios.TCSANOW, a)
    # Set through /dev/tty, read back through stdin, the fixture's PTY.
    b = termios.tcgetattr(0)
    r["dev_tty_is_pty"] = not (b[3] & termios.ECHO) and b[6][termios.VMIN] in (7, b"\x07")
except OSError as e:
    r["dev_tty"] = errno_name = __import__("errno").errorcode[e.errno]
r["session_leader"] = os.getsid(0) == os.getpid()
r["group_leader"] = os.getpgrp() == os.getpid()
os.write(1, b"abc")
r["exit_at"] = time.monotonic()
os.write(37, json.dumps(r).encode())
os._exit(0)
"""

DESCRIPTORS = """
import json, os, stat, sys
held = []
for fd in range(4096):
    try:
        os.fstat(fd)
        held.append(fd)
    except OSError:
        pass
import resource
r = {"held": held, "fd37_fifo": stat.S_ISFIFO(os.fstat(37).st_mode),
     "nofile_soft": resource.getrlimit(resource.RLIMIT_NOFILE)[0]}
sys.stderr.write("err-text")
sys.stderr.flush()
os.write(37, json.dumps(r).encode())
"""

HANGUP_WATCH = """
import os, signal, sys, time
def hup(*_):
    with open(sys.argv[1], "w") as f:
        f.write("SIGHUP")
    os._exit(0)
signal.signal(signal.SIGHUP, hup)
os.write(1, b"R")
time.sleep(30)
"""


def openpty():
    return pty.openpty()


def report(read_fd, timeout=5):
    data = b""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not select.select([read_fd], [], [], deadline - time.monotonic())[0]:
            break
        chunk = os.read(read_fd, 65536)
        if not chunk:
            break
        data += chunk
    return json.loads(data) if data else None


def drain(master, timeout=2.0):
    """What reading the master gives: its bytes, then 'EOF', 'EIO' or 'blocks'."""
    data = b""
    while True:
        if not select.select([master], [], [], timeout)[0]:
            return data, "blocks"
        try:
            chunk = os.read(master, 4096)
        except OSError as error:
            return data, errno.errorcode[error.errno]
        if not chunk:
            return data, "EOF"
        data += chunk


def reporter():
    read, write = os.pipe()
    os.dup2(write, REPORT)
    os.close(write)
    return read


def close_report():
    os.close(REPORT)


def end_leader(leader, timeout=5):
    try:
        return leader.process.wait(timeout)
    except subprocess.TimeoutExpired:
        leader.process.kill()
        leader.process.wait()
        return "killed"


def verdict(name, checks, values):
    failed = [label for label, ok in checks if ok is not True]
    unknown = [label for label, ok in checks if ok is None]
    word = "INCONCLUSIVE" if unknown else ("NOT VERIFIED" if failed else "VERIFIED")
    print(json.dumps({"probe": name, "verdict": word, "failed": failed, "values": values}, default=str), flush=True)


def tty_state(fd):
    try:
        a = termios.tcgetattr(fd)
        return {"echo": bool(a[3] & termios.ECHO), "vmin": a[6][termios.VMIN]
                if isinstance(a[6][termios.VMIN], int) else ord(a[6][termios.VMIN])}
    except (OSError, termios.error) as error:
        return errno.errorcode[error.args[0]]


def probe_ownership():
    master, slave = openpty()
    read = reporter()
    process = spawn(PY + [OWNER], stdin=slave, stdout=slave, stderr=slave, pass_fds=(REPORT,))
    close_report()
    seen = report(read)
    process.wait(5)
    status_at = time.monotonic()
    after_fd = tty_state(slave)
    fresh = os.open(os.ttyname(slave), os.O_RDWR | os.O_NOCTTY)
    after_open = tty_state(fresh)
    os.close(fresh)
    output, _ = drain(master, 0.5)
    leader = process.leader
    os.close(master)
    os.close(slave)
    leader_status = end_leader(leader)
    latency_ms = round((status_at - seen["exit_at"]) * 1000, 2)
    expected = {"echo": False, "vmin": 7}
    verdict("1 terminal ownership", [
        ("/dev/tty opens", seen["dev_tty"] == "opened"),
        ("/dev/tty is the PTY", seen.get("dev_tty_is_pty")),
        ("C is foreground", seen.get("foreground")),
        ("C is not session leader", not seen["session_leader"]),
        ("fixture slave keeps C's termios", after_fd == expected),
        ("fresh open agrees", after_open == expected),
        ("exit not held by 3 unread bytes (<250 ms)", latency_ms < 250),
        ("returncode 0", process.returncode == 0),
    ], {"child": seen, "slave_after": after_fd, "fresh_open_after": after_open,
        "exit_to_status_ms": latency_ms, "unread_output": output, "leader_exit": leader_status})


def usable(master, slave):
    """The PTY still carries input both ways and keeps its attributes."""
    state = tty_state(slave)
    try:
        os.write(master, b"ping\n")
        got = b""
        deadline = time.monotonic() + 2
        while b"\n" not in got and time.monotonic() < deadline:
            if select.select([slave], [], [], 0.2)[0]:
                got += os.read(slave, 64)
        os.write(slave, b"pong")
        back, _ = drain(master, 0.3)
        return {"termios": state, "slave_read": got, "master_read": back}
    except OSError as error:
        return {"termios": state, "error": errno.errorcode[error.errno]}


def probe_shells():
    master, slave = openpty()
    process = spawn(["bash", "-c", "sleep 1"], stdin=slave, stdout=slave, stderr=slave)
    code = process.wait(5)
    after = usable(master, slave)
    read = reporter()
    second = spawn(PY + [OWNER], stdin=slave, stdout=slave, stderr=slave, pass_fds=(REPORT,))
    close_report()
    seen = report(read)
    second.wait(5)
    drain(master, 0.3)
    leader = process.leader
    os.close(master)
    os.close(slave)
    end_leader(leader)

    # Control: the same shell as the session leader with no terminal (option 1).
    control_master, control_slave = openpty()
    bare = subprocess.Popen(["bash", "-c", "sleep 1"], stdin=control_slave, stdout=control_slave,
                            stderr=control_slave, start_new_session=True)
    bare.wait(5)
    control = usable(control_master, control_slave)
    os.close(control_master)
    os.close(control_slave)

    verdict("2 shells", [
        ("bash exits 0", code == 0),
        ("slave keeps termios", isinstance(after["termios"], dict)),
        ("input reaches slave", after.get("slave_read", b"").startswith(b"ping")),
        ("output reaches master", b"pong" in after.get("master_read", b"")),
        ("next command still owns /dev/tty", seen and seen["dev_tty"] == "opened" and seen["foreground"]),
    ], {"after_bash": after, "next_command": seen, "control_bash_as_session_leader": control})


def probe_slave_copy():
    values, checks = {}, []
    for keep in (True, False):
        master, slave = openpty()
        read = reporter()
        process = spawn(PY + [OWNER], stdin=slave, stdout=slave, stderr=slave, pass_fds=(REPORT,),
                        leader_options={"keep_slave": keep})
        close_report()
        os.close(slave)
        seen = report(read)
        process.wait(5)
        data, end = drain(master, 2.0)
        leader = process.leader
        os.close(master)
        values["leader keeps slave" if keep else "leader closes slave"] = {
            "dev_tty": seen["dev_tty"], "foreground": seen.get("foreground"),
            "master_read_after_exit": data, "then": end, "leader_exit": end_leader(leader)}
        checks.append((f"/dev/tty opens (keep={keep})", seen["dev_tty"] == "opened"))
        checks.append((f"unread output survives (keep={keep})", data == b"abc"))
    # Control: today's Popen, with no leader.
    master, slave = openpty()
    bare = subprocess.Popen(PY + ["import os; os.write(1, b'abc')"], stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    bare.wait(5)
    data, end = drain(master, 2.0)
    os.close(master)
    values["control: Popen, no leader"] = {"master_read_after_exit": data, "then": end}
    verdict("3 leader's slave copy", checks, values)


def probe_status():
    master, slave = openpty()
    streams = {"stdin": slave, "stdout": slave, "stderr": slave}
    exit3 = spawn(PY + ["import sys; sys.exit(3)"], **streams).wait(5)
    victim = spawn(["sleep", "30"], **streams)
    victim.kill()
    killed = victim.wait(5)
    isig = bool(termios.tcgetattr(slave)[3] & termios.ISIG)

    def ctrl_c(**options):
        sleeper = spawn(["sleep", "30"], **streams, **options)
        os.write(master, b"\x03")
        try:
            return sleeper, sleeper.wait(2)
        except subprocess.TimeoutExpired:
            sleeper.kill()
            sleeper.wait(5)
            return sleeper, "still running"

    # The command inherits an ignored SIGINT as a Popen child does, unless the
    # fixture resets it. Pin the fixture's disposition so the run doesn't
    # depend on what started the probe.
    previous = signal.signal(signal.SIGINT, signal.SIG_IGN)
    try:
        _, inherited = ctrl_c()
        sleeper, interrupted = ctrl_c(default_signals=(signal.SIGINT,))
        control = subprocess.Popen(["sleep", "30"], stdin=slave, stdout=slave, stderr=slave)
        control.send_signal(signal.SIGINT)
        try:
            popen_ignored = control.wait(2)
        except subprocess.TimeoutExpired:
            control.kill()
            control.wait()
            popen_ignored = "still running"
        signal.signal(signal.SIGINT, signal.default_int_handler)
        _, default_interrupted = ctrl_c()
    finally:
        signal.signal(signal.SIGINT, previous)
    leader = sleeper.leader
    leader_alive = leader.process.poll() is None
    after = spawn(PY + ["pass"], **streams).wait(5)
    drain(master, 0.3)
    os.close(master)
    os.close(slave)
    end_leader(leader)
    verdict("4 status relay", [
        ("exit 3 -> 3", exit3 == 3),
        ("SIGKILL -> -9", killed == -signal.SIGKILL),
        ("ISIG on", isig),
        ("^C -> -2 (SIGINT reset by default_signals)", interrupted == -signal.SIGINT),
        ("^C -> -2 (fixture SIGINT at default)", default_interrupted == -signal.SIGINT),
        ("ignored SIGINT inherited, as Popen does", inherited == popen_ignored == "still running"),
        ("leader untouched", leader_alive),
        ("leader still runs commands", after == 0),
    ], {"exit3": exit3, "killed": killed, "isig": isig, "ctrl_c": interrupted, "ctrl_c_fixture_default": default_interrupted,
        "ctrl_c_fixture_ignores": inherited, "popen_control_fixture_ignores": popen_ignored,
        "leader_alive_after_ctrl_c": leader_alive, "next_command": after, "fixture_pid": os.getpid()})


def probe_descriptors():
    master, slave = openpty()
    read = reporter()
    hard = resource.getrlimit(resource.RLIMIT_NOFILE)[1]
    process = spawn(PY + [DESCRIPTORS], stdin=slave, stdout=slave, stderr=subprocess.PIPE, pass_fds=(REPORT,),
                    rlimits={resource.RLIMIT_NOFILE: (256, hard)})
    close_report()
    seen = report(read)
    _, err = process.communicate(timeout=5)
    failures = {}
    for label, args, extra in (("missing path", ["/nonexistent/rui"], {}),
                               ("missing on PATH", ["rui-no-such-command"], {}),
                               ("missing cwd", ["true"], {"cwd": "/nonexistent"})):
        try:
            spawn(args, stdin=slave, stdout=slave, stderr=slave, **extra)
            failures[label] = "spawned"
        except Exception as error:  # noqa: BLE001 - the probe reports the type
            failures[label] = f"{type(error).__name__}: {error}"
    after = spawn(["true"], stdin=slave, stdout=slave, stderr=slave).wait(5)
    leader = process.leader
    os.close(master)
    os.close(slave)
    end_leader(leader)
    verdict("5 descriptors", [
        ("fd 37 arrives as 37", seen is not None and seen["fd37_fifo"]),
        ("stderr PIPE", err == b"err-text"),
        ("C holds only 0,1,2,37", seen is not None and seen["held"] == [0, 1, 2, 37]),
        ("rlimits reach C (NOFILE soft 256)", seen is not None and seen["nofile_soft"] == 256),
        ("exec failures raise FileNotFoundError",
         all(v.startswith("FileNotFoundError") for v in failures.values())),
        ("leader runs commands after a failure", after == 0),
    ], {"child": seen, "stderr": err, "failures": failures, "fd_dir": FD_DIR})


def probe_hangup():
    values, checks = {}, []
    for forward in (True, False):
        master, slave = openpty()
        process = spawn(["sleep", "30"], stdin=slave, stdout=slave, stderr=slave,
                        leader_options={"forward_hangup": forward})
        leader = process.leader
        closed_at = time.monotonic()
        os.close(master)
        try:
            code = process.wait(5)
        except subprocess.TimeoutExpired:
            code = "still running after 5 s"
        ended = end_leader(leader, 5) if code != "still running after 5 s" else None
        if ended is None:
            os.kill(process.pid, signal.SIGKILL)
            ended = end_leader(leader, 5)
        os.close(slave)
        label = "leader forwards SIGHUP" if forward else "kernel only"
        values[label] = {"command": code, "leader": ended, "ms": round((time.monotonic() - closed_at) * 1000, 1)}
        if forward:
            checks += [("C gets SIGHUP on master close", code == -signal.SIGHUP),
                       ("leader ends on master close", ended == 0)]

    # The fixture dies with SIGKILL while another process keeps the master open,
    # so only the control socket tells the leader.
    master, slave = openpty()
    marker = tempfile.mktemp()
    fixture = subprocess.Popen([sys.executable, __file__, "--fixture", str(slave), marker],
                               pass_fds=(slave,), stdout=subprocess.PIPE)
    pids = json.loads(fixture.stdout.readline())
    ready = os.read(master, 1)  # C set its SIGHUP handler
    killed_at = time.monotonic()
    fixture.kill()
    fixture.wait()
    gone = {}
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline and len(gone) < 2:
        for name in ("leader", "command"):
            if name not in gone and not alive(pids[name]):
                gone[name] = round((time.monotonic() - killed_at) * 1000, 1)
        time.sleep(0.02)
    os.close(master)
    os.close(slave)
    got = open(marker).read() if os.path.exists(marker) else None
    states = {name: process_state(pids[name]) for name in ("leader", "command")}
    values["fixture SIGKILL"] = {"pids": pids, "ready": ready, "gone_after_ms": gone, "command_saw": got, "ps_state": states}
    checks += [("C gets SIGHUP on fixture death", got == "SIGHUP"),
               ("leader ends on control EOF", "leader" in gone),
               ("nothing survives", len(gone) == 2)]
    verdict("6 hangup and crash", checks, values)


def alive(pid):
    """Running, rather than gone or a zombie awaiting its reaper."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return process_state(pid) not in (None, "Z")


def process_state(pid):
    state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return state[:1] or None


def sub_fixture(slave, marker):
    process = spawn(PY + [HANGUP_WATCH, marker], stdin=slave, stdout=slave, stderr=slave)
    print(json.dumps({"leader": process.leader.process.pid, "command": process.pid}), flush=True)
    time.sleep(60)


def probe_cost():
    def percentiles(samples):
        samples = sorted(samples)
        return {"median_ms": round(statistics.median(samples) * 1000, 2),
                "p95_ms": round(samples[int(len(samples) * 0.95) - 1] * 1000, 2), "n": len(samples)}

    cold, warm, plain = [], [], []
    for _ in range(50):
        master, slave = openpty()
        started = time.perf_counter()
        process = spawn(["true"], stdin=slave, stdout=slave, stderr=slave)
        cold.append(time.perf_counter() - started)
        process.wait(5)
        started = time.perf_counter()
        again = spawn(["true"], stdin=slave, stdout=slave, stderr=slave)
        warm.append(time.perf_counter() - started)
        again.wait(5)
        leader = process.leader
        os.close(master)
        os.close(slave)
        end_leader(leader)
        master, slave = openpty()
        started = time.perf_counter()
        bare = subprocess.Popen(["true"], stdin=slave, stdout=slave, stderr=slave)
        plain.append(time.perf_counter() - started)
        bare.wait(5)
        os.close(master)
        os.close(slave)
    verdict("7 cost", [("measured", True)], {
        "new PTY (leader start + spawn)": percentiles(cold),
        "existing leader (spawn only)": percentiles(warm),
        "Popen today": percentiles(plain),
    })


PROBES = {"ownership": probe_ownership, "shells": probe_shells, "slave-copy": probe_slave_copy,
          "status": probe_status, "descriptors": probe_descriptors, "hangup": probe_hangup, "cost": probe_cost}

if __name__ == "__main__":
    if sys.argv[1:2] == ["--fixture"]:
        sub_fixture(int(sys.argv[2]), sys.argv[3])
        sys.exit(0)
    print(json.dumps({"system": platform.platform(), "python": platform.python_version()}), flush=True)
    for name in sys.argv[1:] or PROBES:
        try:
            PROBES[name]()
        except Exception as error:  # noqa: BLE001 - a crashed probe is inconclusive
            import traceback
            traceback.print_exc()
            verdict(name, [("ran", None)], {"error": repr(error)})
