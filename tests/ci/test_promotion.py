from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import unittest

import promotion
import run_selected
import select_tests
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

    def bisect(self):
        """The manual bisect of the failed steps this job recorded, across the batch."""
        logs = self.root / "logs"
        code = ("import sys; from pathlib import Path; import promotion, steps; "
                "promotion.run_bisect(sys.argv[1], sys.argv[2], steps.failures(steps.record_path()), Path(sys.argv[3]))")
        result = subprocess.run([sys.executable, "-B", "-c", code, self.base, self.commits[-1], str(logs)],
                                cwd=self.repo, env=dict(self.env, PYTHONPATH=str(PROMOTION.parent)),
                                capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
        verdict = logs / "verdict.json"
        return (json.loads(verdict.read_text()) if verdict.exists() else None), result.stdout

    def suspects(self):
        result = subprocess.run([sys.executable, "-B", str(PROMOTION), "suspects", "--base", self.base,
                                 "--head", self.commits[-1]], cwd=self.repo, env=self.env,
                                capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
        return result.stdout

    def close(self):
        self.scratch.cleanup()


class ManualBisectTest(unittest.TestCase):
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
                         "stopped at the 90-minute cap after 3 replays; the first failing commit is one of c0 to c4 "
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
             "stopped at the 90-minute cap after 2 replays; the first failing commit is one of c0 to c10 "
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
            "one of c0 to c4 or before this batch (stable not checked)",
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


def entry(sha, subject, **paths):
    """A batch commit for rank(): `paths` maps each changed path to its {target: tier} reach."""
    return dict(sha=sha, subject=subject, paths=paths)


DIRECT, GRAPH, BROAD = select_tests.DIRECT, select_tests.GRAPH, select_tests.BROAD


class SuspectRankingTest(unittest.TestCase):
    def test_a_commit_that_owns_the_target_ranks_above_one_the_graph_reaches_and_one_a_fallback_selects(self):
        batch = [
            entry("a" * 40, "Graph (#1)", **{"xray": {"stack-frames": GRAPH}}),
            entry("b" * 40, "Fallback (#2)", **{"yankee": {"stack-frames": BROAD}}),
            entry("c" * 40, "Owner (#3)", **{"tests/ci/stack_frames.py": {"stack-frames": DIRECT}}),
        ]
        ranked = promotion.rank(["stack-frames"], batch)
        self.assertEqual([(suspect["sha"][0], suspect["tier"]) for suspect in ranked],
                         [("c", DIRECT), ("a", GRAPH), ("b", BROAD)])

    def test_within_a_tier_the_newer_commit_ranks_first(self):
        batch = [entry(f"{letter}" * 40, f"Change {letter} (#{number})", **{"alpha": {"t": GRAPH}})
                 for number, letter in enumerate("abc", 1)]
        ranked = promotion.rank(["t"], batch)
        self.assertEqual([suspect["sha"][0] for suspect in ranked], ["c", "b", "a"])

    def test_the_commit_tier_is_its_most_direct_touched_file_and_only_matching_files_are_listed(self):
        batch = [entry("d" * 40, "Mixed (#4)", **{"alpha": {"t": BROAD}, "beta": {"t": GRAPH},
                                                  "gamma": {"other": DIRECT}})]
        [suspect] = promotion.rank(["t"], batch)
        self.assertEqual((suspect["tier"], suspect["files"]), (GRAPH, ["beta"]))

    def test_a_step_with_several_targets_is_reached_through_any_of_them(self):
        batch = [entry("e" * 40, "Second (#5)", **{"alpha": {"admission": GRAPH}}),
                 entry("f" * 40, "First (#6)", **{"beta": {"human": GRAPH}})]
        self.assertEqual([suspect["sha"][0] for suspect in promotion.rank(["admission", "human"], batch)], ["f", "e"])

    def test_no_commit_selecting_the_targets_gives_no_suspects(self):
        batch = [entry("a" * 40, "Unrelated (#7)", **{"delta": {}})]
        self.assertEqual(promotion.rank(["stack-frames"], batch), [])
        self.assertEqual(promotion.rank(["stack-frames"], []), [])

    def test_only_the_top_five_are_kept(self):
        batch = [entry(f"{number:040d}", f"Change {number} (#{number})", **{"alpha": {"t": GRAPH}})
                 for number in range(9)]
        ranked = promotion.rank(["t"], batch)
        self.assertEqual(len(ranked), promotion.TOP_SUSPECTS)
        self.assertEqual(ranked[0]["sha"], f"{8:040d}")


class SuspectReportTest(unittest.TestCase):
    SHA = "9" * 40

    def test_each_suspect_line_names_its_commit_pr_tier_and_matching_files(self):
        ranked = [dict(sha=self.SHA, subject="Change the bash owner (#1692)", tier=GRAPH,
                       files=["alpha", "beta"], position=3)]
        [line] = promotion.suspect_lines("stack-frames", ["stack-frames"], ranked, 25)
        self.assertEqual(line, f"Promotion suspects: stack-frames: 1. {self.SHA} PR #1692, tier b (import or rule): "
                               "Change the bash owner (#1692); touched alpha, beta")
        self.assertTrue(line.startswith(promotion.SUSPECT_PREFIX + "stack-frames: "))

    def test_a_subject_without_a_pull_request_number_says_so(self):
        self.assertIn("no PR number in the subject",
                      promotion.suspect_lines("s", ["s"], [dict(sha=self.SHA, subject="Direct push", tier=DIRECT,
                                                                files=["x"], position=0)], 1)[0])

    def test_an_empty_suspect_list_says_no_batch_commit_selects_the_step(self):
        [line] = promotion.suspect_lines("rsql-table", ["rsql-table"], [], 46)
        self.assertEqual(line, "Promotion suspects: rsql-table: none of the 46 batch commits selects rsql-table; "
                               "read the failed step's log")

    def test_an_empty_batch_and_a_step_no_target_names_each_say_so(self):
        self.assertIn("no commits between the base and head", promotion.suspect_lines("s", ["s"], [], 0)[0])
        self.assertIn("not a selector target", promotion.suspect_lines("running-upgrade", [], [], 3)[0])

    def test_targets_split_a_run_selected_batch_and_drop_its_flags(self):
        self.assertEqual(promotion.targets_of("check-full -Dcheck-part=execution"), ["check-full"])
        self.assertEqual(promotion.targets_of("admission-debug-integration human-cli-integration"),
                         ["admission-debug-integration", "human-cli-integration"])

    def test_the_report_prints_each_failed_steps_lines_and_its_excerpt(self):
        failed = [dict(name="stack-frames", argv=["x"], excerpt=["boom", "last line"]),
                  dict(name="rsql-table", argv=["y"])]
        entries = [entry(self.SHA, "Change (#8)", **{"alpha": {"stack-frames": GRAPH}})]
        lines = promotion.suspect_report(failed, entries)
        self.assertEqual(lines[0], f"Promotion suspects: stack-frames: 1. {self.SHA} PR #8, tier b (import or rule): "
                                   "Change (#8); touched alpha")
        self.assertEqual(lines[1:5], ["--- stack-frames: last 2 lines of the failed step's output ---",
                                      "boom", "last line", "--- end of excerpt ---"])
        self.assertEqual(lines[5], "Promotion suspects: rsql-table: none of the 1 batch commits selects rsql-table; "
                                   "read the failed step's log")

    def test_no_recorded_failure_says_there_is_nothing_to_rank(self):
        self.assertEqual(promotion.suspect_report([], []),
                         [f"{promotion.SUSPECT_PREFIX}no recorded step failed, so there is nothing to rank; "
                          "read the job's failed step"])


class RecordedExcerptTest(unittest.TestCase):
    def runner(self, scratch):
        previous = os.environ.get("RUNNER_TEMP")

        def restore():
            if previous is None:
                os.environ.pop("RUNNER_TEMP", None)
            else:
                os.environ["RUNNER_TEMP"] = previous

        os.environ["RUNNER_TEMP"] = scratch
        self.addCleanup(restore)
        return Path(scratch)

    def test_the_record_keeps_the_last_thirty_lines_of_a_failed_steps_output_and_truncates_each(self):
        with tempfile.TemporaryDirectory() as scratch:
            runner = self.runner(scratch)
            output = "\n".join([f"line {number}" for number in range(40)] + ["x" * 400])
            steps.record_failure("stack-frames", ["zig"], output)
            [entry_] = steps.failures(runner / "rui-failed-steps.jsonl")
        self.assertEqual(len(entry_["excerpt"]), steps.EXCERPT_LINES)
        self.assertEqual(entry_["excerpt"][-1], "x" * steps.EXCERPT_WIDTH)
        self.assertEqual(entry_["excerpt"][0], "line 11")

    def test_a_failure_without_output_records_no_excerpt(self):
        with tempfile.TemporaryDirectory() as scratch:
            runner = self.runner(scratch)
            steps.record_failure("state", ["x"])
            [entry_] = steps.failures(runner / "rui-failed-steps.jsonl")
        self.assertNotIn("excerpt", entry_)


class ManualBisectCommandTest(unittest.TestCase):
    def test_a_manual_bisect_replays_the_command_run_selected_would_run_for_that_step(self):
        [failure] = promotion.manual_steps("admission-debug-integration human-cli-integration")
        self.assertEqual(failure["name"], "admission-debug-integration human-cli-integration")
        self.assertEqual(failure["argv"], run_selected.command(["admission-debug-integration", "human-cli-integration"]))

    def test_the_manual_bisect_subcommand_takes_a_step_and_a_range(self):
        result = subprocess.run([sys.executable, "-B", str(PROMOTION), "bisect", "--help"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("--step", result.stdout)
        self.assertIn("--logs", result.stdout)


if __name__ == "__main__":
    unittest.main()
