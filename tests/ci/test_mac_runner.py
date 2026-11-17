"""Runner policy domain, mutation controls and workflow/hook handoffs."""

import copy
import itertools
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import mac_runner

ROOT = Path(__file__).resolve().parents[2]
TRUSTED = "DivyanshGolyan"
OTHER = "NimishGolyan"
REPO = "DivyanshGolyan/rui"
HOSTED = "macos-15"
SELF = ["self-hosted", "macOS", "ARM64", "rui-mac"]


def runner(status="online", busy=False, label="rui-mac"):
    return {"status": status, "busy": busy, "labels": [{"name": label}]}


def cases():
    # This oracle states the accepted contract independently of decide's branches.
    events = ["pull_request", "workflow_dispatch", "workflow_call", "push", "pull_request_target", "schedule", ""]
    states = [None, [], [runner("offline")], [runner(busy=True)], [runner()],
              [runner(label="other")], [runner("offline"), runner()],
              [runner(busy=True), runner(label="other")]]
    for event_name, same_repo, author, actor, trigger, switch, promotion, compile_only, state in itertools.product(
            events, [False, True], [OTHER, TRUSTED], [OTHER, TRUSTED], [OTHER, TRUSTED],
            [None, "on", "off"], [False, True], [False, True], range(len(states))):
        event = {"pull_request": {"head": {"repo": {"full_name": REPO if same_repo else "NimishGolyan/rui"}},
                                  "user": {"login": author}}}
        eligible = (switch != "off" and not promotion and not compile_only
                    and actor == TRUSTED and trigger == TRUSTED
                    and (event_name == "workflow_dispatch"
                         or (event_name == "pull_request" and same_repo and author == TRUSTED)))
        expected = SELF if eligible and state in (4, 6) else HOSTED
        yield (event_name, event, actor, trigger, REPO,
               {"promotion": promotion, "compile_only": compile_only}, switch, states[state]), expected


class DecisionTest(unittest.TestCase):
    def test_whole_domain(self):
        for args, expected in cases():
            actual, reason = mac_runner.decide(*args)
            self.assertEqual(actual, expected, args)
            self.assertTrue(reason.endswith("."), reason)
            self.assertNotIn("\n", reason)

    def test_each_policy_condition_has_a_negative_control(self):
        # Each removed guard must produce a different result for a domain witness.
        source = Path(mac_runner.__file__).read_text()
        mutations = [
            ('switch == "off"', 'False'),
            ('event_name != "workflow_dispatch"', 'False'),
            ('not repository or head_repo != repository', 'False'),
            ('_object(pr.get("user")).get("login") not in ALLOWLIST', 'False'),
            ('actor not in ALLOWLIST', 'False'),
            ('triggering_actor not in ALLOWLIST', 'False'),
            ('_enabled(inputs.get("promotion"))', 'False'),
            ('_enabled(inputs.get("compile_only"))', 'False'),
            ('runner.get("status") == "online"', 'True'),
            ('runner.get("busy") is False', 'True'),
            ('_object(label).get("name") == "rui-mac"', 'True'),
        ]
        witnesses = list(cases())
        for before, after in mutations:
            with self.subTest(condition=before):
                self.assertIn(before, source)
                namespace = {"__name__": "mutant"}
                exec(compile(source.replace(before, after, 1), "mutant", "exec"), namespace)
                self.assertTrue(any(namespace["decide"](*args)[0] != expected for args, expected in witnesses))

    def test_missing_or_malformed_values_stay_hosted(self):
        baseline = ("pull_request", {"pull_request": {"head": {"repo": {"full_name": REPO}},
                                                     "user": {"login": TRUSTED}}},
                    TRUSTED, TRUSTED, REPO, {}, None, [runner()])
        for index, values in [(1, [None, {}, {"pull_request": None}, {"pull_request": {"head": None}}]),
                              (2, [None, ""]), (3, [None, ""]), (4, [None, ""]),
                              (7, [{}, "bad", [None], [dict(runner(), busy="false")],
                                   [dict(runner(), busy=0)], [dict(runner(), labels=None)]])]:
            for value in values:
                args = list(baseline)
                args[index] = value
                self.assertEqual(mac_runner.decide(*args)[0], HOSTED, args)


class AdapterTest(unittest.TestCase):
    def test_cli_fallback_and_outputs(self):
        for content in [None, "not JSON", "{}", '{"runners":null}', json.dumps({"runners": [runner()]})]:
            with self.subTest(content=content), tempfile.TemporaryDirectory() as directory:
                temp = Path(directory)
                (temp / "event").write_text("{}")
                if content is not None:
                    (temp / "runners").write_text(content)
                env = dict(os.environ, GITHUB_EVENT_PATH=str(temp / "event"),
                           GITHUB_EVENT_NAME="workflow_dispatch", GITHUB_ACTOR=TRUSTED,
                           GITHUB_TRIGGERING_ACTOR=TRUSTED, GITHUB_REPOSITORY=REPO,
                           INPUTS="{}", RUI_MAC_RUNNER="on", RUNNERS_PATH=str(temp / "runners"),
                           GITHUB_OUTPUT=str(temp / "output"), GITHUB_STEP_SUMMARY=str(temp / "summary"))
                subprocess.run([sys.executable, str(ROOT / "tests/ci/mac_runner.py")], env=env, check=True,
                               capture_output=True, text=True)
                expected = SELF if content == json.dumps({"runners": [runner()]}) else HOSTED
                lines = dict(line.split("=", 1) for line in (temp / "output").read_text().splitlines())
                self.assertEqual(json.loads(lines["runs_on"]), expected)
                self.assertEqual(lines["self_hosted"], str(expected == SELF).lower())
                self.assertIn("Mac runner:", (temp / "summary").read_text())

    def test_status_fetch_errors_are_hosted_and_bounded(self):
        text = (ROOT / ".github/workflows/check.yml").read_text()
        step = text.split("      - name: Read the runner status snapshot\n", 1)[1].split("      - name:", 1)[0]
        script = "\n".join(line[10:] for line in step.split("        run: |\n", 1)[1].splitlines())
        for token, result in [("", 0), ("available", 22), ("available", 28), ("available", 0)]:
            with self.subTest(token=bool(token), result=result), tempfile.TemporaryDirectory() as directory:
                temp = Path(directory)
                curl = temp / "curl"
                curl.write_text("#!/bin/bash\nprintf '%s\\n' \"$@\" > \"$RUNNER_TEMP/args\"\n"
                                "printf '%s' '{\"runners\": []}' > \"$RUNNER_TEMP/mac-runners.json\"\n"
                                f"exit {result}\n")
                curl.chmod(0o755)
                env = dict(os.environ, PATH=str(temp) + os.pathsep + os.environ["PATH"],
                           MAC_RUNNER_STATUS_TOKEN=token, RUNNER_TEMP=str(temp),
                           GITHUB_API_URL="https://api.github.com", GITHUB_REPOSITORY=REPO)
                subprocess.run(["bash", "-e", "-c", script], env=env, check=True)
                if token:
                    args = (temp / "args").read_text().splitlines()
                    self.assertEqual(args[args.index("--max-time") + 1], "10")
                    self.assertIn("--fail", args)
                    self.assertEqual((temp / "mac-runners.json").exists(), result == 0)
                else:
                    self.assertFalse((temp / "args").exists())

    def test_allowlist_cli(self):
        result = subprocess.run([sys.executable, str(ROOT / "tests/ci/mac_runner.py"), "allowlist"],
                                capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout.splitlines(), [TRUSTED])

    def test_workflow_routing_dependencies_and_cache_publication(self):
        text = (ROOT / ".github/workflows/check.yml").read_text()
        jobs = dict(re.findall(r"(?ms)^  ([a-z_]+):\n(.*?)(?=^  [a-z_]+:|\Z)", text))
        routed = set()
        for name, job in jobs.items():
            if "runs-on: ${{ fromJSON(needs.mac_runner.outputs.runs_on || '\"macos-15\"') }}" in job:
                routed.add(name)
                needs = re.search(r"^    needs: \[([^\]]+)\]", job, re.M).group(1).split(", ")
                self.assertIn("mac_runner", needs, name)
                setup = job.split("- uses: ./.github/actions/setup\n", 1)[1]
                self.assertIn("publish-caches: ${{ github.ref == 'refs/heads/main' && needs.mac_runner.outputs.self_hosted != 'true' && 'true' || 'false' }}", setup)
        self.assertEqual(routed, {"macos_build", "macos_build_unit", "macos_suites"})
        route = jobs["mac_runner"]
        self.assertIn("timeout-minutes: 3", route)
        self.assertIn("    continue-on-error: true", route)
        for producer in ("macos_build", "macos_build_unit"):
            self.assertIn("!cancelled() && needs.plan.result == 'success'", jobs[producer])
        self.assertIn("--max-time 10", route)
        self.assertEqual(text.count("secrets.MAC_RUNNER_STATUS_TOKEN"), 1)
        self.assertIn("test \"$(uname -m)\" = arm64", jobs["macos_suites"])


class HookTest(unittest.TestCase):
    @staticmethod
    def supervise(hook, env):
        # The hook's parent must be disposable: refusal kills the job worker.
        # This supervisor deliberately continues after a failed child, as always() does.
        script = ("import subprocess, sys; subprocess.run(['bash', sys.argv[1]]); "
                  "print('ALWAYS_STEP_RAN', flush=True)")
        return subprocess.run([sys.executable, "-c", script, str(hook)], env=env,
                              capture_output=True, text=True, timeout=10)

    def test_hook_admits_only_trusted_job_context(self):
        original = {"repository": {"full_name": REPO}, "sender": {"login": TRUSTED},
                    "pull_request": {"head": {"repo": {"full_name": REPO}},
                                     "base": {"repo": {"full_name": REPO}}, "user": {"login": TRUSTED}}}
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            hook = temp / "job-started.sh"
            hook.write_text((ROOT / "tests/ci/mac-runner/job-started.sh").read_text())
            (temp / "allowlist").write_text("\n".join(mac_runner.ALLOWLIST) + "\n")
            event_path = temp / "event.json"
            env = dict(os.environ, HOME=str(temp), GITHUB_REPOSITORY=REPO, GITHUB_EVENT_NAME="pull_request",
                       GITHUB_ACTOR=TRUSTED, GITHUB_TRIGGERING_ACTOR=TRUSTED, GITHUB_EVENT_PATH=str(event_path))
            variants = [({}, original, True), ({"GITHUB_EVENT_NAME": "workflow_dispatch"}, original, True)]
            for key, value in [("GITHUB_REPOSITORY", "another/repo"), ("GITHUB_EVENT_NAME", "push"),
                               ("GITHUB_EVENT_NAME", "pull_request_target"), ("GITHUB_EVENT_NAME", "workflow_call"),
                               ("GITHUB_ACTOR", OTHER), ("GITHUB_TRIGGERING_ACTOR", OTHER),
                               ("GITHUB_ACTOR", ""), ("GITHUB_TRIGGERING_ACTOR", "")]:
                variants.append(({key: value}, original, False))
            for path, value in [(('pull_request', 'head', 'repo', 'full_name'), 'NimishGolyan/rui'),
                                (('pull_request', 'user', 'login'), OTHER)]:
                event = copy.deepcopy(original)
                target = event
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                variants.append(({}, event, False))
            variants.extend([({}, {}, False), ({}, None, False)])
            for changes, event, admitted in variants:
                event_path.write_text(json.dumps(event))
                result = self.supervise(hook, dict(env, **changes))
                self.assertEqual(result.returncode, 0 if admitted else -signal.SIGKILL,
                                 (changes, event, result.stderr))
                self.assertEqual("ALWAYS_STEP_RAN" in result.stdout, admitted)
            event_path.write_text("not JSON")
            result = self.supervise(hook, env)
            self.assertEqual(result.returncode, -signal.SIGKILL)
            self.assertNotIn("ALWAYS_STEP_RAN", result.stdout)

    def test_hook_failure_cannot_continue_to_an_always_step(self):
        source = (ROOT / "tests/ci/mac-runner/job-started.sh").read_text()
        with tempfile.TemporaryDirectory() as directory:
            hook = Path(directory) / "job-started.sh"
            for variant in [source, source.replace("python3 -I -S", "/missing-python -I -S"),
                            source.replace('policy_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)',
                                           'policy_dir=$(false)')]:
                hook.write_text(variant)
                result = self.supervise(hook, dict(os.environ, GITHUB_REPOSITORY="wrong/repo"))
                self.assertEqual(result.returncode, -signal.SIGKILL, result.stderr)
                self.assertNotIn("ALWAYS_STEP_RAN", result.stdout)
            # Removing hard refusal recreates the upstream exit-only bypass.
            self.assertIn('kill -KILL "$PPID"', source)
            hook.write_text(source.replace('kill -KILL "$PPID"', ':'))
            result = self.supervise(hook, dict(os.environ, GITHUB_REPOSITORY="wrong/repo"))
            self.assertEqual(result.returncode, 0)
            self.assertIn("ALWAYS_STEP_RAN", result.stdout)

    def test_hook_trims_cache_only_above_limit_after_admission(self):
        source = (ROOT / "tests/ci/mac-runner/job-started.sh").read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            allowlist = temp / "allowlist"
            allowlist.write_text("\n".join(mac_runner.ALLOWLIST))
            event = temp / "event"
            event.write_text(json.dumps({"repository": {"full_name": REPO}, "sender": {"login": TRUSTED}}))
            cache = temp / ".cache" / "zig"
            cache.mkdir(parents=True)
            env = {"GITHUB_REPOSITORY": REPO, "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_ACTOR": TRUSTED,
                   "GITHUB_TRIGGERING_ACTOR": TRUSTED, "GITHUB_EVENT_PATH": str(event)}
            for size in [40 * 1024 * 1024, 40 * 1024 * 1024 + 1]:
                with patch.dict(os.environ, env), patch.object(sys, "argv", ["hook", str(allowlist)]), \
                        patch("pathlib.Path.home", return_value=temp), patch("subprocess.run") as du, \
                        patch("shutil.rmtree") as remove:
                    du.return_value.stdout = f"{size}\t{cache}\n"
                    exec(compile(source, "hook", "exec"), {"__name__": "hook"})
                    self.assertEqual(remove.called, size > 40 * 1024 * 1024)
            with patch.dict(os.environ, dict(env, GITHUB_ACTOR=OTHER)), \
                    patch.object(sys, "argv", ["hook", str(allowlist)]), patch("subprocess.run") as du:
                with self.assertRaises(SystemExit):
                    exec(compile(source, "hook", "exec"), {"__name__": "hook"})
                du.assert_not_called()


if __name__ == "__main__":
    unittest.main()
