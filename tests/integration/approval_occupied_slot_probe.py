#!/usr/bin/env python3
"""Bound one opt-in native assertion control; an observed owner bug exits 1.

Pass a safe-build unit binary compiled with the filter
"occupied submission fresh Action confirmation subprocess control".
This is a synthetic-peer RED control, not Host acceptance qualification.
"""

import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import signal
import stat
import subprocess
import tempfile
import time

from host_process import canonical_fixture_root, enter, stop_process


TEST_NAME = "occupied submission fresh Action confirmation subprocess control"
BASE = "9534ce0368e4d5824e23fce738e2ff9a760b4606"
LOG_LIMIT = 4 * 1024 * 1024


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


def cleanup(process, root, registered_socket):
    # Only a process created with start_new_session=True enters this function.
    # Never signal a global name, a reused user process, or the parent group.
    if process is not None and process.returncode is None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass  # It exited before the signal; stop_process still reaps it.
        stop_process(process, timeout=2)
    if process is not None and process.returncode is None:
        raise RuntimeError("child not reaped; retain owned names for recovery")
    try:
        node = registered_socket.lstat()
    except FileNotFoundError:
        pass
    else:
        if not stat.S_ISSOCK(node.st_mode) or node.st_uid != os.geteuid():
            raise RuntimeError(f"refuse unexpected node at registered socket: {registered_socket}")
        registered_socket.unlink()
    shutil.rmtree(root)


def run(binary, evidence, timeout):
    binary = binary.resolve(strict=True)
    evidence.mkdir(mode=0o700, parents=True, exist_ok=False)
    root = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-oc-", dir="/tmp"))
    root.chmod(0o700)
    registered_socket = socket_path(root)
    process = None
    result = {"classification": "fixture_failure", "red_control_observed": False, "host_accepted": False}
    manifest = {"base": BASE, "test": TEST_NAME, "root": str(root),
                "socket": str(registered_socket), "binary": str(binary),
                "timeout_seconds": timeout}
    try:
        if os.path.lexists(registered_socket):
            # It was not emitted by this child. Never unlink or reclaim it.
            raise FileExistsError(f"registered socket already exists: {registered_socket}")
        manifest["socket_absent_before_launch"] = True
        with binary.open("rb") as source:
            manifest["binary_sha256"] = hashlib.file_digest(source, "sha256").hexdigest()
        # Durable registration precedes process launch, including a crash in
        # setup before the child can print its verified-path marker.
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
            process = subprocess.Popen([str(binary)], cwd=root, env=env, stdin=subprocess.DEVNULL,
                                       stdout=stdout, stderr=stderr, start_new_session=True, umask=0o077)
            try:
                process.wait(timeout=max(0.001, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                result["classification"] = "timeout"
            else:
                stderr_path = evidence / "stderr.log"
                if stderr_path.stat().st_size > LOG_LIMIT:
                    raise RuntimeError("native diagnostic log exceeded control bound")
                result = classify(process.returncode, stderr_path.read_text(errors="replace"), root, registered_socket)
    except Exception as error:
        result["error"] = f"{type(error).__name__}: {error}"
    finally:
        try:
            # A pre-existing socket never enters our cleanup authority.
            if not manifest.get("socket_absent_before_launch"):
                shutil.rmtree(root)
            else:
                cleanup(process, root, registered_socket)
            result["cleanup"] = "complete"
        except Exception as error:
            result["cleanup"] = "failed"
            result["cleanup_error"] = f"{type(error).__name__}: {error}"
            result["red_control_observed"] = False
        result["owned_paths"] = {"root": str(root), "socket": str(registered_socket)}
        (evidence / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=pathlib.Path)
    parser.add_argument("--evidence-dir", required=True, type=pathlib.Path,
                        help="new directory for manifest, native logs, and classified result")
    parser.add_argument("--timeout-seconds", type=int, default=30, choices=range(1, 61))
    args = parser.parse_args()
    enter()
    result = run(args.binary, args.evidence_dir.resolve(), args.timeout_seconds)
    print(json.dumps(result, sort_keys=True))
    # Exit 1 is deliberately RED: the exact original-custody bug was seen.
    # Exit 2 is inconclusive, including arbitrary crashes and cleanup failures.
    return 1 if result["red_control_observed"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
