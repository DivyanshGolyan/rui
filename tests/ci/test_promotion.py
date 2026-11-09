"""Record a job's failed steps and bisect each one in a real repository."""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import unittest

import promotion
import steps

PROMOTION = Path(__file__).with_name("promotion.py")
STEPS = Path(__file__).with_name("steps.py")


class BatchRepository:
    """Seven first-parent commits after `stable`, plus a merged side branch.

    `broken` maps a file to the commit index where its content turns bad; a
    step `grep -qx good FILE` fails from then on.
    """

    FILES = ("state", "other")

    def __init__(self, broken=None, base_bad=False, size=7):
        broken = broken or {}
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        for name in self.FILES:
            (self.repo / name).write_text("bad\n" if base_bad else "good\n")
        self.base = self.commit("stable")
        self.commits = []
        for index in range(size):
            for name, at in broken.items():
                if index == at:
                    (self.repo / name).write_text("bad\n")
            (self.repo / f"file{index}").write_text(f"{index}\n")
            self.commits.append(self.commit(f"change {index}"))
        # A side branch merged in: its commits are not bisected on their own.
        self.git("checkout", "-q", "-b", "side", self.commits[2])
        (self.repo / "side").write_text("side\n")
        self.side = self.commit("side change")
        self.git("checkout", "-q", "main")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "merge", "-q", "--no-ff", "-m", "merge side", self.side)
        self.commits.append(self.git("rev-parse", "HEAD"))
        self.env = dict(os.environ, RUNNER_TEMP=str(self.root / "runner"))
        self.env.pop("GITHUB_STEP_SUMMARY", None)
        (self.root / "runner").mkdir()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True, stderr=subprocess.PIPE).strip()

    def commit(self, message):
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def steps(self, *arguments):
        """Run steps.py at HEAD, as a job does; returns its exit code."""
        return subprocess.run([sys.executable, "-B", str(STEPS), *arguments], cwd=self.repo, env=self.env,
                              capture_output=True, text=True).returncode

    def check(self):
        """The job's checks: one step per file, each failing once its file turns bad."""
        return self.steps(*(f"{name}=grep -qx good {name}" for name in self.FILES))

    def bisect(self):
        logs = self.root / "logs"
        result = subprocess.run([sys.executable, "-B", str(PROMOTION), "--base", self.base, "--head", self.commits[-1],
                                 "--logs", str(logs)], cwd=self.repo, env=self.env, capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
        verdict = logs / "verdict.json"
        return (json.loads(verdict.read_text()) if verdict.exists() else None), result.stdout

    def close(self):
        self.scratch.cleanup()


class PromotionBisectTest(unittest.TestCase):
    def batch(self, **kwargs):
        repository = BatchRepository(**kwargs)
        self.addCleanup(repository.close)
        return repository

    def test_names_the_first_failing_commit_at_every_position(self):
        for broken in range(7):
            with self.subTest(broken=broken):
                repository = self.batch(broken=dict(state=broken))
                self.assertEqual(repository.check(), 1)
                verdict, stdout = repository.bisect()
                [step] = verdict["steps"]
                self.assertEqual((step["step"], step["verdict"], step["culprit"]),
                                 ("state", "culprit", repository.commits[broken]))
                self.assertIn(f"Promotion bisect: state: first fails at {repository.commits[broken]} (change {broken})",
                              stdout)
                # HEAD, then a binary search over eight commits, then stable only for the first.
                self.assertLessEqual(len(step["replays"]), 1 + 3 + (broken == 0))
                self.assertEqual(step["replays"][0], dict(sha=repository.commits[-1], passed=False))
                # The tree returns to HEAD, and the side branch is never replayed on its own.
                self.assertEqual(repository.git("rev-parse", "HEAD"), repository.commits[-1])
                self.assertNotIn(repository.side, [replay["sha"] for replay in step["replays"]])

    def test_each_failed_step_gets_its_own_culprit(self):
        # Two regressions in one job from different commits: each step names its own.
        repository = self.batch(broken=dict(state=1, other=5))
        self.assertEqual(repository.check(), 1)
        verdict, stdout = repository.bisect()
        self.assertEqual({step["step"]: step["culprit"] for step in verdict["steps"]},
                         dict(state=repository.commits[1], other=repository.commits[5]))
        self.assertIn(f"Promotion bisect: state: first fails at {repository.commits[1]}", stdout)
        self.assertIn(f"Promotion bisect: other: first fails at {repository.commits[5]}", stdout)

    def test_only_failed_steps_are_recorded_and_replayed(self):
        repository = self.batch(broken=dict(other=3))
        self.assertEqual(repository.check(), 1)
        recorded = steps.failures(Path(repository.env["RUNNER_TEMP"]) / "rui-failed-steps.jsonl")
        # The command is recorded unexpanded, exactly as the job listed it.
        self.assertEqual(recorded, [dict(name="other", argv=["bash", "-euc", "grep -qx good other"])])
        verdict, _ = repository.bisect()
        self.assertEqual([step["step"] for step in verdict["steps"]], ["other"])

    def test_a_job_that_failed_before_any_recorded_step_has_nothing_to_replay(self):
        repository = self.batch(broken=dict(state=2))
        verdict, stdout = repository.bisect()
        self.assertIsNone(verdict)
        self.assertIn("nothing to replay", stdout)

    def test_a_red_that_passes_again_at_head_is_not_blamed_on_a_commit(self):
        # A red run's record, replayed after the red stopped reproducing.
        repository = self.batch()
        steps_file = Path(repository.env["RUNNER_TEMP"]) / "rui-failed-steps.jsonl"
        steps_file.write_text(json.dumps(dict(name="state", argv=["grep", "-qx", "good", "state"])) + "\n")
        verdict, stdout = repository.bisect()
        [step] = verdict["steps"]
        self.assertEqual(step["verdict"], "not-reproduced")
        self.assertEqual(len(step["replays"]), 1)
        self.assertIn("did not fail again", stdout)

    def test_a_red_already_present_at_stable_blames_no_batch_commit(self):
        repository = self.batch(base_bad=True)
        self.assertEqual(repository.check(), 1)
        verdict, stdout = repository.bisect()
        for step in verdict["steps"]:
            self.assertEqual(step["verdict"], "before-batch")
            self.assertNotIn("culprit", step)
            self.assertEqual(step["replays"][-1]["sha"], repository.base)
        self.assertIn("fails at", stdout)

    def test_every_run_of_a_step_gets_a_fresh_output(self):
        # Harnesses refuse an output directory that exists: the run and each replay get their own.
        repository = self.batch(broken=dict(state=4))
        output = 'out=test ! -e "$STEP_OUTPUT"; mkdir "$STEP_OUTPUT"; grep -qx good state'
        self.assertEqual(repository.steps("--output-root", str(repository.root / "results"), output), 1)
        self.assertTrue((repository.root / "results/out").is_dir())
        verdict, _ = repository.bisect()
        [step] = verdict["steps"]
        self.assertEqual(step["culprit"], repository.commits[4])

    def test_every_step_runs_after_a_failure_and_the_job_fails(self):
        repository = self.batch()
        marker = repository.root / "ran"
        self.assertEqual(repository.steps("first=false", f"second=touch {marker}"), 1)
        self.assertTrue(marker.exists())
        self.assertEqual(repository.steps("first=true", "second=true"), 0)
        self.assertEqual(repository.steps("same=true", "same=true"), 2)

    def test_search_order(self):
        # Pure: given HEAD fails, the search must find the boundary in log2 steps.
        commits = [f"c{i}" for i in range(22)]
        for broken in (0, 1, 10, 21):
            replays = []

            def passes(sha):
                replays.append(sha)
                return sha == "base" or int(sha[1:]) < broken
            result = promotion.bisect(commits, "base", passes)
            self.assertEqual(result["culprit"], f"c{broken}")
            self.assertLessEqual(len(replays), 1 + 5 + (broken == 0))


if __name__ == "__main__":
    unittest.main()
