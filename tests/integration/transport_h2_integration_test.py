#!/usr/bin/env python3
"""Transcript-oracle counterexamples; same h2 dependency and binary arg as fixture."""
import copy
import contextlib
import io
import json
import pathlib
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import codex_h2_integration as codex_h2
import transport_h2_integration as transport


class HostReply:
    sent = False
    released = False

    def __init__(self, body=b"{}", content_type=b"application/json"):
        self.body = body
        self.content_type = content_type

    def settimeout(self, timeout):
        pass

    def connect(self, path):
        pass

    def sendall(self, data):
        pass

    def recv(self, size):
        if self.sent:
            self.released = True
            return b""
        self.sent = True
        return (b"HTTP/1.1 200 OK\r\nContent-Type: " + self.content_type
                + b"\r\nContent-Length: " + str(len(self.body)).encode() + b"\r\n\r\n" + self.body)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass


class RoundTripHistoryTests(unittest.TestCase):
    def setUp(self):
        self.streams = []
        self.answers = {}
        histories = [[], []]
        for wave in range(3):
            for index in range(2):
                text = f"h2-2-{wave}-{index}"
                stream = len(self.streams) * 2 + 1
                user = {"role": "user", "content": [{"type": "input_text", "text": text}]}
                request = {"input": [*histories[index], user]}
                self.streams.append(("connection", stream, text, json.dumps(request).encode()))
                answer = transport.observed_shape_answer(text)
                self.answers[text] = answer.encode()
                _, reasoning, message = transport.dispatch.sse_answer(
                    f"response-{stream}", f"reasoning-{stream}", f"message-{stream}", answer,
                )
                del reasoning["created_by"]
                histories[index] = [*request["input"], reasoning, message]

    def test_complete_history(self):
        transport.assert_round_trip_history(self.streams, 2, 3, self.answers)

    def test_corrupted_history_keeps_latest_prompt_but_must_fail(self):
        original = json.loads(self.streams[-1][3])["input"]
        mutations = {
            "omit_all_history": original[-1:],
            "omit_oldest_turn": original[3:],
            "duplicate_item": [original[0], *original],
            "reorder_output": [original[0], original[2], original[1], *original[3:]],
            "other_session": [json.loads(self.streams[-2][3])["input"][0], *original[1:]],
            "extra_item": [*original, original[1]],
        }
        for name, position, field in (("alter_answer", 2, "content"), ("alter_reasoning", 1, "encrypted_content")):
            changed = copy.deepcopy(original)
            changed[position][field] = [] if field == "content" else "wrong-private-reasoning"
            mutations[name] = changed
        for name, items in mutations.items():
            with self.subTest(name=name):
                # Every mutation passes the former latest-user oracle.
                latest = next(item["content"][0]["text"] for item in reversed(items) if item.get("role") == "user")
                self.assertEqual(latest, self.streams[-1][2])
                corrupted = list(self.streams)
                address, stream, text, _ = corrupted[-1]
                corrupted[-1] = (address, stream, text, json.dumps({"input": items}).encode())
                with self.assertRaisesRegex(AssertionError, "history"):
                    transport.assert_round_trip_history(corrupted, 2, 3, self.answers)


class ShapedWorkTests(unittest.TestCase):
    def test_all_caller_cleanup_precedes_first_fd_baseline(self):
        for kind in ("configure", "message", "observe_command", "read_result", "inspect_session"):
            with self.subTest(kind=kind):
                reply = HostReply(content_type=b"text/plain" if kind == "read_result" else b"application/json")
                with patch.object(transport.socket, "socket", return_value=reply):
                    transport.closed_host_request("/fixture/socket", pathlib.Path("/fixture"), kind)
                baseline = 10 + (0 if reply.released else 1)
                self.assertEqual(baseline, 10, "caller resources contaminated the first FD baseline")
                # An inflated baseline would wrongly accept a later retained FD.
                self.assertGreater(11, baseline)

    def test_per_stream_shape_rejects_compensated_event_loss(self):
        payload, _ = transport.observed_shape_sse(1, "h2-2-0-0")
        transport.assert_observed_shape_work(payload)
        records = payload.split(b"\n\n")
        dropped = b"\n\n".join(records[:5] + records[6:])
        doubled = b"\n\n".join(records[:5] + [records[5]] + records[5:])
        self.assertEqual(len(dropped) + len(doubled), 2 * len(payload))
        for corrupted in (dropped, doubled):
            with self.assertRaisesRegex(AssertionError, "shape"):
                transport.assert_observed_shape_work(corrupted)
        changed = payload.replace(b'"synthetic_padding":"', b'"synthetic_padding":"x', 1)
        with self.assertRaisesRegex(AssertionError, "shape lifecycle bytes"):
            transport.assert_observed_shape_work(changed)

    def test_later_wave_failure_preserves_completed_evidence(self):
        endpoint = SimpleNamespace(server_address=("localhost", 1), streams=[("connection", 1, "h2-1-0-0", b"")],
                                   answers={"h2-1-0-0": b"answer"}, observed_shape=True)
        calls = []

        def request(socket_path, store, kind, **fields):
            calls.append(kind)
            if kind == "message" and calls.count(kind) == 2:
                raise RuntimeError("wave 2 failed")
            return {
                "configure": {"answer": {"status": "accepted"}},
                "message": {"answer": {"status": "accepted"}},
                "observe_command": {"observation": {"result": {"status": "completed"}}},
                "read_result": b"answer",
                "inspect_session": {"execution": {"custody_occupied": "0", "scratch_used_bytes": "0"}},
            }[kind]

        output = io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(contextlib.redirect_stdout(output))
            stack.enter_context(patch.object(transport.dispatch, "start_ready_process",
                                            return_value=(SimpleNamespace(pid=123), {"socket": "/fixture/socket"})))
            stop = stack.enter_context(patch.object(transport.dispatch, "stop_host"))
            stack.enter_context(patch.object(transport, "closed_host_request", side_effect=request))
            stack.enter_context(patch.object(transport.dispatch, "wait_for", side_effect=lambda predicate, *args, **kwargs: predicate()))
            stack.enter_context(patch.object(transport, "open_descriptors", return_value=12))
            stack.enter_context(patch.object(transport, "host_physical_peak", return_value=123456))
            with self.assertRaisesRegex(RuntimeError, "wave 2 failed"):
                transport.round_trip(pathlib.Path("/fixture"), endpoint, 1, pathlib.Path("/fixture/ca"))
            stop.assert_called_once()
        self.assertEqual(calls, ["configure", "message", "observe_command", "observe_command",
                                 "read_result", "inspect_session", "message"])
        rows = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(rows), 2, "completed wave and failure evidence must both survive")
        self.assertEqual(rows[0]["round"], 1)
        self.assertEqual(rows[0]["host_physical_peak_bytes"], 123456)
        self.assertEqual(rows[1]["status"], "failed")
        self.assertEqual(rows[1]["host_physical_peaks_by_round"], [123456])


class ManagedDescriptorTests(unittest.TestCase):
    def test_inherited_allocator_descriptor_preserves_exact_managed_boundary(self):
        for inherited, required in ((3, 77), (4, 78)):
            with self.subTest(inherited=inherited):
                rejected = SimpleNamespace(returncode=1, stdout="", stderr=(
                    "rui: descriptor capacity insufficient: active_capacity=1 "
                    f"required={required} soft_limit=76 inherited={inherited} "
                    "fixed_host=11 clients=42 execution=10 authentication=10 self_wake=1\n"))
                with patch.object(codex_h2.sys, "platform", "darwin"):
                    self.assertEqual(codex_h2.assert_managed_descriptor_rejection(rejected, 76), required)

    def test_wrong_owner_populations_cannot_be_accepted_as_inherited_variation(self):
        correct = ("rui: descriptor capacity insufficient: active_capacity=1 "
                   "required=78 soft_limit=77 inherited=4 fixed_host=11 clients=42 "
                   "execution=10 authentication=10 self_wake=1\n")
        for before, after in (("required=78", "required=77"), ("authentication=10", "authentication=9"),
                              ("inherited=4", "inherited=5"), ("soft_limit=77", "soft_limit=76")):
            with self.subTest(before=before):
                rejected = SimpleNamespace(returncode=1, stdout="", stderr=correct.replace(before, after))
                with patch.object(codex_h2.sys, "platform", "darwin"):
                    with self.assertRaises(AssertionError):
                        codex_h2.assert_managed_descriptor_rejection(rejected, 77)


class ObservationDeadlineTests(unittest.TestCase):
    def test_blocking_predicate_cannot_publish_a_late_clean_observation(self):
        for completed_at in (7.999, 8.0, 15.0):
            with self.subTest(completed_at=completed_at):
                clock = [0.0]

                def inspect():
                    clock[0] = completed_at
                    return {"custody_occupied": "0", "scratch_used_bytes": "0"}

                with patch.object(transport.dispatch.time, "monotonic", side_effect=lambda: clock[0]):
                    if completed_at < 8:
                        self.assertEqual(transport.dispatch.wait_for(inspect, "physical cleanup"),
                                         {"custody_occupied": "0", "scratch_used_bytes": "0"})
                    else:
                        with self.assertRaisesRegex(AssertionError, "physical cleanup"):
                            transport.dispatch.wait_for(inspect, "physical cleanup")


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
