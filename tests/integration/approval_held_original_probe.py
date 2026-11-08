#!/usr/bin/env python3
"""Select one held-original test under the frozen occupied-slot custody owner.

Use only a scheduled, provenance-verified native artifact and its recorded hash.
The mutation control must be separately compiled; this adapter edits no source.
A passing synthetic peer test does not establish real Host persistence.
"""

import argparse
import hashlib
import json
import pathlib
import re
import struct

import approval_occupied_slot_probe as owner


CASES = {
    "accepted": "held original wire blocks confirmation until Message joins",
    "retry": "held original wire retains unconfirmed Message until explicit same-key retry joins",
}
BASE = "087a765a8d1d34c6917e0c11b61b8af3df9a3a7e"
# The unchanged guardian, digest gate, exact test-server selector and cleanup
# implementation are independently reviewed at d297. Refuse silent divergence.
OWNER_SHA256 = "1cbd99f6c401cc3644d0f5041b30744226eccb4251aec3e36029be2832fdeb02"


def test_result(wire, selection):
    frames = []
    offset = 0
    while offset < len(wire):
        if len(wire) - offset < 8:
            raise ValueError("truncated server header")
        tag, length = struct.unpack_from("<II", wire, offset)
        offset += 8
        if length > owner.LOG_LIMIT or length > len(wire) - offset:
            raise ValueError("truncated or oversized server body")
        frames.append((tag, wire[offset:offset + length]))
        offset += length
    if [tag for tag, _ in frames] != [0, 3, 5, 4]:
        raise ValueError("selected test has no complete result sequence")
    if frames[0][1] != b"0.17.0" or frames[2][1] != b"" or len(frames[3][1]) != 12:
        raise ValueError("invalid pinned server result sequence")
    index, flags = struct.unpack("<IQ", frames[3][1])
    if index != selection["index"]:
        raise ValueError("result is not the selected test")
    # Server.Message.TestResults: status:u2, fuzz:bool, log_err_count:u30,
    # leak_count:u31. Only exact clean pass/fail counts as a control result.
    return flags


def classify(case, returncode, stderr, root, registered_socket, flags):
    setup = f"HELD-WIRE-SETUP store={root} socket={registered_socket}\n"
    delivered = re.search(
        r"HELD-WIRE-DELIVERED session=k7m2qx action=10 key=(?P<key>[0-9a-f-]{36}) "
        r"task_live=true wire=exact peer=held frame=(?P<frame>[1-9][0-9]*) delivered=true geometry=80x24 "
        r"input=empty approval=(?P<approval>held|choice) offered=(?P<offered>true|false)\n", stderr)
    failed = re.search(
        r"HELD-WIRE-PREDICATE screen\.offered\(\)==null failed "
        r"frame=(?P<frame>[1-9][0-9]*) key=(?P<key>[0-9a-f-]{36}) "
        r"actual=10:allow_once before_enter=true\n", stderr)
    ordered = setup in stderr and delivered is not None and stderr.find(setup) < delivered.start()
    requests = 2 if case == "retry" else 1
    recovered = "true" if case == "retry" else "false"
    complete = f"HELD-ORIGINAL fixture-only Message requests={requests} explicit_retry={recovered} decision=10:allow_once count=1\n"
    passed = (returncode == 0 and flags == 0 and ordered and
              delivered.group("approval", "offered") == ("held", "false") and
              failed is None and stderr.find(complete) >= delivered.end())
    # A whole original-capacity omission restores a choice while the genuine
    # exact Message request is held. The native test must fail its no-offer
    # assertion, not fail compilation, skip, leak, time out or merely crash.
    # The marker is emitted only for the same non-null value immediately
    # asserted false, before any new Enter; outer expectError hides its trace.
    omitted = (returncode == 0 and flags == 1 and ordered and
               delivered.group("approval", "offered") == ("choice", "true") and
               failed is not None and delivered.end() <= failed.start() and
               delivered.group("key", "frame") == failed.group("key", "frame") and
               complete not in stderr)
    return {
        "classification": "pass" if passed else "omission_detected" if omitted else "inconclusive",
        "native_test_pass": passed,
        "red_control_observed": omitted,
        "test_result_flags": flags,
        "returncode": returncode,
        "host_accepted": False,
        "case": case,
        "message_key": delivered.group("key") if delivered else None,
    }


def run(binary, evidence, timeout, expected_binary_sha256, case):
    owner_path = pathlib.Path(owner.__file__)
    if hashlib.sha256(owner_path.read_bytes()).hexdigest() != OWNER_SHA256:
        raise ValueError("occupied-slot custody owner is not the reviewed frozen source")
    state = {"flags": None}
    original_protocol = owner.protocol
    original_classify = owner.classify
    original_name = owner.FULL_TEST_NAME
    original_base = owner.BASE

    def protocol(process, deadline, output, stdout_log):
        original_protocol(process, deadline, output, stdout_log)
        stdout_log.flush()
        selection = json.loads((output / "selection.json").read_text())
        if selection["test"] != "SessionFrontend.test." + CASES[case]:
            raise ValueError("selection does not name the requested held-original test")
        try:
            state["flags"] = test_result((output / "stdout.log").read_bytes(), selection)
        except ValueError:
            # A native crash cannot provide a complete TestResults message;
            # retain its original logs/status and classify it inconclusive.
            state["flags"] = None

    owner.FULL_TEST_NAME = "SessionFrontend.test." + CASES[case]
    owner.BASE = BASE
    owner.protocol = protocol
    owner.classify = lambda status, stderr, root, socket: classify(case, status, stderr, root, socket, state["flags"])
    try:
        result = owner.run(binary, evidence, timeout, expected_binary_sha256)
    finally:
        owner.protocol = original_protocol
        owner.classify = original_classify
        owner.FULL_TEST_NAME = original_name
        owner.BASE = original_base
    # Reclamation is part of success for positive and omission controls alike.
    if result.get("cleanup") != "complete":
        result.update(classification="inconclusive", native_test_pass=False, red_control_observed=False)
    (evidence / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=pathlib.Path)
    parser.add_argument("--binary-sha256", required=True)
    parser.add_argument("--case", choices=CASES, required=True)
    parser.add_argument("--expect", choices=("pass", "omission"), required=True)
    parser.add_argument("--evidence-dir", required=True, type=pathlib.Path)
    parser.add_argument("--timeout-seconds", type=int, default=30, choices=range(1, 61))
    args = parser.parse_args()
    if re.fullmatch(r"[0-9a-f]{64}", args.binary_sha256) is None:
        parser.error("--binary-sha256 must be 64 lowercase hexadecimal digits")
    owner.enter()
    result = run(args.binary, args.evidence_dir.resolve(), args.timeout_seconds, args.binary_sha256, args.case)
    print(json.dumps(result, sort_keys=True))
    observed = result.get("native_test_pass", False) if args.expect == "pass" else result.get("red_control_observed", False)
    return 0 if observed else 2


if __name__ == "__main__":
    raise SystemExit(main())
