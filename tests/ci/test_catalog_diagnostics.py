"""Catalog fixture oracles separate optional stderr from canonical outcomes."""
import contextlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "integration"))
# The fixture libraries bind their executable from argv even when only imported.
with patch.object(sys, "argv", ["codex_h2_integration.py", "unused-rui"]):
    import codex_h2_integration as catalog


DIAGNOSTICS = {
    "proxy": b"rui: models.dev catalog unavailable (HttpsProxySchemeUnsupported); the saved catalog stands\n",
    "trust": b"rui: models.dev catalog unavailable (InvalidSslCertFile); the saved catalog stands\n",
}
REQUIRED_FAILURE = "transport reactor initialization failure: HttpsProxySchemeUnsupported"


class CatalogDiagnosticsTest(unittest.TestCase):
    def run_fixture(self, case, *, early=b"", late=b"", providers=None, capacity=None,
                    exited=False, required_code=1, required_stderr=REQUIRED_FAILURE,
                    configured="accepted", completed="completed", answer=b"HTTP still works",
                    requests=1):
        hosts = []

        def start(args, **kwargs):
            log = Path(args[4])
            enabled = "--test-models-dev-url" in args
            log.write_bytes(early if enabled else b"")
            host = SimpleNamespace(log=log, enabled=enabled, returncode=None)
            host.poll = lambda: 1 if exited else host.returncode
            hosts.append(host)
            return host, {"socket": "fixture.sock"}

        def stop(host):
            if host.enabled:
                with host.log.open("ab") as output:
                    output.write(late)
            host.returncode = -9

        def request(socket, store, kind):
            if kind == "model_list":
                return {"providers": providers if providers is not None else
                        ([] if case == "proxy" else [{"provider": "codex"}])}
            return {"active_capacity": capacity if capacity is not None else store.name[-1]}

        endpoint = Mock(server_port=1234, requests=[{}] * requests)
        thread = Mock()
        thread.is_alive.return_value = False
        required = subprocess.CompletedProcess([], required_code, "", required_stderr)
        with tempfile.TemporaryDirectory() as directory, contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(catalog.tempfile, "mkdtemp", return_value=directory))
            stack.enter_context(patch.object(catalog, "start_ready_process", side_effect=start))
            stack.enter_context(patch.object(catalog.fixture, "stop_host", side_effect=stop))
            calls = stack.enter_context(patch.object(catalog.h2_fixture, "closed_host_request", side_effect=request))
            mandatory = stack.enter_context(patch.object(catalog.subprocess, "run", return_value=required))
            stack.enter_context(patch.object(catalog.fixture, "SuccessEndpoint", return_value=endpoint))
            stack.enter_context(patch.object(catalog.threading, "Thread", return_value=thread))
            stack.enter_context(patch.object(catalog.fixture, "command", return_value={
                "answer": {"status": configured, "session": "fixture"}}))
            message = stack.enter_context(patch.object(catalog.fixture, "message"))
            stack.enter_context(patch.object(catalog.fixture, "wait_for_result_release", return_value=(
                {"result": {"status": completed}}, answer, None)))
            stack.enter_context(patch.object(catalog.fixture, "wait_for", side_effect=AssertionError(
                "optional stderr must not be awaited")))
            stack.enter_context(patch.object(catalog, "retain_failure_state"))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            try:
                getattr(catalog, f"catalog_unusable_{case}_run")()
            finally:
                self.assertTrue(hosts)
                self.assertTrue(all(host.returncode == -9 for host in hosts), "Host writer not retired")
            self.assertEqual(len(hosts), 2)
            if case == "proxy":
                self.assertEqual(calls.call_count, 12)
                mandatory.assert_called_once()
            else:
                self.assertEqual(calls.call_count, 6)
                message.assert_called_once()
                endpoint.shutdown.assert_called_once()
                thread.join.assert_called_once()

    def test_absent_optional_diagnostics_do_not_gate_canonical_work(self):
        for case in DIAGNOSTICS:
            with self.subTest(case=case):
                self.run_fixture(case)

    def test_exact_single_diagnostic_is_allowed_before_or_at_retirement(self):
        for case, diagnostic in DIAGNOSTICS.items():
            for timing in ("early", "late"):
                with self.subTest(case=case, timing=timing):
                    self.run_fixture(case, **{timing: diagnostic})

    def test_malformed_and_duplicate_diagnostics_fail_after_retirement(self):
        for case, diagnostic in DIAGNOSTICS.items():
            for invalid in (diagnostic * 2, diagnostic[:-1], diagnostic.replace(b"stands", b"changed"),
                            b"unexpected stderr\n"):
                with self.subTest(case=case, invalid=invalid):
                    with self.assertRaises(AssertionError) as raised:
                        self.run_fixture(case, late=invalid)
                    self.assertEqual(raised.exception.args, (invalid,))

    def test_late_invalid_bytes_cannot_hide_behind_an_earlier_valid_diagnostic(self):
        for case, diagnostic in DIAGNOSTICS.items():
            with self.subTest(case=case):
                with self.assertRaises(AssertionError) as raised:
                    self.run_fixture(case, early=diagnostic, late=b"extra\n")
                self.assertEqual(raised.exception.args, (diagnostic + b"extra\n",))

    def test_broken_canonical_behavior_still_fails_with_silent_stderr(self):
        mutations = {
            "proxy": ({"providers": [{"provider": "unexpected"}]}, {"capacity": "99"}, {"exited": True}),
            "trust": ({"providers": []}, {"providers": [{"provider": "unexpected"}]},
                      {"configured": "rejected"}, {"completed": "failed"},
                      {"answer": b"wrong answer"}, {"requests": 0}, {"exited": True}),
        }
        for case, failures in mutations.items():
            for mutation in failures:
                with self.subTest(case=case, mutation=mutation), self.assertRaises(AssertionError):
                    self.run_fixture(case, **mutation)

    def test_required_provider_setup_failure_keeps_its_classification(self):
        mutations = ({"required_code": 0}, {"required_stderr": "wrong failure"},
                     {"required_stderr": REQUIRED_FAILURE + "\nmodels.dev catalog unavailable"})
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                with self.assertRaises(AssertionError) as raised:
                    self.run_fixture("proxy", **mutation)
                self.assertIsInstance(raised.exception.args[0], subprocess.CompletedProcess)


if __name__ == "__main__":
    unittest.main()
