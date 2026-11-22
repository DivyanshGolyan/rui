"""Runner policy domain, mutation controls and workflow/hook handoffs."""

import copy
import itertools
import json
import os
from pathlib import Path
import re
import shutil
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
        eligible = (switch != "off" and not compile_only
                    and actor == TRUSTED and trigger == TRUSTED
                    and (event_name == "workflow_dispatch"
                         or (event_name == "pull_request" and same_repo and author == TRUSTED)))
        expected = SELF if eligible and state in (4, 6) else HOSTED
        offline = eligible and state in (1, 2, 5)
        yield (event_name, event, actor, trigger, REPO,
               {"promotion": promotion, "compile_only": compile_only}, switch, states[state]), (expected, offline)


class DecisionTest(unittest.TestCase):
    def test_whole_domain(self):
        for args, (expected, expected_offline) in cases():
            actual, reason, offline = mac_runner.decide(*args)
            self.assertEqual(actual, expected, args)
            self.assertEqual(offline, expected_offline, args)
            self.assertTrue(reason.endswith("."), reason)
            self.assertNotIn("\n", reason)

    def test_shared_admission_domain(self):
        count = 0
        for args, (expected, _) in cases():
            if args[5] != {"promotion": False, "compile_only": False} or args[6] is not None or args[7] != [runner()]:
                continue
            admitted, reason = mac_runner.admission(*args[:5])
            self.assertEqual(admitted, expected == SELF, args)
            self.assertTrue(reason.endswith("."))
            count += 1
        self.assertEqual(count, 112)

    def test_each_policy_condition_has_a_negative_control(self):
        # Each removed guard must produce a different result for a domain witness.
        source = Path(mac_runner.__file__).read_text()
        mutations = [
            ('switch == "off"', 'False'),
            ('event_name != "workflow_dispatch"', 'False'),
            ('not repository or head_repo != repository', 'False'),
            ('_object(pr.get("user")).get("login") not in allowlist', 'False'),
            ('actor not in allowlist', 'False'),
            ('triggering_actor not in allowlist', 'False'),
            ('_enabled(inputs.get("compile_only"))', 'False'),
            ('runner.get("status") == "online"', 'True'),
            ('runner.get("busy") is False', 'True'),
            ('_object(label).get("name") == "rui-mac"', 'True'),
        ]
        witnesses = [(args, expected) for args, (expected, _) in cases()]
        for before, after in mutations:
            with self.subTest(condition=before):
                self.assertIn(before, source)
                namespace = {"__name__": "mutant"}
                exec(compile(source.replace(before, after, 1), "mutant", "exec"), namespace)
                self.assertTrue(any(namespace["decide"](*args)[0] != expected for args, expected in witnesses))

    def test_queue_decisions_and_mutation_controls(self):
        base = ("workflow_dispatch", {}, TRUSTED, TRUSTED, REPO, {}, None)
        zero = {"mac_queued": 0, "hosted_queued": 0, "hosted_running": 0}
        examples = [
            ([runner()], dict(zero), SELF),
            ([runner(busy=True)], dict(zero, hosted_queued=2, mac_queued=1), SELF),
            ([runner(busy=True)], dict(zero, hosted_queued=1, mac_queued=1), HOSTED),
            ([runner(busy=True)], dict(zero, hosted_queued=1, mac_queued=2), HOSTED),
            ([runner(busy=True)], dict(zero, hosted_running=5), SELF),
            ([runner(busy=True)], dict(zero, hosted_running=4), HOSTED),
            ([runner(busy=True)], None, HOSTED),
            ([runner()], None, SELF),
            ([runner("offline", busy=True)], dict(zero, hosted_queued=3), HOSTED),
        ]
        for runners, queue, expected in examples:
            with self.subTest(runners=runners, queue=queue):
                actual, reason, _ = mac_runner.decide(*base, runners, queue)
                self.assertEqual(actual, expected)
                if queue is not None:
                    for value in queue.values():
                        self.assertIn(str(value), reason)
                else:
                    self.assertIn("unavailable", reason)
        for invalid in ({}, {**zero, "mac_queued": -1}, {**zero, "hosted_running": True},
                        {**zero, "hosted_queued": "1"}, []):
            self.assertEqual(mac_runner.decide(*base, [runner(busy=True)], invalid)[0], HOSTED)
            self.assertEqual(mac_runner.decide(*base, [runner()], invalid)[0], SELF)
        source = Path(mac_runner.__file__).read_text()
        mutations = [
            ('runner.get("busy") is False', 'False'),
            ('runner.get("status") == "online"', 'True'),
            ('queue["mac_queued"] < queue["hosted_queued"]', 'queue["mac_queued"] <= queue["hosted_queued"]'),
            ('queue["mac_queued"] < queue["hosted_queued"]', 'queue["mac_queued"] > queue["hosted_queued"]'),
            ('queue["hosted_running"] >= 5', 'queue["hosted_running"] > 5'),
            ('and valid_queue\n', 'and True\n'),
        ]
        for before, after in mutations:
            with self.subTest(mutation=before, replacement=after):
                self.assertIn(before, source)
                namespace = {"__name__": "mutant"}
                exec(compile(source.replace(before, after, 1), "mutant", "exec"), namespace)
                def differs(case):
                    runners, queue, expected = case
                    try:
                        return namespace["decide"](*base, runners, queue)[0] != expected
                    except (TypeError, KeyError):
                        return True
                self.assertTrue(any(differs(case) for case in examples))

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


SHORTER = {"mac_queued": 0, "hosted_queued": 1, "hosted_running": 0}
LONGER = {"mac_queued": 2, "hosted_queued": 1, "hosted_running": 0}
OFFLINE_SENTENCE = "Hosted macOS is selected because the rui-mac runner is offline."
# (name, option overrides, runners, queue, route, offline flag); every admitted row is a trusted dispatch.
OFFLINE_CASES = [
    ("switch off", {"switch": "off"}, [runner("offline")], None, HOSTED, False),
    ("not admitted", {"event_name": "push"}, [runner("offline")], None, HOSTED, False),
    ("compile only", {"inputs": {"compile_only": True}}, [runner("offline")], None, HOSTED, False),
    ("status unavailable", {}, None, None, HOSTED, False),
    ("status not a list", {}, {}, None, HOSTED, False),
    ("status row not an object", {}, [None], None, HOSTED, False),
    ("rui-mac row without a status", {}, [{"labels": [{"name": "rui-mac"}]}], None, HOSTED, False),
    ("labels not a list", {}, [dict(runner("offline"), labels="rui-mac")], None, HOSTED, False),
    ("runner offline", {}, [runner("offline")], None, HOSTED, True),
    ("no rui-mac runner", {}, [runner(label="other")], None, HOSTED, True),
    ("online idle", {}, [runner()], None, SELF, False),
    ("online busy, shorter queue", {}, [runner(busy=True)], SHORTER, SELF, False),
    ("online busy, longer queue", {}, [runner(busy=True)], LONGER, HOSTED, False),
]


class OfflineWarningTest(unittest.TestCase):
    def options(self, overrides):
        options = {"event_name": "workflow_dispatch", "inputs": {}, "switch": "on"}
        options.update(overrides)
        return options

    def run_main(self, options, runners, queue):
        # Drives the CLI as CI does: its env contract, its GITHUB_OUTPUT route and its stdout annotations.
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            (temp / "event").write_text("{}")
            if runners is not None:
                (temp / "runners").write_text(json.dumps({"runners": runners}))
            if queue is not None:
                (temp / "queue").write_text(json.dumps(queue))
            env = {"GITHUB_EVENT_PATH": str(temp / "event"), "GITHUB_EVENT_NAME": options["event_name"],
                   "GITHUB_ACTOR": TRUSTED, "GITHUB_TRIGGERING_ACTOR": TRUSTED, "GITHUB_REPOSITORY": REPO,
                   "INPUTS": json.dumps(options["inputs"]), "RUI_MAC_RUNNER": options["switch"],
                   "RUNNERS_PATH": str(temp / "runners"), "QUEUE_PATH": str(temp / "queue"),
                   "GITHUB_OUTPUT": str(temp / "output"), "GITHUB_STEP_SUMMARY": str(temp / "summary")}
            stdout = subprocess.run([sys.executable, str(ROOT / "tests/ci/mac_runner.py")], env=env, check=True,
                                    capture_output=True, text=True).stdout
            lines = dict(line.split("=", 1) for line in (temp / "output").read_text().splitlines())
            annotations = [line for line in stdout.splitlines() if line.startswith("::")]
            return json.loads(lines["runs_on"]), annotations

    def test_offline_flag_route_and_annotation_table(self):
        for name, overrides, runners, queue, route, offline in OFFLINE_CASES:
            with self.subTest(name):
                options = self.options(overrides)
                actual, reason, flag = mac_runner.decide(
                    options["event_name"], {}, TRUSTED, TRUSTED, REPO, options["inputs"], options["switch"],
                    runners, queue)
                self.assertEqual((actual, flag), (route, offline), reason)
                self.assertEqual(reason.startswith(OFFLINE_SENTENCE), offline, reason)
                self.assertNotIn("\n", reason)
                routed, annotations = self.run_main(options, runners, queue)
                self.assertEqual(routed, route)
                self.assertEqual(annotations, [f"::warning title=rui-mac offline::{reason}"] if offline else [])

    def test_offline_flag_has_negative_controls(self):
        source = Path(mac_runner.__file__).read_text()
        mutations = [
            ("if not online:", "if False:"),
            ("            online = True\n", ""),
        ]
        for before, after in mutations:
            with self.subTest(mutation=before):
                self.assertIn(before, source)
                namespace = {"__name__": "mutant"}
                exec(compile(source.replace(before, after, 1), "mutant", "exec"), namespace)
                def differs(case):
                    _, overrides, runners, queue, _, offline = case
                    options = self.options(overrides)
                    flag = namespace["decide"](options["event_name"], {}, TRUSTED, TRUSTED, REPO,
                                               options["inputs"], options["switch"], runners, queue)[2]
                    return flag != offline
                self.assertTrue(any(differs(case) for case in OFFLINE_CASES))


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

    def test_cli_queue_snapshot_and_malformed_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            (temp / "event").write_text("{}")
            (temp / "runners").write_text(json.dumps({"runners": [runner(busy=True)]}))
            env = dict(os.environ, GITHUB_EVENT_PATH=str(temp / "event"),
                       GITHUB_EVENT_NAME="workflow_dispatch", GITHUB_ACTOR=TRUSTED,
                       GITHUB_TRIGGERING_ACTOR=TRUSTED, GITHUB_REPOSITORY=REPO,
                       INPUTS="{}", RUNNERS_PATH=str(temp / "runners"), QUEUE_PATH=str(temp / "queue"),
                       GITHUB_OUTPUT=str(temp / "output"))
            for content, expected in [(None, HOSTED), ("bad json", HOSTED),
                                      (json.dumps({"mac_queued": 0, "hosted_queued": 1, "hosted_running": 0}), SELF)]:
                (temp / "queue").unlink(missing_ok=True)
                (temp / "output").unlink(missing_ok=True)
                if content is not None:
                    (temp / "queue").write_text(content)
                subprocess.run([sys.executable, str(ROOT / "tests/ci/mac_runner.py")], env=env, check=True,
                               capture_output=True, text=True)
                lines = dict(line.split("=", 1) for line in (temp / "output").read_text().splitlines())
                self.assertEqual(json.loads(lines["runs_on"]), expected)

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

    def test_promotion_passes_only_the_status_token_to_its_routing(self):
        check = (ROOT / ".github/workflows/check.yml").read_text()
        call = check.split("  workflow_call:\n", 1)[1].split("\npermissions:", 1)[0]
        self.assertIn("    secrets:\n", call)
        self.assertRegex(call, r"(?m)^      MAC_RUNNER_STATUS_TOKEN:\n        required: false$")
        tier = (ROOT / ".github/workflows/qualification-tier.yml").read_text()
        self.assertRegex(tier.split("\npermissions:", 1)[0], r"(?m)^      MAC_RUNNER_STATUS_TOKEN:\n        required: false$")
        token = ["MAC_RUNNER_STATUS_TOKEN: ${{ secrets.MAC_RUNNER_STATUS_TOKEN }}"]
        # Runner routing is the one input the tier's callers may pass: Promote passes the token so a dispatched
        # promotion's macOS jobs may route to rui-mac, and the tier's own check passes it on. A scheduled
        # event is not admitted to rui-mac, so its jobs stay hosted whatever the token holds.
        for path, job, uses, expected in ((".github/workflows/qualification-tier.yml", "selected", "check.yml", token),
                                          (".github/workflows/promote.yml", "qualify", "qualification-tier.yml", token)):
            with self.subTest(caller=path):
                text = (ROOT / path).read_text()
                body = re.search(rf"(?ms)^  {job}:\n(.*?)(?=^  [a-z_]+:|\Z)", text)[1]
                self.assertIn(f"uses: ./.github/workflows/{uses}", body)
                secrets = body.split("    secrets:\n", 1)[1] if "    secrets:\n" in body else ""
                self.assertEqual([line.strip() for line in secrets.splitlines() if line.strip()], expected,
                                 "a caller passes the status token alone, never inherit")

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
    def supervise(hook, env, cwd=None):
        # The hook's parent must be disposable: refusal kills the job worker.
        # This supervisor deliberately continues after a failed child, as always() does.
        script = ("import subprocess, sys; subprocess.run(['bash', sys.argv[1]]); "
                  "print('ALWAYS_STEP_RAN', flush=True)")
        return subprocess.run([sys.executable, "-c", script, str(hook)], env=env,
                              capture_output=True, text=True, timeout=60, cwd=cwd)

    def test_hook_admits_only_trusted_job_context(self):
        original = {"repository": {"full_name": REPO}, "sender": {"login": TRUSTED},
                    "pull_request": {"head": {"repo": {"full_name": REPO}},
                                     "base": {"repo": {"full_name": REPO}}, "user": {"login": TRUSTED}}}
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            hook = temp / "job-started.sh"
            hook.write_text((ROOT / "tests/ci/mac-runner/job-started.sh").read_text())
            (temp / "mac_runner.py").write_text((ROOT / "tests/ci/mac_runner.py").read_text())
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
                if "GITHUB_ACTOR" in changes and isinstance(event, dict) and "sender" in event:
                    event = copy.deepcopy(event)
                    event["sender"]["login"] = changes["GITHUB_ACTOR"]
                event_path.write_text(json.dumps(event))
                result = self.supervise(hook, dict(env, **changes))
                self.assertEqual(result.returncode, 0 if admitted else -signal.SIGKILL,
                                 (changes, event, result.stderr))
                self.assertEqual("ALWAYS_STEP_RAN" in result.stdout, admitted)
            event_path.write_text("not JSON")
            result = self.supervise(hook, env)
            self.assertEqual(result.returncode, -signal.SIGKILL)
            self.assertNotIn("ALWAYS_STEP_RAN", result.stdout)

    def test_hook_imports_installed_policy_instead_of_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            policy = temp / "policy"
            checkout = temp / "checkout"
            policy.mkdir()
            checkout.mkdir()
            hook = policy / "job-started.sh"
            hook.write_text((ROOT / "tests/ci/mac-runner/job-started.sh").read_text())
            (policy / "mac_runner.py").write_text((ROOT / "tests/ci/mac_runner.py").read_text())
            (policy / "allowlist").write_text(TRUSTED + "\n")
            (checkout / "mac_runner.py").write_text('def admission(*args): return True, "bypassed"\n')
            event = temp / "event.json"
            event.write_text(json.dumps({"repository": {"full_name": REPO}, "sender": {"login": OTHER}}))
            env = dict(os.environ, HOME=str(temp), PYTHONPATH=str(checkout), GITHUB_REPOSITORY=REPO,
                       GITHUB_EVENT_NAME="workflow_dispatch", GITHUB_ACTOR=OTHER,
                       GITHUB_TRIGGERING_ACTOR=TRUSTED, GITHUB_EVENT_PATH=str(event))
            result = self.supervise(hook, env, cwd=checkout)
            self.assertEqual(result.returncode, -signal.SIGKILL, result.stderr)
            self.assertIn("allowlisted", result.stderr)
            self.assertNotIn("ALWAYS_STEP_RAN", result.stdout)

    def test_exact_policy_source_ignores_installed_package_and_bytecode_collisions(self):
        source = (ROOT / "tests/ci/mac-runner/job-started.sh").read_text()
        loader = source.split('policy_path = ', 1)[1].split('admission = policy["admission"]', 1)[0]
        loader = 'policy_path = ' + loader + 'admission = policy["admission"]'
        unsafe = 'sys.path.insert(0, str(Path(sys.argv[1]).parent))\nfrom mac_runner import RUNNER_USER as runner_user, admission'
        accept = 'RUNNER_USER = "nobody"\ndef admission(*args): return True, "Accepted."\n'
        for collision in ("package", "bytecode"):
            with self.subTest(collision=collision), tempfile.TemporaryDirectory() as directory:
                temp = Path(directory)
                policy = temp / "policy"
                policy.mkdir()
                module = policy / "mac_runner.py"
                module.write_text((ROOT / "tests/ci/mac_runner.py").read_text())
                hook = policy / "job-started.sh"
                (policy / "allowlist").write_text("\n".join(mac_runner.ALLOWLIST))
                if collision == "package":
                    (policy / "mac_runner").mkdir()
                    (policy / "mac_runner" / "__init__.py").write_text(accept)
                else:
                    writable = temp / "writable-bytecode"
                    writable.mkdir()
                    (policy / "__pycache__").symlink_to(writable, target_is_directory=True)
                    # Forge a timestamp/size-valid cache using the hook's interpreter.
                    forge = ("import importlib.util,marshal,pathlib,py_compile,sys; "
                             "p=pathlib.Path(sys.argv[1]); c=pathlib.Path(importlib.util.cache_from_source(str(p))); "
                             "py_compile.compile(str(p),cfile=str(c),doraise=True); "
                             "c.write_bytes(c.read_bytes()[:16]+marshal.dumps(compile(sys.argv[2],str(p),'exec')))")
                    path = re.search(r"^export PATH=(.*)$", source, re.M).group(1)
                    subprocess.run(["python3", "-I", "-S", "-c", forge, str(module), accept],
                                   env=dict(os.environ, PATH=path), check=True)
                event = temp / "event"
                event.write_text(json.dumps({"repository": {"full_name": REPO}, "sender": {"login": OTHER}}))
                env = dict(os.environ, HOME=str(temp), GITHUB_REPOSITORY=REPO,
                           GITHUB_EVENT_NAME="workflow_dispatch", GITHUB_ACTOR=OTHER,
                           GITHUB_TRIGGERING_ACTOR=TRUSTED, GITHUB_EVENT_PATH=str(event))
                hook.write_text(source)
                result = self.supervise(hook, env)
                self.assertEqual(result.returncode, -signal.SIGKILL, result.stderr)
                self.assertIn("allowlisted", result.stderr)
                # Restoring ordinary import proves that each collision can admit it.
                hook.write_text(source.replace(loader, unsafe))
                result = self.supervise(hook, env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("ALWAYS_STEP_RAN", result.stdout)

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
            (temp / "mac_runner.py").write_text((ROOT / "tests/ci/mac_runner.py").read_text())
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

    def test_hook_clears_leftovers_only_as_the_runner_account(self):
        source = (ROOT / "tests/ci/mac-runner/job-started.sh").read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            allowlist = temp / "allowlist"
            (temp / "mac_runner.py").write_text((ROOT / "tests/ci/mac_runner.py").read_text())
            allowlist.write_text("\n".join(mac_runner.ALLOWLIST))
            event = temp / "event"
            event.write_text(json.dumps({"repository": {"full_name": REPO}, "sender": {"login": TRUSTED}}))
            env = {"GITHUB_REPOSITORY": REPO, "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_ACTOR": TRUSTED,
                   "GITHUB_TRIGGERING_ACTOR": TRUSTED, "GITHUB_EVENT_PATH": str(event)}
            # launchd 1 -> service 10 -> listener 20 -> worker 30 -> hook bash 40 -> hook python 50;
            # 60 is a leftover Host, 70 its child, 80 a leftover started by launchd.
            table = "1 0\n10 1\n20 10\n30 20\n40 30\n60 1\n70 60\n80 1\n"

            def ps_or_du(argv, **_kwargs):
                result = unittest.mock.Mock()
                result.stdout = table if argv[0] == "/bin/ps" else "1\t.\n"
                return result

            for user, cleared in [(mac_runner.RUNNER_USER, True), ("someone", False)]:
                leftover = temp / "tmp" / "rui-upgrade-x" / "locked"
                leftover.mkdir(parents=True)
                (leftover / "file").write_text("x")
                leftover.chmod(0o500)
                (temp / "tmp" / "loose").write_text("x")
                with self.subTest(user=user), patch.dict(os.environ, env), \
                        patch.object(sys, "argv", ["hook", str(allowlist)]), \
                        patch("pathlib.Path.home", return_value=temp), \
                        patch("pwd.getpwuid", return_value=unittest.mock.Mock(pw_name=user)), \
                        patch("subprocess.run", side_effect=ps_or_du), patch("os.getpid", return_value=50), \
                        patch("os.getppid", return_value=40), patch("os.kill") as kill:
                    exec(compile(source, "hook", "exec"), {"__name__": "hook"})
                    killed = sorted(call.args[0] for call in kill.call_args_list)
                    self.assertEqual(killed, [60, 70, 80] if cleared else [])
                    self.assertEqual(sorted(path.name for path in (temp / "tmp").iterdir()),
                                     [] if cleared else ["loose", "rui-upgrade-x"])
                if not cleared:
                    leftover.chmod(0o700)
                    shutil.rmtree(temp / "tmp")


class RegistrationTest(unittest.TestCase):
    def test_record_validation(self):
        valid = mac_runner.registration_record("old-host-rui", 7)
        self.assertEqual(mac_runner.registration_identity(valid), ("old-host-rui", 7))
        for change in ({"version": True}, {"version": 2}, {"repository": "other/repo"}, {"name": ""},
                       {"name": "bad\nname"}, {"id": True}, {"id": 0}, {"id": -1}, {"id": "7"}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                mac_runner.registration_identity(dict(valid, **change))
        for value in (None, {}, "bad"):
            with self.assertRaises(ValueError):
                mac_runner.registration_identity(value)
        with self.assertRaises(ValueError):
            mac_runner.registration_record("", 7)

    def test_removal_domain_uses_installed_identity(self):
        remote = [[], [{"id": 7, "name": "old-host-rui"}], [{"id": 7, "name": "renamed-remotely"}],
                  [{"id": 8, "name": "old-host-rui"}], [{"id": 8, "name": "another-runner"}],
                  [{"id": 7, "name": "old-host-rui"}, {"id": 8, "name": "old-host-rui"}]]
        matching = {"agentName": "old-host-rui", "agentId": 7, "gitHubUrl": "https://github.com/DivyanshGolyan/rui"}
        locals_ = [None, matching, dict(matching, agentId=8), dict(matching, agentName="new-host-rui"),
                   dict(matching, gitHubUrl="https://github.com/other/repo"), dict(matching, gitHubUrl=None)]
        for registered_id, state, local_index, credentials in itertools.product([None, 7], range(6), range(6), [False, True]):
            record = mac_runner.registration_record("old-host-rui", registered_id)
            local = locals_[local_index]
            # Independent expected table; no current hostname participates in identity.
            local_valid = local_index in (0, 1) or (registered_id is None and local_index == 2)
            if (not local_valid or state == 5 or (state == 2 and (registered_id == 7 or local_index == 1))
                    or (registered_id is None and state == 4 and local_index == 2)
                    or (registered_id == 7 and state == 3)):
                expected = "repair"
            elif state in (0, 4) or (registered_id is None and state == 2):
                expected = "cleanup"
            elif local_index == 1 and credentials and state == 1:
                expected = "deregister"
            elif registered_id is None and state == 3 and local_index == 2 and credentials:
                expected = "deregister"
            else:
                expected = "repair"
            result, reason = mac_runner.removal_action(record, remote[state], local, credentials)
            self.assertEqual(result, expected, (record, state, local_index, credentials))
            self.assertTrue(reason.endswith("."))

    def test_malformed_or_unscoped_removal_inputs_preserve_recovery(self):
        record = mac_runner.registration_record("old-host-rui", 7)
        for snapshot in (None, {}, [None], [{"id": True, "name": "old-host-rui"}],
                         [{"id": 7}], [{"id": 7, "name": ""}]):
            self.assertEqual(mac_runner.removal_action(record, snapshot, None, False)[0], "repair")
        for bad in (None, {}, dict(record, repository="another/repo")):
            self.assertEqual(mac_runner.removal_action(bad, [], None, False)[0], "repair")
        local = {"agentName": "old-host-rui", "agentId": 7, "gitHubUrl": "https://github.com/DivyanshGolyan/rui"}
        for credentials in (None, "true", 1, False):
            self.assertEqual(mac_runner.removal_action(record, [{"id": 7, "name": "old-host-rui"}], local, credentials)[0], "repair")

    def test_installer_record_journey_preserves_identity_before_effects(self):
        install = (ROOT / "tests/ci/mac-runner/install.sh").read_text()
        source = next(code for code in re.findall(r"<<'PY'\n(.*?)\nPY", install, re.S)
                      if "def local_registration" in code)
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            record, local, runners = (temp / name for name in ("record", ".runner", "runners"))
            runners.write_text("[]")
            def step(operation, allow_new="false", proposed="new-host-rui"):
                return subprocess.run([sys.executable, "-I", "-S", "-", str(ROOT / "tests/ci/mac_runner.py"),
                                       str(record), str(local), operation, allow_new, proposed, str(runners)],
                                      input=source, capture_output=True, text=True)
            self.assertEqual(step("prepare", "true", "old-host-rui").returncode, 0)
            self.assertEqual(json.loads(record.read_text()), mac_runner.registration_record("old-host-rui"))
            local.write_text(json.dumps({"gitHubUrl": "https://github.com/DivyanshGolyan/rui", "agentName": "old-host-rui", "agentId": 7}))
            self.assertEqual(step("complete").returncode, 0)
            runners.write_text(json.dumps([{"id": 7, "name": "old-host-rui"}]))
            self.assertEqual(step("prepare").stdout.strip(), "old-host-rui")
            self.assertEqual(json.loads(record.read_text())["id"], 7)
            # Refuse both remote rename and replacement before clearing the prior ID.
            original = record.read_bytes()
            for remote in ([{"id": 7, "name": "remote-rename"}], [{"id": 8, "name": "old-host-rui"}]):
                runners.write_text(json.dumps(remote))
                for operation in ("prepare", "intent"):
                    self.assertNotEqual(step(operation).returncode, 0)
                    self.assertEqual(record.read_bytes(), original)
            runners.write_text(json.dumps([{"id": 7, "name": "old-host-rui"}]))
            self.assertEqual(step("intent").returncode, 0)
            self.assertIsNone(json.loads(record.read_text())["id"])
            local.write_text(json.dumps({"gitHubUrl": "https://github.com/DivyanshGolyan/rui", "agentName": "old-host-rui", "agentId": 9}))
            self.assertEqual(step("complete").returncode, 0)
            self.assertEqual(json.loads(record.read_text()), mac_runner.registration_record("old-host-rui", 9))
            local.unlink()
            record.unlink()
            self.assertNotEqual(step("prepare").returncode, 0)
        first_intent = install.index('runner_name=$(registration_state "$stage" prepare')
        self.assertLess(first_intent, install.index('/usr/bin/dscl . -create /Users/ruici\n'))
        self.assertLess(install.index('registration_state "$stage" intent'), install.index('./config.sh remove --local'))

    def test_uninstaller_adapter_rechecks_local_state_and_ignores_old_receipts(self):
        uninstall = (ROOT / "tests/ci/mac-runner/uninstall.sh").read_text()
        source = next(code for code in re.findall(r"<<'PY'\n(.*?)\nPY", uninstall, re.S)
                      if 'action, reason = policy["removal_action"]' in code)
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            record, local, runners = (temp / name for name in ("record", ".runner", "runners"))
            record.write_text(json.dumps(mac_runner.registration_record("old-host-rui", 7)))
            original = record.read_bytes()
            matching = {"gitHubUrl": "https://github.com/DivyanshGolyan/rui", "agentName": "old-host-rui", "agentId": 7}
            runners.write_text(json.dumps([{"id": 7, "name": "old-host-rui"}]))
            (temp / ".rui-runner-deregistered").touch()
            def step(credentials):
                result = subprocess.run([sys.executable, "-I", "-S", "-", str(ROOT / "tests/ci/mac_runner.py"),
                                         str(record), str(local), str(runners), credentials],
                                        input=source, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                return result.stdout.strip()
            local.write_text(json.dumps(matching))
            self.assertEqual(step("true"), "deregister")
            # Changes during bootout must prevent the SDK's silent local-only removal.
            for changed, credentials in [(None, "true"), (matching, "false"), (dict(matching, agentId=8), "true")]:
                if changed is None:
                    local.unlink(missing_ok=True)
                else:
                    local.write_text(json.dumps(changed))
                self.assertEqual(step(credentials), "repair")
                self.assertEqual(record.read_bytes(), original)
            local.unlink()
            runners.write_text("[]")
            self.assertEqual(step("false"), "cleanup")
            record.unlink()
            self.assertEqual(step("false"), "repair")
        calls = [match.start() for match in re.finditer(re.escape('action=$(removal_decision "$stage")'), uninstall)]
        self.assertEqual(len(calls), 2)
        stop = uninstall.index('/bin/launchctl bootout', uninstall.index('case $action in'))
        self.assertLess(calls[0], stop)
        self.assertLess(stop, calls[1])
        self.assertLess(calls[1], uninstall.index('./config.sh remove --unattended'))

    def test_interrupted_removal_reinstall_and_missing_configuration(self):
        old = mac_runner.registration_record("old-host-rui", 7)
        self.assertEqual(mac_runner.removal_action(old, [{"id": 7, "name": "old-host-rui"}], None, False)[0], "repair")
        self.assertEqual(mac_runner.removal_action(old, [], None, False)[0], "cleanup")
        # A new registration replaces the old identity; a stale receipt cannot authorize cleanup.
        intent = mac_runner.registration_record("old-host-rui")
        fresh = mac_runner.registration_record("old-host-rui", 9)
        self.assertEqual(mac_runner.removal_action(intent, [{"id": 9, "name": "old-host-rui"}], None, False)[0], "repair")
        self.assertEqual(mac_runner.removal_action(fresh, [{"id": 9, "name": "old-host-rui"}], None, False)[0], "repair")
        for record, snapshot in [(None, []), (old, None), (old, [{}]), (old, [{"id": True, "name": "old-host-rui"}])]:
            self.assertEqual(mac_runner.removal_action(record, snapshot, None, False)[0], "repair")


class QueueSnapshotWorkflowTest(unittest.TestCase):
    def test_pagination_counts_and_failed_snapshot_cleanup(self):
        import http.server
        import textwrap
        import threading
        import urllib.parse

        workflow = (ROOT / ".github/workflows/check.yml").read_text()
        script = textwrap.dedent(re.search(
            r"      - name: Read the workflow queue snapshot\n.*?        run: \|\n(.*?)(?=      - name: Choose)",
            workflow, re.S).group(1))
        state = {"failure": None, "calls": [], "transition": False}

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                parsed = urllib.parse.urlparse(self.path)
                query = urllib.parse.parse_qs(parsed.query)
                state["calls"].append((parsed.path, query))
                if state["failure"] == "http" and parsed.path.endswith("/jobs"):
                    self.send_error(500)
                    return
                page = int(query["page"][0])
                if parsed.path.endswith("/runs"):
                    rows = ([{"id": i} for i in range(1, 102)] if query["status"] == ["queued"]
                            else ([{"id": 1}] if state["transition"] else []))
                    key = "workflow_runs"
                else:
                    run_id = int(parsed.path.split("/")[-2])
                    rows = ([{"labels": ["rui-mac", "macos-15"], "status": "queued"},
                             {"labels": ["macos-15"], "status": "in_progress"},
                             {"labels": ["rui-mac"], "status": "in_progress"},
                             {"labels": ["other"], "status": "queued"}]
                            + [{"labels": ["macos-15"], "status": "completed"}] * 100
                            if run_id == 1 else [])
                    key = "jobs"
                payload = {"total_count": len(rows), key: rows[(page - 1) * 100:page * 100]}
                if state["failure"] == "malformed" and parsed.path.endswith("/jobs"):
                    payload[key] = None
                data = json.dumps(payload).encode()
                self.send_response(200)
                self.end_headers()
                self.wfile.write(data)

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "queue.json"
                env = dict(os.environ, GITHUB_API_URL=f"http://127.0.0.1:{server.server_port}",
                           GITHUB_REPOSITORY="owner/repo", GH_TOKEN="test", QUEUE_PATH=str(path))
                def execute():
                    return subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script],
                                          env=env, capture_output=True, text=True)
                result = execute()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(path.read_text()),
                                 {"mac_queued": 1, "hosted_queued": 1, "hosted_running": 1})
                self.assertTrue(any(path_.endswith("/runs") and query["page"] == ["2"]
                                    for path_, query in state["calls"]))
                self.assertTrue(any(path_.endswith("/jobs") and query["page"] == ["2"]
                                    for path_, query in state["calls"]))
                state["transition"] = True
                state["calls"].clear()
                result = execute()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(path.read_text()),
                                 {"mac_queued": 1, "hosted_queued": 1, "hosted_running": 1})
                first_job_calls = [(path_, query) for path_, query in state["calls"]
                                   if path_.endswith("/runs/1/jobs") and query["page"] == ["1"]]
                self.assertEqual(len(first_job_calls), 1)
                for failure in ("http", "malformed"):
                    with self.subTest(failure=failure):
                        path.write_text("stale")
                        state["failure"] = failure
                        self.assertNotEqual(execute().returncode, 0)
                        self.assertFalse(path.exists())
                        self.assertFalse(Path(str(path) + ".tmp").exists())
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
