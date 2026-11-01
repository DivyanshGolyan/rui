#!/usr/bin/env python3
"""Transcript-oracle counterexamples; same h2 dependency and binary arg as fixture."""
import copy
import contextlib
import http.client
import io
import json
import pathlib
import sys
import tempfile
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import codex_h2_integration as codex_h2
import os_semantics
import transport_h2_integration as transport
import host_process


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
    def test_every_caller_waits_for_peer_eof(self):
        for kind in ("configure", "message", "observe_command", "read_result", "inspect_session"):
            with self.subTest(kind=kind):
                reply = HostReply(content_type=b"text/plain" if kind == "read_result" else b"application/json")
                with patch.object(transport.socket, "socket", return_value=reply):
                    transport.closed_host_request("/fixture/socket", pathlib.Path("/fixture"), kind)
                self.assertTrue(reply.released, "caller returned before peer EOF")

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
        reports = []

        def request(socket_path, store, kind, **fields):
            calls.append(kind)
            reports.append(kind)  # EOF can precede disposal of any caller's report.
            if kind == "message" and calls.count(kind) == 2:
                raise RuntimeError("wave 2 failed")
            if kind == "read_result":
                self.assertEqual(fields.get("deadline"), 45.0,
                                 "exact result read must retain the original result deadline")
            return {
                "configure": {"answer": {"status": "accepted", "session": "abc123"}},
                "message": {"answer": {"status": "accepted"}},
                "observe_command": {"observation": {"result": {"status": "completed"}}},
                "read_result": b"answer",
                "inspect_session": {"execution": {"dispatch_fenced": False, "custody_occupied": "0", "scratch_used_bytes": "0"}},
            }[kind]

        def census(deadline, routes):
            self.assertEqual(deadline, 20.0)
            self.assertEqual(routes, ["configure", "message", "observe", "read_result", "inspect"])
            reports.clear()

        def descriptors(pid):
            self.assertFalse(reports, "H2 caller report remains open after EOF at idle sample")
            return 12

        output = io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(contextlib.redirect_stdout(output))
            stack.enter_context(patch.object(transport.time, "monotonic", return_value=0.0))
            stack.enter_context(patch.object(transport.dispatch, "start_ready_process",
                                            return_value=(SimpleNamespace(pid=123), {"socket": "/fixture/socket"})))
            stack.enter_context(patch.object(transport, "HostDiagnostics", return_value=SimpleNamespace(
                observations=SimpleNamespace(plan="transport"),
                borrower_census=census)))
            stop = stack.enter_context(patch.object(transport.dispatch, "stop_host"))
            stack.enter_context(patch.object(transport, "closed_host_request", side_effect=request))
            stack.enter_context(patch.object(transport.dispatch, "wait_for", side_effect=lambda predicate, *args, **kwargs: predicate()))
            stack.enter_context(patch.object(transport, "open_descriptors", side_effect=descriptors))
            stack.enter_context(patch.object(transport, "host_physical_peak", return_value=123456))
            with self.assertRaisesRegex(RuntimeError, "wave 2 failed"):
                transport.round_trip(pathlib.Path("/fixture"), endpoint, 1, pathlib.Path("/fixture/ca"))
            stop.assert_called_once()
        self.assertEqual(calls, ["configure", "message", "observe_command",
                                 "read_result", "inspect_session", "message"])
        rows = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(rows), 2, "completed wave and failure evidence must both survive")
        self.assertEqual(rows[0]["round"], 1)
        self.assertEqual(rows[0]["host_physical_peak_bytes"], 123456)
        self.assertEqual(rows[1]["status"], "failed")
        self.assertEqual(rows[1]["host_physical_peaks_by_round"], [123456])


class ManagedDescriptorTests(unittest.TestCase):
    def test_managed_transfer_cannot_renew_result_read_or_release_budget(self):
        cases = ((platform, inherited, observed, intake)
                 for platform, inherited in (("linux", 3), ("darwin", 3), ("darwin", 4))
                 for observed, intake in ((False, 100), (True, 100), (False, 10)))
        for platform, inherited, observed, intake in cases:
            for late in (None, "read", "release", "preparation_completed", "codex_transfer",
                         "preparation_completed_at_deadline", "codex_transfer_at_deadline"):
                with self.subTest(platform=platform, inherited=inherited, observed=observed,
                                  intake=intake, late=late), tempfile.TemporaryDirectory() as temporary:
                    root = pathlib.Path(temporary) / "managed"
                    root.mkdir()
                    clock = [0.0]
                    launches = []
                    headers = {b":path": b"/responses", b"content-length": b"2", b"accept-encoding": b"identity",
                               b"content-type": b"application/json", b"accept": b"text/event-stream", b"session-id": b"a" * 32,
                               b"originator": b"rui", b"authorization": ("Bearer " + codex_h2.codex.ACCESS).encode(),
                               b"chatgpt-account-id": codex_h2.codex.ACCOUNT.encode(), b"user-agent": b"rui/test-revision"}
                    body = json.dumps({"text": {"verbosity": "low"}, "parallel_tool_calls": False}).encode()
                    endpoint = SimpleNamespace(server_address=("localhost", 1), serve_forever=lambda: None,
                        shutdown=lambda: None, server_close=lambda: None,
                        streams=[("connection", index, None, body) for index in (1, 3, 5)], connections=["connection"],
                        request_headers=[headers, headers, {**headers, b"x-openai-fedramp": b"true"}])
                    identities = [dict(turn=str(7 + index), operation=str(11 + index), attempt="2") for index in range(3)]
                    transfers = [{"rui_test_phase": "codex_transfer", "operation": identities[index]["operation"],
                                  "new_connections": str(index == 0 and 1 or 0), "replays": "0"}
                                 for index in range(3)]
                    preparations = [dict(identity, rui_test_phase="preparation_completed") for identity in identities]
                    observation_index = [0]
                    forwarded = []

                    def matching(phase, **fields):
                        if fields:
                            forwarded.append((phase, fields))
                            if late == phase + "_at_deadline":
                                clock[0] = 20.0
                            elif phase == late:
                                clock[0] = 20.1
                        return [row for row in [*transfers, *preparations]
                                if row["rui_test_phase"] == phase and all(row.get(name) == value for name, value in fields.items())]

                    diagnostics = SimpleNamespace(records=[*transfers, *preparations], wait=lambda *args, **kwargs: transfers,
                        matching=matching)

                    def command(resource, operation, *args, **kwargs):
                        if (resource, operation) == ("session", "configure"):
                            return {"answer": {"status": "accepted", "session": "abc123"}}
                        if (resource, operation) == ("request", "inspect"):
                            # Observation has its own 15-second command cap;
                            # leave the cumulative crossing to read or release.
                            clock[0] += 14.9
                            identity = identities[observation_index[0]]
                            observation_index[0] += 1
                            return {"observation": {"result": {"status": "completed"}, "processing": identity}}
                        clock[0] += 0.2 if late == "release" else 0.01
                        return {"execution": {"custody_occupied": "0", "scratch_used_bytes": "0", "dispatch_fenced": False}}

                    def process(args, **kwargs):
                        if args[0] == "openssl":
                            return SimpleNamespace(returncode=0)
                        if args[0] == "sh":
                            fixed, authentication = (9, 7) if platform == "darwin" else (8, 6)
                            required = inherited + fixed + 403 + 10 + authentication + 2
                            limit = int(args[4])
                            launches.append(limit)
                            if limit >= required - 360:
                                return SimpleNamespace(returncode=0, stdout="ready ", stderr="")
                            return SimpleNamespace(returncode=1, stdout="", stderr=(
                                "descriptor capacity insufficient: active_capacity=1 "
                                f"required={required} soft_limit={limit} inherited={inherited} fixed_host={fixed} "
                                f"clients=403 execution=10 authentication={authentication} self_wake=2"))
                        clock[0] += 5.2 if late == "read" else 4.95
                        key = args[-1]
                        text = "managed-federal" if key == "federal" else f"managed-{key[-1]}"
                        answer = "L" * 8192 + text if key == "message-1" else f"answer-{text}"
                        return SimpleNamespace(returncode=0, stdout=answer.encode(), stderr=b"")

                    def start(args, **kwargs):
                        # Derive the launch contract independently for all
                        # three native inherited populations and both intakes.
                        full = (432 if platform == "linux" else 434) + inherited - 3
                        limit = full - (360 if intake == 10 else 0) + (2 if observed else 0)
                        self.assertEqual(int(args[4]), limit)
                        self.assertEqual(kwargs["required_fields"]["intake_capacity"], str(intake))
                        self.assertEqual(kwargs["required_fields"]["descriptor_requirement"], str(limit))
                        self.assertEqual(kwargs["required_fields"]["descriptor_limit"], str(limit))
                        self.assertEqual(launches, [71 if platform == "linux" else 73] +
                                         ([74] if inherited == 4 else []))
                        return SimpleNamespace(pid=1), {}

                    with contextlib.ExitStack() as stack:
                        stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                        stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
                        stack.enter_context(patch.dict(codex_h2.os.environ))
                        stack.enter_context(os_semantics.simulate(platform))
                        stack.enter_context(patch.object(transport.time, "monotonic", side_effect=lambda: clock[0]))
                        stack.enter_context(patch.object(codex_h2.tempfile, "mkdtemp", return_value=str(root)))
                        stack.enter_context(patch.object(codex_h2.ssl, "SSLContext"))
                        stack.enter_context(patch.object(codex_h2.h2_fixture, "Endpoint", return_value=endpoint))
                        thread = stack.enter_context(patch.object(codex_h2.threading, "Thread"))
                        thread.return_value.is_alive.return_value = False
                        stack.enter_context(patch.object(codex_h2, "start_ready_process", side_effect=start))
                        stack.enter_context(patch.object(codex_h2, "HostDiagnostics", return_value=diagnostics))
                        stack.enter_context(patch.object(codex_h2.fixture, "command", side_effect=command))
                        stack.enter_context(patch.object(codex_h2.fixture, "message"))
                        stack.enter_context(patch.object(codex_h2.fixture, "stop_host"))
                        stack.enter_context(patch.object(codex_h2.codex, "expected_user_agent", return_value="rui/test-revision"))
                        stack.enter_context(patch.object(codex_h2.subprocess, "run", side_effect=process))
                        if late is None or (not observed and late not in ("read", "release")):
                            codex_h2.run(observed=observed, intake=intake)
                            if observed:
                                self.assertEqual(forwarded, [entry for identity in identities for entry in (
                                    ("preparation_completed", identity), ("codex_transfer", {"operation": identity["operation"]}))])
                        else:
                            with self.assertRaisesRegex(AssertionError, "original deadline|preparation_completed|codex_transfer"):
                                codex_h2.run(observed=observed, intake=intake)

    def test_inherited_allocator_descriptor_preserves_exact_managed_boundary(self):
        for inherited, required in ((3, 434), (4, 435)):
            with self.subTest(inherited=inherited):
                rejected = SimpleNamespace(returncode=1, stdout="", stderr=(
                    "rui: descriptor capacity insufficient: active_capacity=1 "
                    f"required={required} soft_limit=73 inherited={inherited} "
                    "fixed_host=9 clients=403 execution=10 authentication=7 self_wake=2\n"))
                with os_semantics.simulate("darwin"):
                    self.assertEqual(codex_h2.assert_managed_descriptor_rejection(rejected, 73), required)

    def test_wrong_owner_populations_cannot_be_accepted_as_inherited_variation(self):
        correct = ("rui: descriptor capacity insufficient: active_capacity=1 "
                   "required=435 soft_limit=74 inherited=4 fixed_host=9 clients=403 "
                   "execution=10 authentication=7 self_wake=2\n")
        for before, after in (("required=435", "required=434"), ("authentication=7", "authentication=6"),
                              ("inherited=4", "inherited=5"), ("soft_limit=74", "soft_limit=73")):
            with self.subTest(before=before):
                rejected = SimpleNamespace(returncode=1, stdout="", stderr=correct.replace(before, after))
                with os_semantics.simulate("darwin"):
                    with self.assertRaises(AssertionError):
                        codex_h2.assert_managed_descriptor_rejection(rejected, 74)


class HeldResponseBoundaryTests(unittest.TestCase):
    def test_complete_response_does_not_wait_for_handler_retirement(self):
        tail_entered = threading.Event()
        release_tail = threading.Event()

        class HeldTail(transport.HeldHandler):
            def __setattr__(self, name, value):
                super().__setattr__(name, value)
                if (name == "close_connection" and value is True
                        and getattr(self, "requestline", "").startswith("POST")
                        and getattr(self, "_headers_buffer", None) == []
                        and not tail_entered.is_set()):
                    tail_entered.set()
                    assert release_tail.wait(5), "post-response handler tail was not released"

        with patch.object(transport, "HeldHandler", HeldTail), \
                patch.object(transport.socket, "getfqdn", side_effect=OSError("reverse DNS unavailable")):
            endpoint = transport.HeldEndpoint()
        endpoint.release_first.set()
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        thread.start()
        try:
            for text in ("first", "second"):
                connection = http.client.HTTPConnection("127.0.0.1", endpoint.server_port, timeout=3)
                try:
                    body = json.dumps({"input": [{"role": "user", "content": [{"text": text}]}]})
                    connection.request("POST", "/responses", body)
                    response = connection.getresponse()
                    expected, _, _ = transport.dispatch.sse_answer(
                        f"response-{text}", f"reasoning-{text}", f"message-{text}", f"answer-{text}")
                    self.assertEqual(response.status, 200)
                    self.assertEqual(response.read(), expected)
                finally:
                    connection.close()
                self.assertTrue(tail_entered.wait(1))
                self.assertFalse(release_tail.is_set())
            with endpoint.lock:
                self.assertEqual([text for text, _ in endpoint.requests], ["first", "second"])
                self.assertEqual(endpoint.maximum_active, 1)
                self.assertEqual(endpoint.active, 0)
        finally:
            release_tail.set()
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)
            self.assertFalse(thread.is_alive())


class HeldPopulationCleanupTests(unittest.TestCase):
    def test_actual_caller_preserves_body_error_and_attempts_every_disposal(self):
        self.run_caller("held_population", fail_body=True)

    def test_successful_body_reports_cleanup_failure_after_every_disposal(self):
        self.run_caller("held_population", fail_body=False)

    def test_startup_failure_still_disposes_endpoint(self):
        self.run_caller("held_population", fail_body=False, fail_start=True)

    def test_actual_body_requires_every_caller_eof_before_first_idle_sample(self):
        self.run_caller("held_population", fail_body=False, eof_oracle=True)
        for kind in ("configure", "message", "observe_command", "read_result", "inspect_session"):
            with self.subTest(omitted_eof=kind):
                self.run_caller("held_population", fail_body=False, eof_oracle=True, omitted_eof=kind)

    def test_idle_samples_require_report_retirement_after_every_caller_eof(self):
        for kind in ("configure", "message", "observe_command", "read_result", "inspect_session"):
            with self.subTest(held_report=kind):
                self.run_caller("held_population", fail_body=False, eof_oracle=True, held_report=kind)

    def test_native_retirement_does_not_excuse_a_retained_descriptor(self):
        self.run_caller("held_population", fail_body=False, eof_oracle=True, leaked_descriptor=True)

    def run_caller(self, caller, *, fail_body, fail_start=False, eof_oracle=False, omitted_eof=None, held_report=None, leaked_descriptor=False):
        calls = []
        primary = AssertionError("original held population body failure")
        secondary = RuntimeError("endpoint shutdown failure")
        endpoint = SimpleNamespace(server_port=1, lock=contextlib.nullcontext(),
            first_ready=SimpleNamespace(wait=lambda timeout: True), requests=[],
            connections=[], active=1, maximum_active=1, h2_connections=1, serve_forever=lambda: None)
        released = [False]

        def release():
            calls.append("release")
            released[0] = True

        endpoint.release_first = SimpleNamespace(set=release)

        def shutdown():
            calls.append("shutdown")
            if not eof_oracle:
                raise secondary

        endpoint.shutdown = shutdown
        endpoint.server_close = lambda: calls.append("close")
        thread = SimpleNamespace(start=lambda: None,
            join=lambda *, timeout: calls.append(("join", timeout)), is_alive=lambda: False)

        def start(*args, **kwargs):
            if fail_start:
                raise primary
            return SimpleNamespace(pid=1, rui_ready_fields={"socket": "/fixture/socket"})

        def message(root, store, key, session, text):
            if fail_body:
                raise primary
            # Every stream arrives at once; only the first response is held.
            endpoint.requests.append((text, b""))
            endpoint.connections.append(text)

        def observe(store, key, **kwargs):
            if not kwargs:
                return {"processing": {"attempt": "1"}}
            return {"result": {"status": "completed"}}

        def drain(*args):
            endpoint.active = 0

        reads = []

        def read(store, key, **kwargs):
            reads.append(key)
            text = key.replace("held-message-", "held-")
            return ("answer-" + text).encode()

        replies = []
        samples = []
        real_request = transport.closed_host_request

        def request(socket_path, store, kind, **fields):
            if kind == "message":
                self.assertEqual(fields["session"], "abc123")
                message(None, store, fields["key"], fields["session"], fields["text"]["value"])
            if kind == "observe_command":
                value = {"observation": observe(store, fields["key"],
                         **({"deadline": fields["deadline"]} if "deadline" in fields else {}))}
            elif kind == "read_result":
                value = read(store, fields["key"], deadline=fields["deadline"])
            elif kind == "inspect_session":
                self.assertEqual(fields["session"], "abc123")
                value = {"execution": {"dispatch_fenced": False, "scratch_used_bytes": "0",
                         "custody_occupied": "0" if released[0] else "1"}}
                if released[0]:
                    endpoint.active = 0
            else:
                if kind == "configure":
                    self.assertEqual(fields["session"], "", "wire creation must not request a caller-chosen Session")
                value = {"answer": {"status": "accepted", "session": "abc123"}}
            if not eof_oracle:
                return value
            # Body and EOF are separate recv events, including the final
            # inspection. A later request cannot release an earlier caller.
            reply = HostReply(body=value if isinstance(value, bytes) else json.dumps(value).encode(),
                              content_type=b"text/plain" if kind == "read_result" else b"application/json")
            reply.report_released = kind != held_report
            replies.append((kind, reply))
            with patch.object(transport.socket, "socket", return_value=reply):
                if kind == omitted_eof:
                    # Model the old Content-Length-only completion boundary.
                    _, body = transport.control.read_http_response(reply)
                    return body if kind == "read_result" else json.loads(body)
                return real_request(socket_path, store, kind, **fields)

        def descriptors(pid):
            samples.append(len(replies))
            if eof_oracle and len(samples) >= 2:
                self.assertTrue(all(reply.released for _, reply in replies),
                                "caller has not reached EOF at first idle sample")
                self.assertTrue(all(reply.report_released for _, reply in replies),
                                "caller report remains open after EOF at idle sample")
            return 11 if leaked_descriptor and len(samples) == 3 else 10

        def census(deadline, routes):
            if not eof_oracle:
                return
            expected = [{"observe_command": "observe", "inspect_session": "inspect"}.get(kind, kind)
                        for kind, _ in replies]
            self.assertEqual(routes, expected)
            for _, reply in replies:
                reply.report_released = True

        with contextlib.ExitStack() as stack:
            for owner, name, value in (
                    (transport, "HeldEndpoint", lambda **kwargs: endpoint),
                    (transport.threading, "Thread", lambda **kwargs: thread),
                    (transport.time, "sleep", lambda _: None),
                    (transport.subprocess, "check_output", lambda *a, **k: "0"),
                    (transport, "open_descriptors", descriptors),
                    (transport, "closed_host_request", request),
                    (transport, "HostDiagnostics", lambda _: SimpleNamespace(
                        observations=SimpleNamespace(plan="transport"), borrower_census=census)),
                    (transport.dispatch, "start_host", start),
                    (transport.dispatch, "configure", lambda *a: "abc123"),
                    (transport.dispatch, "message", message),
                    (transport.dispatch, "observe", observe),
                    (transport.dispatch, "wait_for", lambda predicate, *a, **k: predicate()),
                    (transport.dispatch, "read_result", read),
                    (transport.dispatch, "command", lambda *a, **k:
                     {"execution": {"custody_occupied": "1"}}),
                    (transport, "wait_for_drain", transport.wait_for_drain if eof_oracle else drain),
                    (transport.dispatch, "stop_host", lambda _: calls.append("stop"))):
                stack.enter_context(patch.object(owner, name, side_effect=value))
            output = stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
            expected = primary if fail_body or fail_start else secondary
            if leaked_descriptor:
                with self.assertRaisesRegex(AssertionError, r"\[10, 11\]"):
                    getattr(transport, caller)(pathlib.Path("/fixture"))
                self.assertEqual(len(samples), 3)
            elif eof_oracle and omitted_eof is None:
                getattr(transport, caller)(pathlib.Path("/fixture"))
                self.assertEqual(len(samples), 3)
                self.assertEqual({kind for kind, _ in replies},
                                 {"configure", "message", "observe_command", "read_result", "inspect_session"})
            elif eof_oracle:
                with self.assertRaisesRegex(AssertionError, "caller has not reached EOF at first idle sample"):
                    getattr(transport, caller)(pathlib.Path("/fixture"))
                self.assertEqual(len(samples), 2, "counterexample must fail at the first idle sample")
            else:
                with self.assertRaises(type(expected)) as raised:
                    getattr(transport, caller)(pathlib.Path("/fixture"))
                self.assertIs(raised.exception, expected)
        order = ["release", "stop"]
        if fail_start:
            order.remove("stop")
        expected_disposals = [*order, "shutdown", "close", ("join", 5)]
        self.assertEqual(calls[-len(expected_disposals):], expected_disposals)
        if not fail_body and not fail_start:
            self.assertEqual(len(endpoint.requests), 8 if omitted_eof else 16)
            if not omitted_eof and not leaked_descriptor:
                self.assertEqual(json.loads(output.getvalue())["requests"], 16)


class ObservationDeadlineTests(unittest.TestCase):
    def test_caller_populations_and_final_release_keep_original_budget(self):
        class Released(Exception):
            pass

        cases = (("round_trip", 45, 2), ("held_population", 40, 8),
                 ("held_streams", 45, 100),
                 ("write_failure_isolated", 20, 20), ("isolated_bad_header", 20, 2),
                 ("connection_failure", 20, 2), ("isolated_terminal_stream", 20, 2))
        for name, budget, population in cases:
            phases = ("release",) if name in ("isolated_bad_header", "connection_failure") else ("read", "release")
            for late in (None, *phases):
                for boundary in (0, 0.1) if late else (0,):
                    with self.subTest(caller=name, late=late, boundary=boundary), tempfile.TemporaryDirectory() as temporary:
                        clock = [100.0]  # Readiness/setup are outside the result budget.
                        observations = [0]
                        start = 100.0
                        clean = {"custody_occupied": "0", "scratch_used_bytes": "0", "dispatch_fenced": False}
                        endpoint = SimpleNamespace(server_address=("localhost", 1), observed_shape=False,
                            ready=SimpleNamespace(wait=lambda timeout: True), connections=["connection"],
                            streams=[("connection", 1, "isolation-target", b""), ("connection", 3, "isolation-sibling", b"")],
                            resets=[1], stream_ids={"isolation-target": 1, "held-0": 1}, answers={},
                            held=SimpleNamespace(wait=lambda timeout: True),
                            held_prefix_bytes=0, held_prefixes={"held-0": 0},
                            release=SimpleNamespace(set=lambda: None, is_set=lambda: False))
                        if name == "round_trip":
                            endpoint.answers = {f"h2-2-0-{i}": b"answer" for i in range(2)}
                        elif name in ("held_streams", "write_failure_isolated"):
                            prefix = {"held_streams": "held", "write_failure_isolated": "isolated"}[name]
                            endpoint.streams = [None] * population
                            endpoint.answers = {f"{prefix}-{i}": b"answer" for i in range(population)}
                            endpoint.answers["isolated-after"] = b"answer"
                        endpoint.server_port = 1
                        endpoint.first_ready = endpoint.ready
                        endpoint.release_first = SimpleNamespace(set=lambda: None)
                        endpoint.lock = contextlib.nullcontext()
                        endpoint.requests = [(f"held-0-{i}", b"") for i in range(population)]
                        endpoint.active, endpoint.h2_connections = 1, 1
                        endpoint.serve_forever = endpoint.shutdown = endpoint.server_close = lambda: None

                        def observe(store, key, *, deadline=None):
                            if deadline is None:
                                return {"processing": {"turn": "1", "operation": "1", "attempt": "1"}}
                            observations[0] += 1
                            if observations[0] == 1:
                                clock[0] += budget * 0.6
                            status, code = "completed", None
                            if name == "held_streams" and observations[0] == 1:
                                status = "cancelled"
                            if name == "write_failure_isolated" and observations[0] == 1:
                                status, code = "failed", "response_write_failed"
                            if name == "isolated_bad_header":
                                status, code = "failed", ("invalid_provider_headers" if observations[0] == 1 else "provider_http_422")
                            if name == "connection_failure":
                                status, code = "failed", "provider_http_422"
                            if name == "isolated_terminal_stream" and observations[0] == 1:
                                status, code = "failed", "response_scratch_exhausted"
                            assert clock[0] < deadline, "observation exceeded original deadline"
                            return {"result": {"status": status, "code": code}}

                        def read(store, key, *, deadline):
                            if late == "read" and observations[0] == population:
                                clock[0] = start + budget + boundary
                            assert clock[0] < deadline, "read exceeded original deadline"
                            if name == "held_population":
                                return f"answer-held-0-{key.rsplit('-', 1)[1]}".encode()
                            return b"unaffected sibling" if name == "isolated_terminal_stream" else b"answer"

                        def command(resource, operation, *args, **kwargs):
                            if (resource, operation) == ("session", "inspect"):
                                if "timeout" not in kwargs:
                                    return {"execution": {**clean, "custody_occupied": str(population) if name == "held_streams" else "1"}}
                                if late == "release":
                                    clock[0] = start + budget + boundary
                                return {"execution": clean}
                            return {"answer": {"status": "accepted", "session": "abc123"}}

                        def request(socket_path, store, kind, **fields):
                            if kind == "observe_command":
                                return {"observation": observe(store, fields["key"], deadline=fields.get("deadline"))}
                            if kind == "read_result":
                                return read(store, fields["key"], deadline=fields["deadline"])
                            if kind == "inspect_session" and "timeout" not in fields:
                                return command("session", "inspect")
                            operation = {"configure": ("session", "configure"), "message": ("session", "send"),
                                         "inspect_session": ("session", "inspect")}[kind]
                            return command(*operation, timeout=fields.get("timeout"))

                        real_drain = transport.wait_for_drain

                        def drain(inspect, deadline):
                            real_drain(inspect, deadline)
                            raise Released()  # Stop before unrelated native Store/FD audits.

                        diagnostics = SimpleNamespace(observations=SimpleNamespace(plan="transport"),
                            wait=lambda *args, **kwargs: [{}],
                            matching=lambda *args: [{}], records=[], dispose_interrupt=lambda *args, **kwargs: None)
                        if name == "connection_failure":
                            endpoint.streams = [("connection", i, f"drop-{i % 2}", b"") for i in range(4)]
                        with contextlib.ExitStack() as stack:
                            for owner, attribute, value in (
                                (transport.time, "monotonic", lambda: clock[0]), (transport.time, "sleep", lambda _: None),
                                (transport.dispatch, "start_host", lambda *a, **k:
                                 SimpleNamespace(pid=1, rui_ready_fields={"socket": "socket"})),
                                (transport.dispatch, "start_ready_process", lambda *a, **k: (SimpleNamespace(pid=1), {"socket": "socket"})),
                                (transport.dispatch, "stop_host", lambda *a: None),
                                (transport.dispatch, "configure", lambda *a: "abc123"), (transport.dispatch, "message", lambda *a: None),
                                (transport.dispatch, "observe", observe), (transport.dispatch, "read_result", read),
                                (transport.dispatch, "command", command), (transport, "closed_host_request", request),
                                (transport, "wait_for_drain", drain), (transport, "HostDiagnostics", lambda *a: diagnostics),
                                (transport, "HeldEndpoint", lambda: endpoint), (transport, "open_descriptors", lambda *a: 10),
                                (transport.subprocess, "check_output", lambda *a, **k: "0")):
                                stack.enter_context(patch.object(owner, attribute, side_effect=value))
                            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                            mocked_thread = stack.enter_context(patch.object(transport.threading, "Thread"))
                            mocked_thread.return_value.is_alive.return_value = False
                            with self.assertRaisesRegex(AssertionError, "original deadline") if late else self.assertRaises(Released):
                                root = pathlib.Path(temporary)
                                if name == "round_trip":
                                    transport.round_trip(root, endpoint, 2, root / "ca", rounds=1)
                                elif name == "held_population":
                                    transport.held_population(root)
                                elif name == "isolated_terminal_stream":
                                    transport.isolated_terminal_stream(root, endpoint, "capture")
                                else:
                                    getattr(transport, name)(root, endpoint)

    def test_shared_terminal_result_read_and_release_use_one_deadline(self):
        clean = {"custody_occupied": "0", "scratch_used_bytes": "0", "dispatch_fenced": False}
        for status, durations, accepted in (
                ("failed", (0.1, 0, 0.1), True),
                ("cancelled", (0.1, 0, 0.1), True),
                ("completed", (0.4, 0.3, 0.2), True),
                ("completed", (1, 0, 0), False),
                ("completed", (0.4, 0.6, 0), False),
                ("completed", (0.4, 0.3, 0.3), False)):
            with self.subTest(status=status, durations=durations):
                clock = [0.0]
                observation = {"result": {"status": status}}

                def command(resource, operation, *args, timeout, **kwargs):
                    observing = (resource, operation) == ("request", "inspect")
                    clock[0] += durations[0] if observing else durations[2]
                    return {"observation": observation} if observing else {"execution": clean}

                def read(*args, timeout, **kwargs):
                    self.assertEqual(status, "completed", "terminal failure must not request answer bytes")
                    clock[0] += durations[1]
                    return SimpleNamespace(returncode=0, stdout=b"exact answer", stderr=b"")

                with patch.object(transport.dispatch.time, "monotonic", side_effect=lambda: clock[0]), \
                        patch.object(transport.dispatch, "command", side_effect=command), \
                        patch.object(transport.dispatch.subprocess, "run", side_effect=read):
                    if accepted:
                        result = transport.dispatch.wait_for_result_release(pathlib.Path("/fixture"), "key", "abc123", 1)
                        self.assertEqual(result, (observation, b"exact answer" if status == "completed" else None, clean))
                        self.assertAlmostEqual(clock[0], sum(durations))
                    else:
                        with self.assertRaises(AssertionError):
                            transport.dispatch.wait_for_result_release(pathlib.Path("/fixture"), "key", "abc123", 1)

    def test_native_final_population_cannot_arrive_after_original_deadline(self):
        # Host diagnostics uses this same wait after result/read/release. A
        # complete population is not a replacement for timely observation.
        for arrival in (0.9, 1.0, 1.2):
            with self.subTest(arrival=arrival):
                clock = [0.7]

                def population():
                    clock[0] = arrival
                    return [{"phase": "inspection_captured"}, {"phase": "cleanup_completed"}]

                with patch.object(transport.dispatch.time, "monotonic", side_effect=lambda: clock[0]):
                    if arrival < 1:
                        self.assertEqual(len(transport.dispatch.wait_for(population, "native final population", deadline=1)), 2)
                    else:
                        with self.assertRaisesRegex(AssertionError, "native final population"):
                            transport.dispatch.wait_for(population, "native final population", deadline=1)

    def test_result_exchanges_keep_caps_and_reject_late_or_exhausted_evidence(self):
        for kind in ("observe", "read_result"):
            for remaining, elapsed in ((None, 0.1), (0, 0), (0.25, 0.1), (0.25, 0.25), (0.25, 1), (20, 0.1), (20, 16)):
                with self.subTest(kind=kind, remaining=remaining, elapsed=elapsed):
                    clock = [10.0]
                    budgets = []

                    def exchange(*args, timeout, **kwargs):
                        budgets.append(timeout)
                        clock[0] += elapsed
                        return ({"observation": {"result": {"status": "completed"}}} if kind == "observe"
                                else SimpleNamespace(returncode=0, stdout=b"exact answer", stderr=b""))

                    with patch.object(transport.time, "monotonic", side_effect=lambda: clock[0]), \
                            patch.object(transport.dispatch, "command", side_effect=exchange), \
                            patch.object(transport.dispatch.subprocess, "run", side_effect=exchange):
                        operation = getattr(transport.dispatch, kind)
                        if remaining is not None and min(15, remaining) <= elapsed:
                            with self.assertRaisesRegex(AssertionError, "original deadline"):
                                operation(pathlib.Path("/fixture"), "key", deadline=10 + remaining)
                        else:
                            result = operation(pathlib.Path("/fixture"), "key", deadline=None if remaining is None else 10 + remaining)
                            self.assertEqual(result, {"result": {"status": "completed"}} if kind == "observe" else b"exact answer")
                    self.assertEqual(budgets, [] if remaining == 0 else [15 if remaining is None else min(15, remaining)])

    def test_fragmented_result_and_eof_share_one_exchange_budget(self):
        class TimedReply(HostReply):
            def __init__(self, clock, arrivals):
                super().__init__(content_type=b"text/plain")
                self.clock, self.arrivals = clock, iter(arrivals)
                self.chunks = iter((b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 6\r\n\r\n", b"answer", b""))
                self.request = None

            def settimeout(self, timeout):
                self.timeout = timeout

            def sendall(self, data):
                self.request = data

            def recv(self, size):
                arrival = next(self.arrivals)
                if arrival - self.clock[0] >= self.timeout:
                    raise TimeoutError("remaining socket credit exhausted")
                self.clock[0] = arrival
                chunk = next(self.chunks)
                self.released = not chunk
                return chunk

        for deadline, arrivals, timely in ((1, (0.2, 0.7, 0.9), True), (1, (0.2, 1, 1.1), False),
                                           (1, (0.2, 0.7, 1), False), (45, (8, 16, 16.1), False)):
            with self.subTest(deadline=deadline, arrivals=arrivals):
                clock = [0.0]
                reply = TimedReply(clock, arrivals)
                with patch.object(transport.time, "monotonic", side_effect=lambda: clock[0]), \
                        patch.object(transport.socket, "socket", return_value=reply):
                    if timely:
                        self.assertEqual(transport.closed_host_request("/fixture/socket", pathlib.Path("/fixture"),
                                                                       "read_result", deadline=deadline), b"answer")
                        self.assertTrue(reply.released)
                        self.assertNotIn(b'"deadline"', reply.request)
                    else:
                        with self.assertRaises((TimeoutError, AssertionError)):
                            transport.closed_host_request("/fixture/socket", pathlib.Path("/fixture"),
                                                          "read_result", deadline=deadline)

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
    host_process.enter()
    unittest.main(argv=[sys.argv[0]])
