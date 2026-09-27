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

import transport_h2_integration as transport


class InspectionReply:
    sent = False
    released = False

    def settimeout(self, timeout):
        pass

    def recv(self, size):
        if self.sent:
            self.released = True
            return b""
        self.sent = True
        body = b'{"execution":{"custody_occupied":"0","scratch_used_bytes":"0"}}'
        return b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body

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
    def test_inspection_cleanup_precedes_first_fd_baseline(self):
        reply = InspectionReply()
        self.assertTrue(transport.inspection_drained(reply))
        baseline = 10 + (0 if reply.released else 2)
        self.assertEqual(baseline, 10, "inspection resources contaminated the first FD baseline")
        # The unqualified count of 12 would wrongly accept two retained FDs.
        self.assertGreater(12, baseline)

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
        output = io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(contextlib.redirect_stdout(output))
            stack.enter_context(patch.object(transport.dispatch, "start_ready_process",
                                            return_value=(SimpleNamespace(pid=123), {"socket": "/fixture/socket"})))
            stop = stack.enter_context(patch.object(transport.dispatch, "stop_host"))
            stack.enter_context(patch.object(transport.dispatch, "configure"))
            stack.enter_context(patch.object(transport.dispatch, "message", side_effect=[None, RuntimeError("wave 2 failed")]))
            stack.enter_context(patch.object(transport.dispatch, "wait_for", side_effect=lambda predicate, *args, **kwargs: predicate()))
            stack.enter_context(patch.object(transport.dispatch, "observe", return_value={"result": {"status": "completed"}}))
            stack.enter_context(patch.object(transport.dispatch, "read_result", return_value=b"answer"))
            stack.enter_context(patch.object(transport.control, "open_complete_inspection", return_value=InspectionReply()))
            stack.enter_context(patch.object(transport, "open_descriptors", return_value=12))
            stack.enter_context(patch.object(transport, "host_physical_peak", return_value=123456))
            with self.assertRaisesRegex(RuntimeError, "wave 2 failed"):
                transport.round_trip(pathlib.Path("/fixture"), endpoint, 1, pathlib.Path("/fixture/ca"))
            stop.assert_called_once()
        rows = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(rows), 2, "completed wave and failure evidence must both survive")
        self.assertEqual(rows[0]["round"], 1)
        self.assertEqual(rows[0]["host_physical_peak_bytes"], 123456)
        self.assertEqual(rows[1]["status"], "failed")
        self.assertEqual(rows[1]["host_physical_peaks_by_round"], [123456])


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
