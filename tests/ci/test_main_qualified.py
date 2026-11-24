from datetime import datetime, timezone
import subprocess
import unittest

import main_qualified as mq

NOW = datetime(2026, 11, 18, 12, tzinfo=timezone.utc)
A, B, C, D = (letter * 40 for letter in "abcd")
QUALIFIER = ".github/workflows/main-qualifier.yml"
ARTIFACTS = ("rui-linux-x86_64", "rui-linux-arm64", "rui-darwin-arm64", "rui-npm", "rui-digests", "rui-host-memory")


def status(state, description, run="41", context="main-qualified", creator="github-actions[bot]"):
    return {"context": context, "state": state, "creator": {"login": creator},
            "target_url": f"https://github.com/o/r/actions/runs/{run}", "description": description}


GREEN = status("success", "Qualified with release 0.80.0")
RED = status("failure", "Full tier failed; see the run")


def artifacts(expires="2026-11-20T12:00:00Z", drop=(), expired=()):
    return [{"name": name, "expired": name in expired, "expires_at": expires} for name in ARTIFACTS if name not in drop]


class RecordTest(unittest.TestCase):
    """CI-68: the main-qualified record reads its newest Actions status, and its verdict and description."""

    def test_whole_domain(self):
        # The record each commit's statuses hold, newest status first.
        records = {
            "green": ([GREEN], mq.Record("success", "41", "0.80.0")),
            "green without a release": ([status("success", "Qualified; no new release")], mq.Record("success", "41", "")),
            "red": ([RED], mq.Record("failure", "41", "")),
            "newest wins": ([status("pending", "Qualifying", run="42"), GREEN], mq.Record("pending", "42", "")),
            "other context": ([status("success", "Qualified with release 0.80.0", context="admission")], None),
            "other creator": ([status("success", "Qualified with release 0.80.0", creator="someone")], None),
            "none": ([], None),
        }
        for case, (statuses, expected) in records.items():
            with self.subTest(record=case):
                self.assertEqual(mq.parse(statuses), expected)

        verdicts = {
            ("success", "success", "success", "success"): "success",
            ("success", "failure", "skipped", "success"): "failure",
            ("failure", "cancelled", "skipped", "skipped"): "failure",
            ("success", "cancelled", "success", "success"): "error",
            ("success", "skipped", "skipped", "skipped"): "error",
            (): "error",
        }
        for results, expected in verdicts.items():
            with self.subTest(results=results):
                self.assertEqual(mq.verdict(list(results)), expected)

        descriptions = {("success", "0.80.0"): "Qualified with release 0.80.0", ("success", ""): "Qualified; no new release",
                        ("failure", "0.80.0"): "Full tier failed; see the run",
                        ("error", ""): "Not finished; the next run qualifies again", ("pending", ""): "Qualifying"}
        for (state, version), expected in descriptions.items():
            with self.subTest(describe=state):
                self.assertEqual(mq.describe(state, version), expected)


class PromotionChoiceTest(unittest.TestCase):
    """CI-13: Promote publishes a green record's archives of the same SHA, qualifies only main HEAD, refuses red."""

    def test_whole_domain(self):
        green = mq.Record("success", "41", "0.80.0")
        run = {"head_sha": A, "path": QUALIFIER}
        # (record, run, artifacts, planned version) -> reason, or None when publishable
        reusable = {
            "live green qualification": (green, run, artifacts(), "0.80.0", None),
            "green Promote run": (green, {"head_sha": A, "path": ".github/workflows/promote.yml@refs/heads/main"},
                                  artifacts(), "0.80.0", None),
            "no release needs no archives": (mq.Record("success", "41", ""), run, [], "", None),
            "red": (mq.Record("failure", "41", ""), run, artifacts(), "0.80.0", "no green record"),
            "unfinished": (mq.Record("error", "41", ""), run, artifacts(), "0.80.0", "no green record"),
            "pending": (mq.Record("pending", "41", ""), run, artifacts(), "0.80.0", "no green record"),
            "absent": (None, run, artifacts(), "0.80.0", "no green record"),
            "run gone": (green, None, [], "0.80.0", f"run 41 is not a qualification of {A}"),
            "run of another commit": (green, {"head_sha": B, "path": QUALIFIER}, artifacts(), "0.80.0",
                                      f"run 41 is not a qualification of {A}"),
            "run of another workflow": (green, {"head_sha": A, "path": ".github/workflows/check.yml"}, artifacts(),
                                        "0.80.0", f"run 41 is not a qualification of {A}"),
            "plan moved on": (green, run, artifacts(), "0.80.1", "the release plan is now 0.80.1, not 0.80.0"),
            "already released": (green, run, artifacts(), "", "the release plan is now none, not 0.80.0"),
            "an archive missing": (green, run, artifacts(drop=("rui-linux-arm64",)), "0.80.0",
                                   "run 41 no longer holds rui-linux-arm64"),
            "digests expired": (green, run, artifacts(expired=("rui-digests",)), "0.80.0",
                                "run 41 no longer holds rui-digests"),
            "inside the margin": (green, run, artifacts(expires="2026-11-18T13:30:00Z"), "0.80.0",
                                  "run 41 no longer holds rui-darwin-arm64, rui-digests, rui-host-memory, "
                                  "rui-linux-arm64, rui-linux-x86_64, rui-npm"),
            "memory table expired": (green, run, artifacts(expired=("rui-host-memory",)), "0.80.0",
                                     "run 41 no longer holds rui-host-memory"),
            "just past the margin": (green, run, artifacts(expires="2026-11-18T14:01:00Z"), "0.80.0", None),
        }
        for case, (record, found, held, planned, expected) in reusable.items():
            with self.subTest(reusable=case):
                self.assertEqual(mq.reusable(record, found, held, planned, A, NOW), expected)

        # The run lookup: a run GitHub no longer has is no evidence, so Promote qualifies HEAD instead.
        def found(path):
            self.assertEqual(path, "repos/o/r/actions/runs/41")
            return {"head_sha": A, "path": QUALIFIER}

        def failing(stderr):
            def request(path):
                raise subprocess.CalledProcessError(1, ["gh", "api", path], stderr=stderr)
            return request
        with self.subTest(run_of="found"):
            self.assertEqual(mq.run_of("o/r", "41", found), {"head_sha": A, "path": QUALIFIER})
        with self.subTest(run_of="deleted"):
            self.assertIsNone(mq.run_of("o/r", "41", failing("gh: Not Found (HTTP 404)")))
            self.assertEqual(mq.reusable(green, None, [], "0.80.0", A, NOW), f"run 41 is not a qualification of {A}")
        for case, stderr in (("server error", "gh: Server Error (HTTP 502)"), ("no network", "connection reset")):
            with self.subTest(run_of=case), self.assertRaises(subprocess.CalledProcessError):
                mq.run_of("o/r", "41", failing(stderr))

        # Main HEAD is A; commits after stable are A, B, C. (sha input, records, publishable reason)
        # -> (chosen, reused, reason) or the refusal's text.
        published = mq.Record("success", "41", "0.80.0")
        choices = {
            "green HEAD publishes": ("", {A: "success"}, None, (A, published, None)),
            "green HEAD by name": (A, {A: "success"}, None, (A, published, None)),
            "HEAD without a record qualifies": ("", {}, None, (A, None, "no green record")),
            "pending HEAD qualifies": ("", {A: "pending"}, None, (A, None, "no green record")),
            "unfinished HEAD qualifies": ("", {A: "error"}, None, (A, None, "no green record")),
            "stale green HEAD qualifies": ("", {A: "success"}, "expired", (A, None, "expired")),
            "newest green": ("qualified", {A: "failure", B: "success", C: "success"}, None, (B, published, None)),
            "named earlier green": (B, {B: "success"}, None, (B, published, None)),
            "no green commit": ("qualified", {A: "failure"}, None, "no main commit after stable has a green"),
            "earlier commit without a record": (B, {}, None, "Promote qualifies only main HEAD"),
            "earlier commit stale": (B, {B: "success"}, "expired", "cannot be published as qualified (expired)"),
            "red HEAD": ("", {A: "failure"}, None, f"{A} failed qualification in run 41"),
            "red earlier commit": (B, {B: "failure"}, None, f"{B} failed qualification in run 41"),
            "not on main after stable": (D, {}, None, "is not a first-parent main commit after stable"),
            "not a SHA": ("main", {}, None, "is not a first-parent main commit after stable"),
        }
        for case, (sha, states, reason, expected) in choices.items():
            with self.subTest(choose=case):
                def record(commit):
                    return mq.Record(states[commit], "41", "0.80.0") if commit in states else None
                if isinstance(expected, str):
                    with self.assertRaisesRegex(SystemExit, expected.replace("(", r"\(").replace(")", r"\)")):
                        mq.choose(A, sha, [A, B, C], record, lambda own, commit: reason)
                else:
                    self.assertEqual(mq.choose(A, sha, [A, B, C], record, lambda own, commit: reason), expected)
        with self.subTest(choose="stable holds HEAD"):
            self.assertEqual(mq.choose(A, "", [], lambda commit: None, lambda own, commit: None),
                             (A, None, "stable already holds it"))
        # A scheduled run never refuses: a red HEAD promotes nothing, and an unrecorded or green HEAD proceeds.
        scheduled = {
            "red HEAD skips": ({A: "failure"}, None, (None, mq.Record("failure", "41", "0.80.0"),
                                                       f"{A} failed qualification in run 41; "
                                                       "the next scheduled run waits for a fix on main")),
            "green HEAD publishes": ({A: "success"}, None, (A, published, None)),
            "HEAD without a record qualifies": ({}, None, (A, None, "no green record")),
        }
        for case, (states, reason, expected) in scheduled.items():
            with self.subTest(scheduled=case):
                def record(commit):
                    return mq.Record(states[commit], "41", "0.80.0") if commit in states else None
                self.assertEqual(mq.choose(A, "", [A, B, C], record, lambda own, commit: reason, scheduled=True),
                                 expected)

        # CI-13: a scheduled red HEAD publishes nothing and its outputs name the red record's run (red_run), so
        # Promote's batch fails; a red record with no run cannot be named, so choose refuses it.
        red = mq.Record("failure", "41", "0.80.0")
        skip_outputs = {"head": "", "base": "S", "size": "0", "reuse": "false", "run": "", "version": "",
                        "red_run": "41"}
        with self.subTest(skipped="red record names its run"):
            self.assertEqual(mq.skipped("S", red), skip_outputs)
        with self.subTest(skipped="red record without a run"):
            with self.assertRaisesRegex(SystemExit, "names no run"):
                mq.choose(A, "", [A], lambda commit: mq.Record("failure", None, ""), lambda own, commit: None,
                          scheduled=True)
        # A head that is not red emits no red_run: the outputs below carry none, and so does an up-to-date head.
        with self.subTest(outputs="up to date"):
            self.assertEqual(mq.promoted("S", A, 0, None),
                             {"head": A, "base": "S", "size": "0", "reuse": "false", "run": "", "version": ""})
        with self.subTest(outputs="green archives reused"):
            self.assertEqual(mq.promoted("S", B, 2, mq.Record("success", "41", "0.80.0")),
                             {"head": B, "base": "S", "size": "2", "reuse": "true", "run": "41", "version": "0.80.0"})
        with self.subTest(outputs="qualified here"):
            self.assertEqual(mq.promoted("S", B, 2, None),
                             {"head": B, "base": "S", "size": "2", "reuse": "false", "run": "", "version": ""})
        with self.subTest(manual="red HEAD refuses"):
            with self.assertRaisesRegex(SystemExit, "fix forward"):
                mq.choose(A, "", [A], lambda commit: mq.Record("failure", "41", ""), lambda own, commit: None)


if __name__ == "__main__":
    unittest.main()
