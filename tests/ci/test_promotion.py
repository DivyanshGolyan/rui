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
        self.git("checkout", "-q", "-b", "side", self.commits[2])
        (self.repo / "side").write_text("side\n")
        self.side = self.commit("side change")
        self.git("checkout", "-q", "main")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "merge", "-q", "--no-ff", "-m", "merge side", self.side)
        self.commits.append(self.git("rev-parse", "HEAD"))
        self.env = dict(os.environ, RUNNER_TEMP=str(self.root / "runner"))
        self.env.pop("GITHUB_STEP_SUMMARY", None)
        self.env["RUNNER_OS"] = "Linux"
        (self.root / "runner").mkdir()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True, stderr=subprocess.PIPE).strip()

    def commit(self, message):
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def steps(self, *arguments):
        return subprocess.run([sys.executable, "-B", str(STEPS), *arguments], cwd=self.repo, env=self.env,
                              capture_output=True, text=True).returncode

    def check(self):
        return self.steps(*(f"{name}=grep -qx good {name}" for name in self.FILES))

    def bisect(self, runner_os="Linux"):
        logs = self.root / "logs"
        env = dict(self.env)
        if runner_os is None:
            env.pop("RUNNER_OS")
        else:
            env["RUNNER_OS"] = runner_os
        result = subprocess.run([sys.executable, "-B", str(PROMOTION), "--base", self.base, "--head", self.commits[-1],
                                 "--logs", str(logs)], cwd=self.repo, env=env, capture_output=True, text=True)
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
                self.assertLessEqual(len(step["replays"]), 1 + 3 + (broken == 0))
                self.assertEqual(step["replays"][0], dict(sha=repository.commits[-1], passed=False))
                self.assertEqual(repository.git("rev-parse", "HEAD"), repository.commits[-1])
                self.assertNotIn(repository.side, [replay["sha"] for replay in step["replays"]])

    def test_each_failed_step_gets_its_own_culprit(self):
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
        self.assertEqual(recorded, [dict(name="other", argv=["bash", "-euc", "grep -qx good other"])])
        verdict, _ = repository.bisect()
        self.assertEqual([step["step"] for step in verdict["steps"]], ["other"])

    def test_a_job_that_failed_before_any_recorded_step_has_nothing_to_replay(self):
        repository = self.batch(broken=dict(state=2))
        verdict, stdout = repository.bisect()
        self.assertIsNone(verdict)
        self.assertIn("nothing to replay", stdout)

    def test_a_red_that_passes_again_at_head_is_not_blamed_on_a_commit(self):
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

    def test_a_macos_runner_skips_the_replays_and_leaves_no_verdict(self):
        repository = self.batch(broken=dict(state=2))
        self.assertEqual(repository.check(), 1)
        verdict, stdout = repository.bisect(runner_os="macOS")
        self.assertIsNone(verdict)
        self.assertIn("Promotion bisect: skipped on macOS; read the failed step's log", stdout)
        self.assertNotIn("replay at", stdout)
        self.assertFalse((repository.root / "logs").exists())
        self.assertEqual(repository.git("rev-parse", "HEAD"), repository.commits[-1])

    def test_a_macos_runner_with_nothing_recorded_says_so_first(self):
        repository = self.batch()
        verdict, stdout = repository.bisect(runner_os="macOS")
        self.assertIsNone(verdict)
        self.assertIn("nothing to replay", stdout)
        self.assertNotIn("skipped", stdout)

    def test_linux_and_unset_runner_os_still_bisect(self):
        for runner_os in ("Linux", None):
            with self.subTest(runner_os=runner_os):
                repository = self.batch(broken=dict(state=3))
                self.assertEqual(repository.check(), 1)
                verdict, stdout = repository.bisect(runner_os=runner_os)
                [step] = verdict["steps"]
                self.assertEqual(step["culprit"], repository.commits[3])
                self.assertIn("Promotion bisect: state: first fails", stdout)

    def test_replays_here_is_false_only_on_macos(self):
        self.assertFalse(promotion.replays_here({"RUNNER_OS": "macOS"}))
        self.assertTrue(promotion.replays_here({"RUNNER_OS": "Linux"}))
        self.assertTrue(promotion.replays_here({}))

    def test_the_bisect_stops_starting_replays_at_the_deadline(self):
        commits = [f"c{i}" for i in range(22)]
        now = [0]
        replays = []

        def passes(sha):
            replays.append(sha)
            now[0] += 10
            return False

        result = promotion.bisect(commits, "base", passes, deadline=25, clock=lambda: now[0])
        self.assertEqual((result["verdict"], len(replays), result["first"], result["last"], result["narrowed"]),
                         ("capped", 3, "c0", "c4", 5))
        self.assertEqual(promotion.describe(result, "base", "head"),
                         "stopped at the 90-minute cap after 3 replays; the first failing commit is in c0..c4 "
                         "or before this batch (stable not checked)")

    def test_a_deadline_that_has_passed_starts_no_replay_and_a_later_one_finds_the_culprit(self):
        commits = [f"c{i}" for i in range(22)]
        replays = []
        result = promotion.bisect(commits, "base", lambda sha: replays.append(sha) or False,
                                  deadline=5, clock=lambda: 5)
        self.assertEqual((result["verdict"], replays, result["narrowed"]), ("capped", [], 22))
        found = promotion.bisect(commits, "base", lambda sha: int(sha[1:]) < 3, deadline=5, clock=lambda: 4)
        self.assertEqual(found["culprit"], "c3")

    def test_the_cap_verdict_is_true_at_every_check_point(self):
        # 22 commits c0..c21; each replay takes 10 seconds on the injected clock.
        commits = [f"c{i}" for i in range(22)]
        cases = [
            # (name, passes, deadline, replayed, verdict fields, describe text)
            ("before HEAD", lambda sha: False, 0, [],
             dict(batch_passed=False), "the 90-minute cap left this step unreplayed; read its log"),
            ("in the loop with no batch commit passed", lambda sha: False, 15, ["c21", "c10"],
             dict(batch_passed=False, first="c0", last="c10"),
             "stopped at the 90-minute cap after 2 replays; the first failing commit is in c0..c10 "
             "or before this batch (stable not checked)"),
            ("in the loop after a batch commit passed", lambda sha: int(sha[1:]) < 3, 40,
             ["c21", "c10", "c4", "c1"], dict(batch_passed=True, first="c2", last="c4", narrowed=3),
             "stopped at the 90-minute cap after 4 replays; the first failing commit is one of the 3 commits "
             "from c2 to c4"),
            ("before the stable check", lambda sha: False, 50, ["c21", "c10", "c4", "c1", "c0"],
             dict(batch_passed=False, first="c0", last="c0"),
             "stopped at the 90-minute cap after 5 replays; the first failing commit is c0 or before this batch "
             "(stable not checked)"),
        ]
        for name, passes, deadline, replayed, fields, text in cases:
            with self.subTest(check_point=name):
                sent = []

                def replay(sha):
                    sent.append(sha)
                    return passes(sha)

                now = [0]

                def clock():
                    return now[0]

                def timed(sha):
                    now[0] += 10
                    return replay(sha)

                result = promotion.bisect(commits, "base", timed, deadline=deadline, clock=clock)
                self.assertEqual(result["verdict"], "capped")
                self.assertEqual(sent, replayed)
                self.assertEqual({key: result[key] for key in fields}, fields)
                self.assertEqual(promotion.describe(result, "base", "head"), text)

    def test_a_far_future_deadline_replays_exactly_what_no_deadline_does(self):
        commits = [f"c{i}" for i in range(22)]
        for broken in (0, 1, 10, 21, None):
            with self.subTest(broken=broken):
                sequences = []
                for deadline in (None, 10**9):
                    replays = []

                    def passes(sha):
                        replays.append(sha)
                        return sha == "base" or (broken is not None and int(sha[1:]) < broken)

                    result = promotion.bisect(commits, "base", passes, deadline=deadline, clock=lambda: 0)
                    sequences.append((replays, result["verdict"], result.get("culprit")))
                self.assertEqual(sequences[0], sequences[1])

    def test_two_steps_sharing_one_deadline_give_the_second_step_no_replay(self):
        commits = [f"c{i}" for i in range(22)]
        failed = [dict(name="first", argv=["a"]), dict(name="second", argv=["b"])]
        now = [0]
        replayed = {0: [], 1: []}

        def replay(index, step, sha):
            replayed[index].append(sha)
            now[0] += 10
            return False

        results, lines = promotion.bisect_steps(failed, commits, "base", "head", replay, deadline=25,
                                                clock=lambda: now[0])
        self.assertEqual(replayed[0], ["c21", "c10", "c4"])
        self.assertEqual(replayed[1], [])
        self.assertEqual([result["step"] for result in results], ["first", "second"])
        self.assertEqual(lines, [
            "Promotion bisect: first: stopped at the 90-minute cap after 3 replays; the first failing commit is "
            "in c0..c4 or before this batch (stable not checked)",
            "Promotion bisect: second: the 90-minute cap left this step unreplayed; read its log",
        ])

    def test_search_order(self):
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
