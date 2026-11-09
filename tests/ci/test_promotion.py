"""Bisect a promotion batch in a real repository with the failing command."""
from pathlib import Path
import json
import subprocess
import sys
import tempfile
import unittest

import promotion

SCRIPT = Path(__file__).with_name("promotion.py")


class BatchRepository:
    """Seven first-parent commits after `stable`; `state` turns bad at `broken`."""

    def __init__(self, broken=None, base_bad=False, size=7):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.write("good\n" if not base_bad else "bad\n")
        self.base = self.commit("stable")
        self.commits = []
        for index in range(size):
            if broken is not None and index == broken:
                self.write("bad\n")
            (self.repo / f"file{index}").write_text(f"{index}\n")
            self.commits.append(self.commit(f"change {index}"))
        # A side branch merged in: its commits are not bisected on their own.
        self.git("checkout", "-q", "-b", "side", self.commits[2])
        (self.repo / "side").write_text("side\n")
        side = self.commit("side change")
        self.git("checkout", "-q", "main")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "merge", "-q", "--no-ff", "-m", "merge side", side)
        self.commits.append(self.git("rev-parse", "HEAD"))
        self.side = side

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True, stderr=subprocess.PIPE).strip()

    def write(self, state):
        (self.repo / "state").write_text(state)

    def commit(self, message):
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def run(self):
        logs = self.root / "logs"
        result = subprocess.run([sys.executable, "-B", str(SCRIPT), "--base", self.base, "--head", self.commits[-1],
                                 "--logs", str(logs), "--", "grep", "-qx", "good", "state"],
                                cwd=self.repo, capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
        return json.loads((logs / "verdict.json").read_text()), result.stdout, logs

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
                repository = self.batch(broken=broken)
                verdict, stdout, logs = repository.run()
                self.assertEqual(verdict["verdict"], "culprit")
                self.assertEqual(verdict["culprit"], repository.commits[broken])
                self.assertIn(f"Promotion bisect: first failing commit {repository.commits[broken]} (change {broken})",
                              stdout)
                # HEAD, then a binary search over eight commits, then stable only for the first.
                self.assertLessEqual(len(verdict["replays"]), 1 + 3 + (broken == 0))
                self.assertEqual(verdict["replays"][0], dict(sha=repository.commits[-1], passed=False))
                # Replay output stays out of the job log, and the tree returns to HEAD.
                self.assertTrue((logs / f"{repository.commits[-1]}.log").exists())
                self.assertEqual(repository.git("rev-parse", "HEAD"), repository.commits[-1])
                self.assertNotIn(repository.side, [replay["sha"] for replay in verdict["replays"]])

    def test_a_red_that_passes_again_at_head_is_not_blamed_on_a_commit(self):
        verdict, stdout, _ = self.batch().run()
        self.assertEqual(verdict["verdict"], "not-reproduced")
        self.assertEqual(len(verdict["replays"]), 1)
        self.assertIn("did not fail again", stdout)

    def test_a_red_already_present_at_stable_blames_no_batch_commit(self):
        verdict, stdout, _ = self.batch(base_bad=True).run()
        self.assertEqual(verdict["verdict"], "before-batch")
        self.assertNotIn("culprit", verdict)
        self.assertEqual(verdict["replays"][-1]["sha"], verdict["base"])
        self.assertIn("fails at", stdout)

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
