#!/usr/bin/env python3
"""Maintained Python synchronization oracle; not native Host qualification."""

import json
import os
import sys
import threading
import time
from types import SimpleNamespace
from unittest.mock import patch

from host_process import HostDiagnostics


def check_classification_oracle(run_actor):
    read_fd, write_fd = os.pipe()
    with os.fdopen(read_fd, "rb") as reader, os.fdopen(write_fd, "wb", buffering=0) as writer:
        diagnostics = HostDiagnostics(SimpleNamespace(pid=os.getpid(), stderr=reader, poll=lambda: 0))
        worker = None
        errors, results = [], []
        boundary = threading.Event()
        actor_started = threading.Event()
        released = threading.Event()
        waited = False
        last_sample = None
        deadline = time.monotonic() + 10

        def publish(record):
            writer.write(json.dumps(record).encode() + b"\n")

        pending = dict(rui_test_phase="connection_request_host_stop", subject_kind="request_number", subject="1",
                       process=str(os.getpid()), run="37", sequence="1", at_ns=str(time.monotonic_ns()),
                       clock="awake_ns", trace_lost=False)
        publish(pending)
        diagnostics.wait("connection_request_host_stop", timeout=max(0, deadline - time.monotonic()))
        began_ns = time.monotonic_ns()
        # A buffered release from an earlier exchange cannot permit the actor.
        publish(dict(pending, rui_test_phase="ordinary_classification_released", subject_kind="route",
                     subject="host_info", sequence="2", at_ns=str(began_ns - 1)))
        diagnostics.wait("ordinary_classification_released", timeout=max(0, deadline - time.monotonic()))
        original_wait = diagnostics.condition.wait

        def observed_wait(timeout=None):
            nonlocal waited
            waited = True
            boundary.set()
            return original_wait(timeout)

        def observed_monotonic():
            nonlocal last_sample
            assert threading.current_thread() is worker, "fixture clock observed outside oracle worker"
            last_sample = time.monotonic()
            return last_sample

        def invoke(*args, timeout):
            actor_started.set()
            boundary.set()
            assert released.is_set(), "actor launched before classification notification"
            assert args == ("stop", "fixture-store", "fixture-instance", "after-commit"), args
            assert last_sample is not None, "fixture clock was not sampled"
            assert 0 < timeout == deadline - last_sample, ("actor did not receive exact remaining budget", timeout)
            return "TruncatedResponse"

        def run():
            try:
                # Forward real time unchanged; observe the operand without a native clock seam.
                clock = SimpleNamespace(monotonic=observed_monotonic, monotonic_ns=time.monotonic_ns)
                with patch.object(sys.modules[run_actor.__module__], "time", clock):
                    results.append(run_actor(diagnostics, began_ns, deadline, pending,
                                             "fixture-store", "fixture-instance", invoke=invoke))
            except BaseException as error:
                errors.append(error)
            finally:
                boundary.set()

        diagnostics.condition.wait = observed_wait
        try:
            worker = threading.Thread(target=run)
            worker.start()
            assert boundary.wait(max(0, deadline - time.monotonic())), "oracle boundary not reached"
            # The controller can acquire this lock only after the actual wait
            # releases it. Thread startup alone is not evidence of blocking.
            with diagnostics.condition:
                assert not actor_started.is_set(), "actor launched before classification notification"
                assert waited and not errors, ("oracle never entered condition wait", errors)
                released.set()
                publish(dict(pending, rui_test_phase="ordinary_classification_released", subject_kind="route",
                             subject="host_info", sequence="3", at_ns=str(time.monotonic_ns())))
            worker.join(max(0, deadline - time.monotonic()))
            assert not worker.is_alive(), "oracle did not finish within original stop budget"
            assert not errors, errors
            assert actor_started.is_set() and results == ["TruncatedResponse"], results
        finally:
            writer.close()
            if worker is not None:
                worker.join(max(0, deadline - time.monotonic()))
                assert not worker.is_alive(), "oracle worker did not drain within original stop budget"
            diagnostics.close()
        print("host-stop oracle passed: actual condition wait/no actor, correlated release then launch")


if __name__ == "__main__":
    import host_stop_integration as stop
    check_classification_oracle(stop.actor_after_classification)
