#!/usr/bin/env python3
"""Bound one opt-in native assertion control; an observed owner bug exits 1.

Pass a safe-build unit binary compiled with the filter
"occupied submission fresh Action confirmation subprocess control".
The stock 0.17 test-server protocol selects only that exact test, even
when the artifact contains unrelated tests.
Use only a provenance-verified stock test artifact from the scheduled build;
executable startup is trusted, not sandboxed by metadata selection.
This is a synthetic-peer RED control, not Host acceptance qualification.
"""

import argparse
import hashlib
import json
import os
import pathlib
import re
import resource
import select
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import time

from host_process import canonical_fixture_root, enter, stop_process


TEST_NAME = "occupied submission fresh Action confirmation subprocess control"
BASE = "9534ce0368e4d5824e23fce738e2ff9a760b4606"
LOG_LIMIT = 4 * 1024 * 1024
FULL_TEST_NAME = "SessionFrontend.test." + TEST_NAME


def socket_path(root):
    # platform.zig's default route; the child verifies its actual StoreLease
    # path against this registration before it may bind or start a borrower.
    digest = hashlib.sha256(os.fsencode(root)).digest()[:16].hex()
    return pathlib.Path(f"/tmp/rui-{os.geteuid()}/{digest}.sock")


def classify(returncode, stderr, root, registered_socket):
    setup = f"OCCUPIED-SETUP store={root} socket={registered_socket}\n"
    message = re.search(
        r"OCCUPIED-MESSAGE key=([0-9a-f-]{36}) bytes=19 wire=exact response=withheld\n", stderr)
    armed = re.search(
        r"OCCUPIED-ARMED session=k7m2qx action=10 choice=allow_once "
        r"scope=(\d+) frame=(\d+) key=([0-9a-f-]{36}) task_live=true\n", stderr)
    begin_frame = re.search(r"SessionSubmission\.zig:\d+:\d+:.*\bin begin\b", stderr)
    condition = "std.debug.assert(self.intent == null and self.task.thread == null);"
    panic = "reached unreachable code" in stderr
    ordered = (message is not None and armed is not None and
               stderr.find(setup) < message.start() < armed.start() and
               begin_frame is not None and armed.end() <= begin_frame.start())
    observed = (returncode == -signal.SIGABRT and setup in stderr and ordered and
                message.group(1) == armed.group(3) and int(armed.group(2)) > 0 and
                condition in stderr and panic and "OCCUPIED-RETURNED" not in stderr)
    return {
        "classification": "occupied_submission_begin_assertion" if observed else "not_observed",
        "red_control_observed": observed,
        "returncode": returncode,
        "message_key": message.group(1) if message else None,
        "action": 10 if armed else None,
        "scope": int(armed.group(1)) if armed else None,
        "frame": int(armed.group(2)) if armed else None,
        "host_accepted": False,
    }


def select_test(metadata):
    # std/zig/Server.zig: TestMetadata, little-endian header then two u32
    # offset arrays and the NUL-terminated string table. No test runs here.
    if len(metadata) < 8:
        raise ValueError("short test metadata")
    strings_len, tests_len = struct.unpack_from("<II", metadata)
    strings_at = 8 + 8 * tests_len
    if strings_at + strings_len != len(metadata):
        raise ValueError("invalid test metadata length")
    strings = metadata[strings_at:]
    matches = []
    for index in range(tests_len):
        offset = struct.unpack_from("<I", metadata, 8 + 4 * index)[0]
        if not 0 < offset < len(strings):
            raise ValueError("invalid test name offset")
        end = strings.find(b"\0", offset)
        if end < 0:
            raise ValueError("unterminated test name")
        if strings[offset:end].decode("utf-8") == FULL_TEST_NAME:
            matches.append(index)
    if len(matches) != 1:
        raise ValueError("artifact must contain exactly one matching occupied-slot test")
    return matches[0], tests_len


def protocol(process, deadline, evidence, stdout_log):
    def transfer(fd, count=None, payload=None):
        data = bytearray()
        while (len(data) < count) if payload is None else bool(payload):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("test-server protocol deadline")
            readable, writable, _ = select.select([fd] if payload is None else [],
                                                 [] if payload is None else [fd], [], remaining)
            if not readable and not writable:
                raise TimeoutError("test-server protocol deadline")
            try:
                if payload is None:
                    piece = os.read(fd, count - len(data))
                    if not piece:
                        raise EOFError("test-server closed stdout")
                    stdout_log.write(piece)
                    data.extend(piece)
                else:
                    sent = os.write(fd, payload)
                    if sent == 0:
                        raise EOFError("test-server closed stdin")
                    payload = payload[sent:]
            except (InterruptedError, BlockingIOError):
                continue
        return bytes(data)

    def receive():
        tag, size = struct.unpack("<II", transfer(process.stdout.fileno(), count=8))
        if size > LOG_LIMIT:
            raise ValueError("test-server frame exceeds bound")
        return tag, transfer(process.stdout.fileno(), count=size)

    def send(tag, body=b""):
        transfer(process.stdin.fileno(), payload=struct.pack("<II", tag, len(body)) + body)

    os.set_blocking(process.stdout.fileno(), False)
    os.set_blocking(process.stdin.fileno(), False)
    tag, version = receive()
    if tag != 0 or version != b"0.17.0":
        raise ValueError("not the pinned Zig 0.17 test server")
    send(4)  # Client.query_test_metadata
    tag, metadata = receive()
    if tag != 3:
        raise ValueError("missing test metadata")
    index, count = select_test(metadata)
    selection = {"test": FULL_TEST_NAME, "index": index, "compiled_tests": count,
                 "metadata_sha256": hashlib.sha256(metadata).hexdigest()}
    with (evidence / "selection.json").open("x") as target:
        json.dump(selection, target, indent=2)
        target.write("\n")
        target.flush()
        os.fsync(target.fileno())
    # The only run_test emitted by this owner names the verified exact test.
    send(5, struct.pack("<I", index))
    if receive() != (5, b""):
        raise ValueError("selected test did not start")
    try:
        tag, _ = receive()
    except EOFError:
        return  # Expected only when the selected test crashes; classify stderr.
    if tag != 4:
        raise ValueError("unexpected selected-test result")
    send(0)  # Test returned, so exit without running any other compiled test.


def read_status(fd, deadline):
    data = bytearray()
    while len(data) < 4:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], max(0, remaining))[0]:
            raise TimeoutError("native exit status deadline")
        chunk = os.read(fd, 4 - len(data))
        if not chunk:
            raise EOFError("supervisor closed without native status")
        data.extend(chunk)
    return struct.unpack("<i", data)[0]


def supervise(binary, status_fd, lifetime):
    # This small, live session leader reserves its own PGID until the parent
    # kills/reaps it. A crashed native child may be reaped here without making
    # group identity depend on an exited/zombie leader's platform semantics.
    if os.getsid(0) != os.getpid() or os.getpgrp() != os.getpid():
        raise RuntimeError("supervisor must own its new session")
    deadline = time.monotonic() + lifetime
    try:
        # Bound native regular-file diagnostics during execution, not only
        # after exit. Protocol pipes are unaffected and cannot deadlock here.
        soft, hard = resource.getrlimit(resource.RLIMIT_FSIZE)
        cap = min([LOG_LIMIT] + [value for value in (soft, hard) if value != resource.RLIM_INFINITY])
        resource.setrlimit(resource.RLIMIT_FSIZE, (cap, cap))
        child = subprocess.Popen([binary, "--listen=-"], stdin=0, stdout=1, stderr=2)
        os.close(0)
        os.close(1)  # Native/descendant lifetime, not this supervisor, owns EOF.
        status = child.wait(timeout=max(0.001, deadline - time.monotonic()))
        os.write(status_fd, struct.pack("<i", status))
        os.close(status_fd)
        time.sleep(max(0, deadline - time.monotonic()))
    finally:
        # Parent failure cannot leave this session running indefinitely.
        os.killpg(os.getpid(), signal.SIGKILL)


def cleanup(process, root, registered_socket):
    if process is not None:
        if process.returncode is not None:
            raise RuntimeError("leader already reaped; cannot safely signal its old group")
        # The live supervisor reserves this session's PID/PGID until this
        # signal. Never reap the supervisor before retiring its whole group.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass  # No live members; stop_process still reaps the leader.
        stop_process(process, timeout=2)
        if process.stdin is not None:
            process.stdin.close()
        if process.returncode is None:
            raise RuntimeError("child not reaped; retain owned names for recovery")
    if registered_socket is not None:
        try:
            node = registered_socket.lstat()
        except FileNotFoundError:
            pass
        else:
            if not stat.S_ISSOCK(node.st_mode) or node.st_uid != os.geteuid():
                raise RuntimeError(f"refuse unexpected node at registered socket: {registered_socket}")
            registered_socket.unlink()
    shutil.rmtree(root)


def run(binary, evidence, timeout, expected_binary_sha256):
    binary = binary.resolve(strict=True)
    evidence.mkdir(mode=0o700, parents=True, exist_ok=False)
    root = pathlib.Path(tempfile.mkdtemp(prefix="rui-oc-", dir="/tmp"))
    # Ownership starts immediately after mkdtemp, before resolve/chmod can fail.
    registered_socket = None
    owned_socket = None
    process = None
    status_reader = None
    result = {"classification": "fixture_failure", "red_control_observed": False, "host_accepted": False}
    try:
        root = canonical_fixture_root(root)
        root.chmod(0o700)
        registered_socket = socket_path(root)
        if os.path.lexists(registered_socket):
            raise FileExistsError(f"registered socket already exists: {registered_socket}")
        owned_socket = registered_socket
        manifest = {"base": BASE, "test": FULL_TEST_NAME, "root": str(root),
                    "socket": str(registered_socket), "binary": str(binary),
                    "timeout_seconds": timeout, "socket_absent_before_launch": True}
        with binary.open("rb") as source:
            manifest["binary_sha256"] = hashlib.file_digest(source, "sha256").hexdigest()
        if manifest["binary_sha256"] != expected_binary_sha256:
            raise ValueError("binary digest does not match the registered build artifact")
        manifest["expected_binary_sha256"] = expected_binary_sha256
        with (evidence / "manifest.json").open("x") as target:
            json.dump(manifest, target, indent=2)
            target.write("\n")
            target.flush()
            os.fsync(target.fileno())
        env = os.environ.copy()
        env.update(RUI_APPROVAL_OCCUPIED_ROOT=str(root),
                   RUI_APPROVAL_OCCUPIED_SOCKET=str(registered_socket))
        deadline = time.monotonic() + timeout
        with (evidence / "stdout.log").open("xb") as stdout, (evidence / "stderr.log").open("xb") as stderr:
            status_reader, status_writer = os.pipe()
            try:
                process = subprocess.Popen([sys.executable, str(pathlib.Path(__file__).resolve()),
                                            "--supervise", str(binary), str(status_writer), str(timeout + 4)],
                                           cwd=root, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                           stderr=stderr, pass_fds=(status_writer,),
                                           start_new_session=True, umask=0o077, bufsize=0)
            finally:
                os.close(status_writer)
            result["supervisor_pid"] = process.pid
            protocol(process, deadline, evidence, stdout)
            returncode = read_status(status_reader, deadline)
            stderr_path = evidence / "stderr.log"
            if stderr_path.stat().st_size > LOG_LIMIT:
                raise RuntimeError("native diagnostic log exceeded control bound")
            result.update(classify(returncode, stderr_path.read_text(errors="replace"), root, registered_socket))
    except TimeoutError as error:
        result.update(classification="timeout", error=str(error))
    except Exception as error:
        result["error"] = f"{type(error).__name__}: {error}"
    finally:
        try:
            cleanup(process, root, owned_socket)
            result["cleanup"] = "complete"
        except Exception as error:
            result["cleanup"] = "failed"
            result["cleanup_error"] = f"{type(error).__name__}: {error}"
            result["red_control_observed"] = False
        if status_reader is not None:
            os.close(status_reader)
        result["owned_paths"] = {"root": str(root), "socket": str(owned_socket) if owned_socket else None}
        (evidence / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=pathlib.Path)
    parser.add_argument("--binary-sha256", required=True,
                        help="digest registered from the provenance-verified scheduled build artifact")
    parser.add_argument("--evidence-dir", required=True, type=pathlib.Path,
                        help="new directory for manifest, native logs, and classified result")
    parser.add_argument("--timeout-seconds", type=int, default=30, choices=range(1, 61))
    args = parser.parse_args()
    if re.fullmatch(r"[0-9a-f]{64}", args.binary_sha256) is None:
        parser.error("--binary-sha256 must be 64 lowercase hexadecimal digits")
    enter()
    result = run(args.binary, args.evidence_dir.resolve(), args.timeout_seconds, args.binary_sha256)
    print(json.dumps(result, sort_keys=True))
    # Exit 1 is deliberately RED: the exact original-custody bug was seen.
    # Exit 2 is inconclusive, including arbitrary crashes and cleanup failures.
    return 1 if result["red_control_observed"] else 2


if __name__ == "__main__":
    if sys.argv[1:2] == ["--supervise"]:
        if len(sys.argv) != 5:
            raise SystemExit("invalid internal supervisor invocation")
        supervise(sys.argv[2], int(sys.argv[3]), float(sys.argv[4]))
    else:
        raise SystemExit(main())
