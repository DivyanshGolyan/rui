"""Fault the actual async fixture finalizer without starting any resources."""
import ast
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/integration"))
try:
    import host_process
finally:
    sys.path.pop(0)

SOURCE = ROOT / "tests/integration/async_actions_integration.py"


def finalizer(dispose_all=host_process.dispose_all):
    tree = ast.parse(SOURCE.read_text())
    owner, = [node for node in tree.body
              if isinstance(node, ast.FunctionDef) and node.name == "_dispose_case"]
    namespace = {
        "host_process": SimpleNamespace(dispose_all=dispose_all,
                                         cleanup_failure=host_process.cleanup_failure),
        "bash_fixture": SimpleNamespace(), "sys": sys, "json": __import__("json"),
    }
    exec(compile(ast.Module(body=[owner], type_ignores=[]), str(SOURCE), "exec"), namespace)
    return namespace["_dispose_case"], namespace["bash_fixture"]


def exercise(failures=(), *, body_failed=True, model_gate=True, dispose_all=host_process.dispose_all,
             malformed_requests=False):
    dispose, peer = finalizer(dispose_all)
    calls = []
    errors = {name: RuntimeError(name + " failed") for name in failures}
    primary = AssertionError("original body") if body_failed else None

    def called(name):
        calls.append(name)
        if name in errors:
            raise errors[name]

    class Artifact:
        def __init__(self, name):
            self.name = name

        def write_text(self, value):
            called(self.name)

    class State:
        def __truediv__(self, name):
            return Artifact(name)

    peer.dispose_owner_case = lambda host, endpoint, thread: called("retire")
    release = SimpleNamespace(touch=lambda: called("producer"))
    final_reply = SimpleNamespace(set=lambda: called("model")) if model_gate else None
    endpoint = SimpleNamespace(requests=["invalid JSON" if malformed_requests else '{"fixture":true}'])
    caught = None
    try:
        try:
            if primary is not None:
                raise primary
        finally:
            dispose(State(), object(), endpoint, object(), release, final_reply)
    except BaseException as error:
        caught = error
    return calls, primary, errors, caught


class AsyncActionsCleanupTest(unittest.TestCase):
    def test_all_four_cases_finalize_through_the_one_owner(self):
        cases = {"prove_promotion": 6, "prove_waiting_permission": 6,
                 "prove_capacity_one": 5, "prove_model_controls": 5}
        tree = ast.parse(SOURCE.read_text())
        for name, arguments in cases.items():
            with self.subTest(case=name):
                function, = [node for node in tree.body
                             if isinstance(node, ast.FunctionDef) and node.name == name]
                guarded, = [node for node in function.body if isinstance(node, ast.Try)]
                self.assertEqual(guarded.handlers, [])
                self.assertEqual(guarded.orelse, [])
                cleanup, = guarded.finalbody
                self.assertIsInstance(cleanup, ast.Expr)
                self.assertIsInstance(cleanup.value, ast.Call)
                self.assertEqual(cleanup.value.func.id, "_dispose_case")
                self.assertEqual(len(cleanup.value.args), arguments)

    def test_success_releases_every_owner_once_without_failure_artifacts(self):
        for model_gate in (False, True):
            with self.subTest(model_gate=model_gate):
                calls, _, _, caught = exercise(body_failed=False, model_gate=model_gate)
                self.assertIsNone(caught)
                self.assertEqual(calls, ["producer", *(["model"] if model_gate else []), "retire"])

    def test_each_artifact_failure_preserves_body_and_does_not_skip_any_disposal(self):
        for model_gate in (False, True):
            for failures in (("primary-failure.txt",), ("requests.json",),
                             ("primary-failure.txt", "requests.json")):
                with self.subTest(model_gate=model_gate, failures=failures):
                    calls, primary, _, caught = exercise(failures, model_gate=model_gate)
                    self.assertIs(caught, primary)
                    self.assertEqual(calls, ["producer", *(["model"] if model_gate else []), "retire",
                                             "primary-failure.txt", "requests.json"])
                    self.assertEqual(len(primary.__notes__), len(failures))

    def assert_all_attempts_preserve_primary(self, dispose_all=host_process.dispose_all):
        calls, primary, _, caught = exercise(
            ("producer", "model", "retire", "primary-failure.txt", "requests.json"),
            dispose_all=dispose_all)
        self.assertIs(caught, primary)
        self.assertEqual(calls, ["producer", "model", "retire", "primary-failure.txt", "requests.json"])
        self.assertEqual(len(primary.__notes__), 5)
        self.assertTrue(all(len(note) < 1024 for note in primary.__notes__))

    def test_gate_disposal_and_artifact_failures_are_all_attempted(self):
        self.assert_all_attempts_preserve_primary()
        for failed in ("producer", "model", "retire"):
            with self.subTest(failed=failed):
                calls, primary, _, caught = exercise((failed,))
                self.assertIs(caught, primary)
                self.assertEqual(calls, ["producer", "model", "retire", "primary-failure.txt", "requests.json"])
                self.assertEqual(len(primary.__notes__), 1)

    def test_cleanup_failure_after_success_stays_primary_even_when_both_writers_fail(self):
        for failed in ("producer", "model", "retire"):
            with self.subTest(failed=failed):
                calls, _, errors, caught = exercise(
                    (failed, "primary-failure.txt", "requests.json"), body_failed=False)
                self.assertIs(caught, errors[failed])
                self.assertEqual(calls, ["producer", "model", "retire", "primary-failure.txt", "requests.json"])
                self.assertEqual(len(caught.__notes__), 3)

    def test_malformed_request_evidence_cannot_replace_body_or_skip_retirement(self):
        calls, primary, _, caught = exercise(("primary-failure.txt",), malformed_requests=True)
        self.assertIs(caught, primary)
        self.assertEqual(calls, ["producer", "model", "retire", "primary-failure.txt"])
        self.assertEqual(len(primary.__notes__), 2)
        self.assertIn("JSONDecodeError", primary.__notes__[1])

    def test_same_all_attempt_gate_rejects_a_sequential_cleanup_mutant(self):
        def sequential(*callbacks):
            for callback in callbacks:
                callback()

        self.assert_all_attempts_preserve_primary()
        with self.assertRaises(AssertionError):
            self.assert_all_attempts_preserve_primary(sequential)


if __name__ == "__main__":
    unittest.main()
