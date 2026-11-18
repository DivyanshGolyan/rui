from functools import cache
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import shlex
import unittest

import build_files
from select_tests import select
import steps
from strict_paths import STRICT, strict


ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / '.github/workflows/check.yml'
POLICY = ROOT / '.github/actions/policy/action.yml'
POLICY_CHECKS = ROOT / '.github/actions/policy/checks.sh'
UPGRADE = ROOT / '.github/workflows/previous-release-upgrade.yml'
PROMOTE = ROOT / '.github/workflows/promote.yml'
RELEASE = ROOT / '.github/workflows/release.yml'
RELEASE_BUILD = ROOT / '.github/workflows/release-build.yml'
RENDERER = ROOT / '.github/workflows/renderer-contracts.yml'
QUALIFIER = ROOT / '.github/workflows/main-qualifier.yml'
TIER = ROOT / '.github/workflows/qualification-tier.yml'


def job(text, name):
    match = re.search(rf'(?ms)^  {name}:\n(.*?)(?=^  [a-z_]+:|\Z)', text)
    if not match:
        raise AssertionError(f'missing job {name}')
    return match[1]


def permissions_of(body):
    block = body.split('\n    permissions:\n', 1)[1]
    return dict(re.findall(r'(?m)^      ([a-z-]+): (read|write)$', block.split('\n    uses:', 1)[0].split('\n    runs-on:', 1)[0]))


def step_script(text, name):
    marker = f'      - name: {name}\n'
    if marker not in text:
        raise AssertionError(f'missing step {name}')
    step = text.split(marker, 1)[1].split('\n      - ', 1)[0] + '\n'
    match = re.search(r'(?m)^        run: \|\n((?:          .*\n|\n)+)', step)
    if not match:
        raise AssertionError(f'missing shell for {name}')
    return textwrap.dedent(match[1])


def documentation_env():
    return dict(CHANGE_KIND='documentation', POLICY_RESULT='skipped', MACOS_RESULT='skipped',
                NATIVE='false', TARGETS='[]', NATIVE_TARGETS='[]',
                LINUX_MATRIX='{"include": []}', MACOS_MATRIX='{"include": []}',
                LINUX_SPLIT='false', MACOS_SPLIT='false', LINUX_MEMORY='false')


@cache
def plan_sources():
    names = ['tests/ci/' + name for name in (
        'select_tests.py', 'ci_plan.py', 'docs_only.py', 'qualification.py', 'strict_paths.py', 'platform_boundary.py',
        'import_architecture.py', 'build_files.py', 'release_numbers.py', 'stack_frames.json')]
    names += [path.relative_to(ROOT).as_posix() for path in build_files.files()]
    names += ['src/store/schema.zig']
    return {name: (ROOT / name).read_text() for name in names} | {
        'src/logic_tests.zig': 'const cores = .{\n    .{ "history_memo.zig", @import("history_memo.zig") },\n};\n',
        'src/history_memo.zig': '',
        'src/cli.zig': '',
        'src/store.zig': '',
        'src/tests.zig': '',
        'src/os/descriptor_limit.zig': '',
        'tests/integration/host_status_integration.py': 'import mysql_case\n',
        'tests/integration/mysql_case.py': 'import live_engines\nsocket = env.get(live_engines.MYSQL_SOCKET)\n',
        'tests/integration/live_engines.py': 'MYSQL_SOCKET = "RUI_TEST_MYSQL_SOCKET"\n',
    }


class PlanFixture:
    def __enter__(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.git('init', '-q', '-b', 'main')
        self.write('.git/info/exclude', 'selection.json\n__pycache__/\n')
        for name, source in plan_sources().items():
            self.write(name, source)
        self.write('README.md', 'Base. Another sentence on one line.\n')
        self.base = self.commit()
        return self

    def __exit__(self, *args):
        self.scratch.cleanup()

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.repo, stderr=subprocess.PIPE,
                                       text=True).strip()

    def write(self, name, content):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def commit(self):
        self.git('add', '-A')
        self.git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '--allow-empty', '-qm', 'fixture')
        return self.git('rev-parse', 'HEAD')

    def run(self, base=None, candidate=None, event='pull_request', draft=False, promotion=False, compile_only=False, native_targets=None):
        self.output = self.root / 'output'
        self.output.write_text('')
        script = step_script(job(CHECK.read_text(), 'plan'), 'Select existing targets')
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', BASE=base or self.base, DRAFT=str(draft).lower(), EVENT_NAME=event,
                   PROMOTION=str(promotion).lower(), COMPILE_ONLY=str(compile_only).lower(),
                   GITHUB_REF_NAME='5/merge', CANDIDATE_REF=candidate or self.git('rev-parse', 'HEAD'),
                   GITHUB_OUTPUT=str(self.output), GITHUB_STEP_SUMMARY=str(self.root / 'summary'),
                   NATIVE_TARGETS=json.dumps(native_targets) if native_targets is not None else '')
        return subprocess.run(['bash', '-c', script], cwd=self.repo, env=env,
                              capture_output=True, text=True)

    def plan(self, test, **kwargs):
        result = self.run(**kwargs)
        test.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return dict(line.split('=', 1) for line in self.output.read_text().splitlines())


class AdmissionTest(unittest.TestCase):
    def test_screen_check_is_selected_by_plan_and_precedes_acceptance(self):
        text = CHECK.read_text()
        plan = job(text, 'plan')
        admission = job(text, 'admission')
        self.assertIn('screens_required: ${{ steps.shape.outputs.screens_required }}', plan)
        self.assertIn('- name: Require PR Shape\n        id: shape', plan)
        self.assertIn('python3 tests/ci/pr_shape.py "$BASE"', plan)
        self.assertEqual(admission.count("if: ${{ needs.plan.outputs.screens_required == 'true' }}"), 2)
        self.assertIn('sparse-checkout: tests/ci', admission)
        self.assertIn('ref: ${{ needs.plan.outputs.candidate_ref }}', admission)
        self.assertIn('run: python3 tests/ci/pr_shape.py --screens', admission)
        self.assertLess(admission.index('- name: Require screen evidence'),
                        admission.index('- name: Require candidate acceptance'))
        for name in ('PR_BODY', 'PR_NUMBER', 'GITHUB_REPOSITORY', 'GH_TOKEN'):
            screen_step = admission.split('- name: Require screen evidence', 1)[1].split('\n      - ', 1)[0]
            self.assertIn(name + ':', screen_step)

    def test_cold_native_compile_budget_does_not_extend_runtime_deadlines(self):
        text = CHECK.read_text()

        def budget(body):
            return int(re.search(r'(?m)^    timeout-minutes: (\d+)$', body)[1])

        def step_budget(body, name):
            step = body.split(f'      - name: {name}\n', 1)[1].split('\n      - ', 1)[0]
            return int(re.search(r'(?m)^        timeout-minutes: (\d+)$', step)[1])

        release = RELEASE_BUILD.read_text()
        self.assertGreaterEqual(budget(job(text, 'linux_build')), budget(job(release, 'build')))
        self.assertGreaterEqual(budget(job(text, 'macos_build')), budget(job(release, 'build')))
        qualify = job((ROOT / '.github/workflows/qualify-macos.yml').read_text(), 'compile')
        self.assertIn("    timeout-minutes: ${{ needs.plan.outputs.platform == 'linux' && 15 || %d }}"
                      % budget(job(text, 'macos_build')), qualify)
        for name, step in (('linux_suites', 'Run selected targets'), ('macos_suites', 'Run required native targets')):
            self.assertIn('    timeout-minutes: ${{ inputs.promotion && 300 || 35 }}', job(text, name))
            self.assertEqual(step_budget(job(text, name), step), 35)
        upgrade = job(UPGRADE.read_text(), 'upgrade')
        self.assertIn("    timeout-minutes: ${{ inputs.batch-base && 300 || 45 }}", upgrade)
        self.assertEqual(step_budget(upgrade, 'Start detached, then install, save real work, reinstall and '
                                     'restart the same Store'), 45)
        self.assertEqual(budget(job(text, 'linux_build_unit')), 15)
        self.assertEqual(budget(job(text, 'macos_build_unit')), budget(job(text, 'macos_build')))

    def test_main_ruleset_requires_admission_and_prs_with_only_an_admin_pr_bypass(self):
        ruleset = json.loads((ROOT / '.github/main-ruleset.json').read_text())
        self.assertEqual(ruleset['target'], 'branch')
        self.assertEqual(ruleset['enforcement'], 'active')
        self.assertEqual(ruleset['bypass_actors'],
                         [{'actor_id': 5, 'actor_type': 'RepositoryRole', 'bypass_mode': 'pull_request'}])
        self.assertEqual(ruleset['conditions']['ref_name'], {'include': ['refs/heads/main'], 'exclude': []})
        rules = {rule['type']: rule for rule in ruleset['rules']}
        self.assertIn('pull_request', rules)
        self.assertIn('non_fast_forward', rules)
        self.assertIn('deletion', rules)
        checks = rules['required_status_checks']['parameters']
        self.assertFalse(checks['strict_required_status_checks_policy'])
        self.assertEqual(checks['required_status_checks'], [{'context': 'admission', 'integration_id': 15368}])

    def admission(self, **changes):
        env = dict(CHANGE_KIND='normal', DRAFT='false', PLAN_RESULT='success', POLICY_RESULT='success',
                   LINUX_RESULT='success', MACOS_RESULT='success', PR_JOB='false',
                   NATIVE='true', CACHE_SELECTED='false', CACHE_RESULT='skipped')
        env.update(changes)
        script = step_script(job(CHECK.read_text(), 'admission'), 'Require candidate acceptance')
        return subprocess.run(['bash', '-c', script], env=dict(os.environ, **env),
                              capture_output=True, text=True)

    def test_single_pr_job_admits_only_with_policy_folded_into_it(self):
        self.assertEqual(self.admission(PR_JOB='true', POLICY_RESULT='skipped', NATIVE='false',
                                        MACOS_RESULT='skipped').returncode, 0)
        for pr_job, policy in (('true', 'success'), ('true', 'failure'), ('false', 'skipped'),
                               ('', 'success'), ('unknown', 'skipped')):
            with self.subTest(pr_job=pr_job, policy=policy):
                self.assertNotEqual(self.admission(PR_JOB=pr_job, POLICY_RESULT=policy).returncode, 0)

    def test_all_green_and_only_unselected_cache_skip_pass(self):
        self.assertEqual(self.admission().returncode, 0)
        self.assertEqual(self.admission(CACHE_SELECTED='true', CACHE_RESULT='success').returncode, 0)

    def test_each_required_part_rejects_pending_cancelled_failed_skipped_or_missing(self):
        for part in ('PLAN_RESULT', 'POLICY_RESULT', 'LINUX_RESULT', 'MACOS_RESULT'):
            for result in ('queued', 'pending', 'in_progress', 'cancelled', 'failure', 'skipped', ''):
                with self.subTest(part=part, result=result):
                    self.assertNotEqual(self.admission(**{part: result}).returncode, 0)

    def test_draft_or_reduced_native_run_never_admits(self):
        for value in ('true', ''):
            self.assertNotEqual(self.admission(DRAFT=value).returncode, 0)
        for value in ('', 'unknown'):
            self.assertNotEqual(self.admission(NATIVE=value).returncode, 0)

    def test_mac_admits_only_its_exact_selection(self):
        for native in ('false', 'true'):
            env = dict(NATIVE=native, MACOS_RESULT='success' if native == 'true' else 'skipped')
            with self.subTest(native=native):
                self.assertEqual(self.admission(**env).returncode, 0)
            for result in ('success', 'skipped', 'failure', 'cancelled', 'in_progress', ''):
                if result == env['MACOS_RESULT']:
                    continue
                with self.subTest(native=native, result=result):
                    self.assertNotEqual(self.admission(**dict(env, MACOS_RESULT=result)).returncode, 0)

    def test_cache_selection_has_no_unknown_or_unexpected_skips(self):
        for selected, results in (
                ('true', ('skipped', 'cancelled', 'failure', 'queued', 'in_progress', '')),
                ('false', ('success', 'cancelled', 'failure', 'queued', 'in_progress', '')),
                ('', ('success', 'skipped')), ('unexpected', ('success', 'skipped'))):
            for result in results:
                with self.subTest(selected=selected, result=result):
                    self.assertNotEqual(self.admission(CACHE_SELECTED=selected, CACHE_RESULT=result).returncode, 0)

    def test_unknown_or_missing_kind_never_admits(self):
        for kind in ('', 'docs', 'NORMAL', 'unknown'):
            with self.subTest(kind=kind):
                self.assertNotEqual(self.admission(CHANGE_KIND=kind).returncode, 0)
                self.assertNotEqual(self.admission(**dict(documentation_env(), CHANGE_KIND=kind)).returncode, 0)

    def test_documentation_admission_rejects_every_inconsistent_control_or_result(self):
        env = documentation_env()
        self.assertEqual(self.admission(**env).returncode, 0)
        expected = dict(env, DRAFT='false', PLAN_RESULT='success', LINUX_RESULT='success',
                        CACHE_SELECTED='false', CACHE_RESULT='skipped')
        for key, good in expected.items():
            if key.endswith('_RESULT'):
                alternatives = ('success', 'skipped', 'failure', 'cancelled', 'queued', 'pending', 'in_progress', '')
            elif key in ('TARGETS', 'NATIVE_TARGETS'):
                alternatives = ('', '["check"]', '[ ]', 'null')
            elif key.endswith('_MATRIX'):
                alternatives = ('', '{}', '{"include": [{"targets": ["check"]}]}', 'null')
            else:
                alternatives = ('', 'true', 'false', 'unknown')
            for value in alternatives:
                if value == good:
                    continue
                with self.subTest(key=key, value=value):
                    self.assertNotEqual(self.admission(**dict(env, **{key: value})).returncode, 0)
        script = step_script(job(CHECK.read_text(), 'admission'), 'Require candidate acceptance')
        for key in expected:
            missing = dict(expected)
            del missing[key]
            with self.subTest(missing=key):
                self.assertNotEqual(subprocess.run(['bash', '-c', script], env=missing,
                    capture_output=True, text=True).returncode, 0)

    def test_documentation_linux_requires_exact_skips_and_controls(self):
        script = step_script(job(CHECK.read_text(), 'linux'), 'Require every selected Linux part')
        env = dict(DRAFT_RUN='false', CHANGE_KIND='documentation', PLAN_RESULT='success', POLICY_RESULT='skipped',
                   TARGETS='[]', COMPILE_TARGETS='[]', SPLIT='false', BUILD_RESULT='skipped',
                   UNIT_RESULT='skipped', NATIVE_RESULT='skipped', PR_JOB='false', PR_RESULT='skipped',
                   TYPECHECK='false', TYPECHECK_RESULT='skipped', COMPILE_ONLY='false')

        def run(values):
            return subprocess.run(['bash', '-euc', script], env=values,
                                  capture_output=True, text=True).returncode

        self.assertEqual(run(env), 0)
        for key, good in env.items():
            values = ('success', 'skipped', 'failure', 'cancelled', 'queued', 'pending', 'in_progress', '') if key.endswith('_RESULT') else ('', 'unknown', 'true', '["check"]')
            for value in values:
                if value == good or (key == 'DRAFT_RUN' and value == 'true'):
                    continue
                with self.subTest(key=key, value=value):
                    self.assertNotEqual(run(dict(env, **{key: value})), 0)
            missing = dict(env)
            del missing[key]
            with self.subTest(missing=key):
                self.assertNotEqual(run(missing), 0)

    def test_linux_legacy_default_cannot_admit_an_explicit_unknown_kind(self):
        script = step_script(job(CHECK.read_text(), 'linux'), 'Require every selected Linux part')
        env = dict(DRAFT_RUN='false', PLAN_RESULT='success', POLICY_RESULT='success', TARGETS='[]', COMPILE_TARGETS='[]', SPLIT='false',
                   BUILD_RESULT='skipped', UNIT_RESULT='skipped',
                   NATIVE_RESULT='skipped', TYPECHECK='false', TYPECHECK_RESULT='skipped',
                   PR_JOB='false', PR_RESULT='skipped', COMPILE_ONLY='false')
        self.assertEqual(subprocess.run(['bash', '-euc', script], env=env).returncode, 0)
        for kind in ('', 'docs', 'unknown'):
            with self.subTest(kind=kind):
                self.assertNotEqual(subprocess.run(['bash', '-euc', script],
                    env=dict(env, CHANGE_KIND=kind), capture_output=True).returncode, 0)

    def test_documentation_routing_is_plan_owned_without_new_heavy_checks(self):
        text = CHECK.read_text()
        policy = job(text, 'policy')
        self.assertIn('needs: plan', policy)
        self.assertIn("needs.plan.outputs.change_kind == 'normal'", policy)
        self.assertIn("needs.plan.outputs.draft_run == 'false'", policy)
        self.assertIn('draft_run: ${{ steps.select.outputs.draft_run }}', job(text, 'plan'))
        for name in ('policy', 'linux'):
            self.assertNotIn('github.event.pull_request.draft', job(text, name))
        for name in ('macos_build', 'macos_suites', 'macos'):
            self.assertIn("needs.plan.outputs.native == 'true'", job(text, name))
        for name in ('plan', 'linux', 'admission'):
            body = job(text, name)
            for forbidden in ('sentence_lines', 'pip install', 'npm ', 'actions/setup-node',
                              'uses: ./.github/actions/setup', 'actionlint', 'unittest discover'):
                self.assertNotIn(forbidden, body)
        self.assertNotIn('paths-ignore', text)

    def test_policy_runs_live_client_locality_with_trusted_main_history(self):
        for name in ('policy', 'pr_linux'):
            self.assertIn('fetch-depth: 0', job(CHECK.read_text(), name))
        self.assertIn('uses: ./.github/actions/policy\n', job(CHECK.read_text(), 'policy'))
        self.assertIn('      run: bash .github/actions/policy/checks.sh\n', POLICY.read_text())
        self.assertIn('bash .github/actions/policy/checks.sh', job(CHECK.read_text(), 'pr_linux'))
        self.assertIn(' python3 -B tests/ci/client_locality.py\n', POLICY_CHECKS.read_text())

    def test_single_pr_job_runs_policy_beside_compile_and_reports_it_after_the_tests(self):
        body = job(CHECK.read_text(), 'pr_linux')
        steps = re.findall(r'(?m)^      - (?:name: (.+)$|uses: (\S+))', body)
        names = [name or uses.split('@')[0] for name, uses in steps]
        self.assertEqual(names, [
            'actions/checkout', './.github/actions/setup',
            'Install the pinned packages tests/ci imports', 'actions/setup-node', 'actions/cache',
            'Install the pinned workflow linter',
            'Start the policy checks beside the compile',
            'Check formatting',
            'Compile only the binaries the selected targets need',
            'Give tests macOS\'s temporary directory shape',
            'Run selected targets on SQLite, stopping at the first failure',
            'Retain bounded failed-fixture diagnostics',
            'Report the policy checks that ran beside the compile',
            'Fail for the policy or format checks that failed above',
        ])
        start = body.split('      - name: Start the policy checks beside the compile\n', 1)[1].split('\n      - ', 1)[0]
        self.assertIn('( nice -n 10 bash .github/actions/policy/checks.sh > "$RUNNER_TEMP/policy.log" 2>&1', start)
        self.assertIn('echo $? > "$RUNNER_TEMP/policy.status" ) &', start)
        self.assertNotIn('continue-on-error', start)
        report = body.split('      - name: Report the policy checks that ran beside the compile\n', 1)[1].split('\n      - ', 1)[0]
        for line in ('id: policy', "if: ${{ !cancelled() }}", 'continue-on-error: true',
                     'cat "$RUNNER_TEMP/policy.log"', 'exit "$(cat "$RUNNER_TEMP/policy.status")"'):
            self.assertIn(line, report)
        final = body.split('      - name: Fail for the policy or format checks that failed above\n', 1)[1]
        self.assertIn("steps.policy.outcome == 'failure' || steps.format.outcome == 'failure'", final)
        self.assertNotIn('continue-on-error', final)

    def test_policy_checks_all_run_after_a_failure_and_the_script_fails_naming_it(self):
        names = ["Check caller error coverage and shrink-only pending causes",
                 "Check flake sources and shrink-only allowances",
                 "Check client locality and shrink-only exceptions",
                 "Run tests/ci, less self-checks whose inputs are unchanged",
                 "Reject undefined fixture names before native builds",
                 "Check the TypeScript client's generated wire types and type-check it",
                 "Validate workflows with pinned-linter compatibility exceptions"]
        for failing in (None, 1, 5, 6):
            with self.subTest(failing=failing), tempfile.TemporaryDirectory() as root:
                root = Path(root)
                (root / 'bin').mkdir()
                (root / 'clients/ts').mkdir(parents=True)
                (root / '.github/workflows').mkdir(parents=True)
                (root / '.github/workflows/check.yml').write_text('on: push\n')
                (root / 'actionlint').mkdir()
                marker = {1: 'flake_sources', 5: 'npm', 6: 'actionlint'}.get(failing, 'never')
                for tool in ('python3', 'npm', 'actionlint/actionlint'):
                    fake = root / ('bin/' + tool if '/' not in tool else tool)
                    fake.write_text('#!/bin/sh\necho "$0 $*" >> "$CALLS"\n'
                                    f'case "$0 $*" in *{marker}*) exit 3;; esac\nexit 0\n')
                    fake.chmod(0o755)
                result = subprocess.run(['bash', str(POLICY_CHECKS)], cwd=root, capture_output=True, text=True,
                                        env=dict(os.environ, PATH=f"{root / 'bin'}:{os.environ['PATH']}",
                                                 RUNNER_TEMP=str(root), SKIPS='[]', CALLS=str(root / 'calls')))
                for name in names:
                    self.assertEqual(result.stdout.count(f"{name}: exit "), 1, name)
                if failing is None:
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                else:
                    self.assertEqual(result.returncode, 1)
                    self.assertIn(f"{names[failing]}: exit 3", result.stdout)
                    self.assertIn(f"Policy checks failed: {names[failing]}", result.stdout)

    def test_policy_skips_only_the_named_unchanged_self_checks(self):
        script = 'python3 -B tests/ci/policy_suite.py --skips "$SKIPS"'
        self.assertIn(' ' + script + '\n', POLICY_CHECKS.read_text())
        self.assertIn('        SKIPS: ${{ inputs.skips }}\n', POLICY.read_text())
        self.assertIn('skips: ${{ needs.plan.outputs.policy_skips }}', job(CHECK.read_text(), 'policy'))
        self.assertIn('SKIPS: ${{ needs.plan.outputs.policy_skips }}', job(CHECK.read_text(), 'pr_linux'))
        modules = {
            'test_alpha': 'class Alpha(unittest.TestCase):\n    def test_one(self): pass\n    def test_two(self): pass\n',
            'test_beta': ('class Kept(unittest.TestCase):\n    def test_kept(self): pass\n'
                          'class Skipped(unittest.TestCase):\n    def test_skipped(self): self.fail()\n'),
            'test_gamma': 'class Gamma(unittest.TestCase):\n    def test_gamma(self): self.fail()\n',
            'test_gamma_more': 'class More(unittest.TestCase):\n    def test_more(self): pass\n',
        }
        with tempfile.TemporaryDirectory() as root:
            Path(root, 'tests/ci').mkdir(parents=True)
            Path(root, 'tests/ci/policy_suite.py').write_text((ROOT / 'tests/ci/policy_suite.py').read_text())
            for name, body in modules.items():
                path = Path(root, 'tests/ci', name + '.py')
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('import unittest\n' + body)

            def run(skips):
                return subprocess.run(['bash', '-euc', script], cwd=root, capture_output=True, text=True,
                                      env=dict(os.environ, SKIPS=json.dumps(skips)))
            passed = run(['test_beta.Skipped', 'test_gamma'])
            self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
            ran = set(re.findall(r'^(test_\w+) \(', passed.stderr, re.M))
            self.assertEqual(ran, {'test_one', 'test_two', 'test_kept', 'test_more'})
            for skips in ([], ['test_beta.Skipped'], ['test_gamma'], ['test_beta.Kept', 'test_gamma']):
                with self.subTest(skips=skips):
                    self.assertNotEqual(run(skips).returncode, 0)

    def test_admission_always_runs_for_every_pr_and_waits_for_required_parts(self):
        text = job(CHECK.read_text(), 'admission')
        self.assertIn("if: ${{ always() && github.event_name == 'pull_request' }}", text)
        required = ('plan', 'policy', 'linux', 'macos', 'cache_execution')
        needs = re.search(r'(?m)^    needs: \[(.*?)\]$', text)[1].split(', ')
        self.assertCountEqual(needs, required)
        for name in required:
            self.assertIn('${{ needs.' + name + '.result }}', text)
        self.assertIn('${{ github.event.pull_request.draft }}', text)

    def test_native_aggregate_requires_real_producers_and_every_suite(self):
        script = step_script(job(CHECK.read_text(), 'macos'), 'Require every selected Apple Silicon part')
        baseline = dict(PLAN_RESULT='success', BUILD_RESULT='success', UNIT_RESULT='skipped',
                        SPLIT='false', NATIVE_RESULT='success')
        for split in ('false', 'true'):
            env = dict(baseline, SPLIT=split, UNIT_RESULT='success' if split == 'true' else 'skipped')
            self.assertEqual(subprocess.run(['bash', '-euc', script], env=env).returncode, 0)
            for key in ('PLAN_RESULT', 'BUILD_RESULT', 'NATIVE_RESULT', 'UNIT_RESULT'):
                for result in ('failure', 'cancelled', 'in_progress', ''):
                    with self.subTest(split=split, key=key, result=result):
                        self.assertNotEqual(subprocess.run(['bash', '-euc', script],
                            env=dict(env, **{key: result})).returncode, 0)
            if split == 'true':
                self.assertNotEqual(subprocess.run(['bash', '-euc', script],
                    env=dict(env, UNIT_RESULT='skipped')).returncode, 0)

    def test_all_selected_checkouts_use_the_immutable_candidate(self):
        text = CHECK.read_text()
        jobs = re.findall(r'(?m)^  ([a-z_]+):$', text.split('\njobs:', 1)[1])
        for name in jobs:
            body = job(text, name)
            checkouts = re.findall(r'(?ms)^      - uses: actions/checkout@.*?(?=^      - |\Z)', body)
            for checkout in checkouts:
                with self.subTest(job=name):
                    expected = '${{ github.sha }}' if name in ('plan', 'policy', 'mac_runner') else '${{ needs.plan.outputs.candidate_ref }}'
                    self.assertIn('ref: ' + expected, checkout)
        self.assertIn('candidate_ref: ${{ steps.select.outputs.candidate_ref }}', job(text, 'plan'))
        self.assertIn('CANDIDATE_REF: ${{ github.sha }}', job(text, 'plan'))
        self.assertNotIn('refs/pull/', text)

    def test_upgrade_runs_both_platforms_in_promotion_and_never_on_prs(self):
        self.assertNotIn('uses: ./.github/workflows/previous-release-upgrade.yml', CHECK.read_text())
        promotion = job(TIER.read_text(), 'upgrade')
        self.assertIn('uses: ./.github/workflows/previous-release-upgrade.yml', promotion)
        text = UPGRADE.read_text()
        self.assertNotIn('pull_request', text)
        self.assertIn('  workflow_call:', text)
        self.assertIn('      candidate-ref:', text)
        upgrade = job(text, 'upgrade')
        self.assertIn('os: [ubuntu-24.04, macos-15]', upgrade)
        self.assertIn('ref: ${{ inputs.candidate-ref || github.sha }}', upgrade)
        self.assertIn('python3 -B tests/integration/previous_release_upgrade.py "$RUNNER_TEMP/previous-release" .', upgrade)
        script = step_script(upgrade, 'Validate immutable candidate')
        for value, success in (('a' * 40, True), ('refs/pull/5/merge', False), ('main', False), ('', False)):
            with self.subTest(candidate=value):
                result = subprocess.run(['bash', '-c', script], env=dict(os.environ, CANDIDATE_REF=value))
                self.assertEqual(result.returncode == 0, success)


class StrictPathTest(unittest.TestCase):
    def test_strict_patterns_match_like_github_path_filters(self):
        self.assertEqual(strict([
            'src/store.zig', 'src/server.zig', 'src/execution_turn.zig', 'build.zig', 'build.zig.zon',
            'src/server_execution.zig', 'src/server_host.zig',
            'install.sh', 'tests/integration/bash_integration.py', 'tests/integration/bash_recovery_integration.py',
            'src/cli.zig', 'src/store/Store.zig', 'src/store/domain/turn.zig', 'src/store/domain/x/y.zig',
            'tests/integration/host_process.py', 'build.zig.bak', 'docs/install.sh']), [
            'build.zig', 'build.zig.zon', 'install.sh', 'src/execution_turn.zig', 'src/server.zig',
            'src/server_execution.zig', 'src/server_host.zig',
            'src/store.zig', 'src/store/Store.zig', 'src/store/domain/turn.zig', 'src/store/domain/x/y.zig',
            'tests/integration/bash_integration.py', 'tests/integration/bash_recovery_integration.py'])

    def test_selected_runs_mac_for_every_strict_path(self):
        available = set(build_files.steps())
        for pattern in STRICT:
            path = pattern.replace('*', '_x')
            self.assertEqual(strict([path]), [path])
            self.assertTrue(select([path], 'review', available)['native_required'], path)

class CandidatePlanTest(unittest.TestCase):
    def test_plan_input_snapshot_is_shared_but_worktrees_are_isolated(self):
        self.assertIs(plan_sources(), plan_sources())
        self.assertLess(sum(name.startswith(("src/", "tests/integration/")) for name in plan_sources()), 20)
        with PlanFixture() as first, PlanFixture() as second:
            first.write('src/history_memo.zig', 'changed in first fixture\n')
            self.assertEqual((second.repo / 'src/history_memo.zig').read_text(), '')
            self.assertEqual(plan_sources()['src/history_memo.zig'], '')

    def test_ready_prs_run_the_upgrade_only_for_what_it_exercises(self):
        available = set(build_files.steps())
        for path, required in (('src/store/schema.zig', True), ('src/upgrade_process.zig', True),
                               ('install.sh', True), ('build.zig', True),
                               ('.github/workflows/previous-release-upgrade.yml', True),
                               ('src/cli.zig', False), ('src/Overview.zig', False), ('src/store/Store.zig', False),
                               ('tests/ci/release.py', False), ('README.md', False)):
            with self.subTest(path=path):
                self.assertEqual(select([path], 'review', available)['upgrade_required'], required)
                self.assertFalse(select([path], 'development', available)['upgrade_required'])
        for path in ('tests/ci/test_previous_release_upgrade.py', '.github/workflows/cache-maintenance.yml'):
            with self.subTest(path=path):
                self.assertFalse(select([path], 'review', available)['upgrade_required'])

    def test_schema_edits_run_the_upgrade_only_when_the_store_format_changes(self):
        available = set(build_files.steps())
        schema = 'src/store/schema.zig'
        source = (ROOT / schema).read_text()
        version = int(re.search(r'^pub const schema_version: u32 = (\d+);$', source, re.M)[1])
        last_row = re.findall(r'\.\{ \.schema_version = \d+, \.digest = 0x[0-9a-f]+ \},\n', source)[-1]
        bumped = (source.replace(f'schema_version: u32 = {version};', f'schema_version: u32 = {version + 1};')
                  .replace(last_row, last_row + f'    .{{ .schema_version = {version + 1}, .digest = 0x0123456789abcdef }},\n'))
        for after, required in (
                ('const unused = @import("std");\n' + source, False),
                (source.replace('/// `digest()` of each', '/// The `digest()` of each'), False),
                (bumped, True),
                (source.replace(last_row, last_row.replace('.digest = 0x', '.digest = 0x1')), True),
                (None, True)):
            with self.subTest(required=required):
                self.assertEqual(select([schema], 'review', available, contents={schema: (source, after)})
                                 ['upgrade_required'], required)

    def test_plan_reads_the_store_format_from_both_revisions(self):
        schema = 'src/store/schema.zig'
        source = (ROOT / schema).read_text()
        for after, upgrade in (('const unused = @import("std");\n' + source, 'false'),
                               (source.replace('.digest = 0x', '.digest = 0x1', 1), 'true')):
            with self.subTest(upgrade=upgrade), PlanFixture() as fixture:
                fixture.write(schema, after)
                output = fixture.plan(self, candidate=fixture.commit())
                self.assertIn(f'"upgrade_required": {upgrade}', (fixture.root / 'summary').read_text())
                self.assertEqual(set(json.loads(output['linux_compile_targets'])) - set(json.loads(output['targets'])), {'test'})
                self.assertIn('test-store', json.loads(output['targets']))
                self.assertNotIn('test', json.loads(output['targets']))

    def assert_documentation_plan(self, output):
        self.assertEqual(output['change_kind'], 'documentation')
        self.assert_quick_plan(output)

    def assert_quick_plan(self, output):
        for key in ('targets', 'native_targets'):
            self.assertEqual(output[key], '[]', key)
        for key in ('linux_matrix', 'macos_matrix'):
            self.assertEqual(output[key], '{"include": []}', key)
        for key in ('native', 'retry', 'linux_split', 'macos_split',
                    'linux_memory', 'cache_execution', 'typecheck_macos'):
            self.assertEqual(output[key], 'false', key)

    # CI-1: written as literals, independent of select_tests' tier constants.
    PR_TIER_NEVER = {'check', 'check-full', 'test', 'test-full', 'stack-frames', 'mysql-wire-integration'}
    # Unit roots the diff reaches, plus fixtures whose own script, executable or owner changed.
    PR_TIER_CASES = {
        'documentation': (['README.md'], set()),
        'tests/ci only': (['tests/ci/select_tests.py'], set()),
        'unreached source': (['src/future_owner.zig'], {'test-logic', 'test-native'}),
        'build hub': (['build.zig'], {'test-logic'}),
        'compiler and cache setup': (['.github/actions/setup/action.yml'], {'test-logic'}),
        'CI artifact producer': (['tests/ci/build_artifact.py'], {'test-logic'}),
        'dependency pins': (['build.zig.zon', 'src/fetch_dependencies.sh'], {'test-logic'}),
        'workflow and policy only': (['.github/workflows/check.yml', '.github/actions/policy/action.yml',
                                      'tests/ci/ci_plan.py'], set()),
        'producer and documentation': (['tests/ci/build_artifact.py', 'docs/verification/gates.md'], {'test-logic'}),
        'producer and core source': (['tests/ci/build_artifact.py', 'src/request_encoding.zig'],
                                     {'test-logic', 'test-native'}),
        'Store': (['src/store.zig'], {'test-native', 'test-store'}),
        'fixture script': (['tests/integration/overview_integration.py'], {'overview-integration'}),
        'slow fixture owner': (['src/Upgrade.zig'], {'upgrade-integration'}),
        'core owning no fixture': (['src/request_encoding.zig'], {'test-logic', 'test-native'}),
        'core owning one fixture': (['src/session_skills.zig'], {'skills-integration', 'test-logic', 'test-native'}),
        'core owning many fixtures (Mac path)': (['src/client.zig'], {
            'activity-integration', 'admission-integration', 'control-integration', 'conversation-page-integration',
            'host-status-integration', 'host-stop-integration', 'human-cli-integration', 'request-wait-integration',
            'session-list-integration', 'test-logic', 'test-native'}),
    }

    def test_ready_candidate_runs_its_pr_tier_and_promotion_the_full_selection(self):
        from ci_plan import plan
        from docs_only import ChangeKind
        available = set(build_files.steps())
        for name, (paths, expected) in self.PR_TIER_CASES.items():
            with self.subTest(case=name):
                selected = select(paths, 'review', available)

                kind = ChangeKind.DOCUMENTATION if name == 'documentation' else ChangeKind.NORMAL

                def run(event, draft=False, promotion=False):
                    return plan(selected, event_name=event, draft=draft, promotion=promotion,
                                change_kind=kind).outputs
                ready = run('pull_request')
                self.assertEqual(set(ready['targets']), expected)
                self.assertFalse(set(ready['targets']) & self.PR_TIER_NEVER)
                self.assertEqual(ready['pr_job'], name != 'documentation', 'every ready normal PR is one job')
                self.assertEqual(ready['linux_matrix'], {'include': []})
                self.assertEqual(run('pull_request', draft=True)['targets'], [])
                self.assertEqual(run('workflow_dispatch')['targets'], selected['targets'])
                promoted = set(run('workflow_dispatch', promotion=True)['targets'])
                self.assertLessEqual({'check-full', 'test-logic', 'admission-debug-integration', 'stack-frames'}, promoted)
                from select_tests import covers
                self.assertEqual([t for t in selected['targets'] if not covers(t, promoted)], [])

    def test_executed_plan_uses_pinned_tree_and_recomputes_after_base_change(self):
        with PlanFixture() as fixture:
            fixture.write('src/history_memo.zig', 'changed owner\n')
            retarget = fixture.commit()
            fixture.write('README.md', 'Candidate. Same line.\n')
            candidate = fixture.commit()
            mixed = fixture.plan(self, base=fixture.base, candidate=candidate)
            docs = fixture.plan(self, base=retarget, candidate=candidate)
            self.assert_documentation_plan(docs)
            self.assertEqual(mixed['change_kind'], 'normal')
            self.assertEqual(mixed['native'], 'false')
            self.assertEqual(mixed['retry'], 'false')
            self.assertIn('test-logic', json.loads(mixed['targets']))
            self.assertNotEqual(mixed['targets'], docs['targets'])
            self.assertEqual(fixture.plan(self, base=fixture.base, candidate=candidate), mixed)
            fixture.git('checkout', '-q', '--detach', retarget)
            self.assertNotEqual(fixture.run(candidate=candidate).returncode, 0)

    def test_pr_plan_diffs_the_merge_commit_against_the_main_it_merged(self):
        pr_base = re.search(r"(?m)^          BASE: \$\{\{ github\.event_name == 'pull_request' && '([^']+)' \|\| inputs\.base \}\}$",
                            job(CHECK.read_text(), 'plan'))[1]
        with PlanFixture() as fixture:
            stale = fixture.base
            fixture.write('src/history_memo.zig', 'changed on main\n')
            main = fixture.commit()
            fixture.git('checkout', '-q', '-b', 'pr', stale)
            fixture.write('README.md', 'Candidate. Same line.\n')
            fixture.commit()
            fixture.git('checkout', '-q', '--detach', main)
            fixture.git('-c', 'user.name=t', '-c', 'user.email=t@t', 'merge', '-q', '--no-ff', '-m', 'merge', 'pr')
            self.assertEqual(fixture.plan(self, base=stale)['change_kind'], 'normal')
            self.assert_documentation_plan(fixture.plan(self, base=pr_base))

    def test_manual_native_targets_reach_existing_producers_and_matrix(self):
        with PlanFixture() as fixture:
            output = fixture.plan(self, event='workflow_dispatch', native_targets=['test-logic'])
            self.assertEqual(json.loads(output['native_targets']), ['test-logic'])
            self.assertEqual(output['native'], 'true')
            self.assertEqual(output['retry'], 'false')
            self.assertEqual(output['quarantine'], 'off')
            [row] = json.loads(output['macos_matrix'])['include']
            self.assertEqual(row['targets'], ['test-logic'])
            self.assertEqual(row['part'], 'all')

    def test_plan_step_serializes_the_value_owners_result(self):
        with PlanFixture() as fixture:
            fixture.write('tests/ci/ci_plan.py', """from types import SimpleNamespace

def plan(selection, *, event_name, draft, promotion, change_kind, compile_only):
    return SimpleNamespace(outputs=dict(owner='called', event=event_name, draft=draft,
        promotion=promotion, kind=change_kind.value, base=selection['base'], compile_only=compile_only),
        selection=dict(summary='from owner'))
""")
            candidate = fixture.commit()
            output = fixture.plan(self, candidate=candidate, draft=True)
            self.assertEqual(output, dict(owner='called', event='pull_request', draft='true',
                promotion='false', kind='normal', base=fixture.base, compile_only='false',
                candidate_ref=candidate))
            built = fixture.plan(self, candidate=candidate, event='push', compile_only=True)
            self.assertEqual((built['event'], built['compile_only']), ('push', 'true'))
            summary = (fixture.root / 'summary').read_text()
            self.assertIn('"summary": "from owner"', summary)

    def test_plan_checks_whitespace_and_invalid_base(self):
        with PlanFixture() as fixture:
            fixture.write('README.md', 'Trailing whitespace.  \n')
            candidate = fixture.commit()
            failed = fixture.run(candidate=candidate)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn('trailing whitespace', failed.stdout)
            self.assertNotEqual(fixture.run(base='missing-ref', candidate=candidate).returncode, 0)

    def test_empty_deleted_and_asset_classification(self):
        with PlanFixture() as fixture:
            empty = fixture.plan(self)
            self.assertEqual(empty['change_kind'], 'normal')
            self.assertEqual(empty['native'], 'false')
            (fixture.repo / 'README.md').unlink()
            deleted = fixture.commit()
            self.assert_documentation_plan(fixture.plan(self, candidate=deleted))
            fixture.git('reset', '--hard', fixture.base)
            fixture.write('docs/images/screen.png', 'asset\n')
            asset = fixture.commit()
            output = fixture.plan(self, candidate=asset)
            self.assert_documentation_plan(output)

    def test_documentation_plan_flows_through_real_linux_and_admission_scripts(self):
        workflow = CHECK.read_text()
        linux = step_script(job(workflow, 'linux'), 'Require every selected Linux part')
        admission = step_script(job(workflow, 'admission'), 'Require candidate acceptance')
        with PlanFixture() as fixture:
            fixture.write('README.md', 'First sentence. Second sentence.\n')
            candidate = fixture.commit()
            output = fixture.plan(self, candidate=candidate)
            results = dict(plan='success', policy='skipped', linux='success', macos='skipped',
                           cache_execution='skipped', pr_linux='skipped',
                           linux_build='skipped', linux_build_unit='skipped',
                           linux_suites='skipped', macos_typecheck='skipped')
            for name, script in (('linux', linux), ('admission', admission)):
                result = self.aggregate(workflow, name, script, output, results)
                self.assertEqual(result.returncode, 0, result.stderr)

    @staticmethod
    def aggregate(workflow, name, script, output, results, draft=False):
        env = {}
        body = job(workflow, name)
        if name == 'admission':
            body = body.split('      - name: Require candidate acceptance\n', 1)[1].split('\n      - ', 1)[0]
        for key, expression in re.findall(r'(?m)^          ([A-Z_]+): \$\{\{ (.*?) \}\}$', body):
            if expression.startswith('needs.plan.outputs.'):
                env[key] = output[expression.removeprefix('needs.plan.outputs.')]
            elif expression == 'github.event.pull_request.draft':
                env[key] = str(draft).lower()
            elif expression == 'github.token':
                continue
            else:
                env[key] = results[expression.split('.')[1]]
        assert env
        return subprocess.run(['bash', '-euc', script], env=env, capture_output=True, text=True)

    def test_draft_quick_plan_cannot_replace_ready_acceptance(self):
        workflow = CHECK.read_text()
        linux = step_script(job(workflow, 'linux'), 'Require every selected Linux part')
        admission = step_script(job(workflow, 'admission'), 'Require candidate acceptance')
        path = 'build.zig'
        with PlanFixture() as fixture:
            before = (fixture.repo / path).read_text() if (fixture.repo / path).exists() else ''
            fixture.write(path, before + '\n// fixture change\n')
            candidate = fixture.commit()
            draft = fixture.plan(self, candidate=candidate, draft=True)
            self.assertEqual(draft['change_kind'], 'normal')
            self.assertEqual(draft['draft_run'], 'true')
            self.assert_quick_plan(draft)
            results = {name: 'skipped' for name in (
                'policy', 'macos', 'cache_execution', 'pr_linux',
                'linux_build', 'linux_build_unit', 'linux_suites', 'macos_typecheck')}
            results.update(plan='success', linux='success')
            self.assertEqual(self.aggregate(workflow, 'linux', linux, draft, results, draft=True).returncode, 0)
            refused = self.aggregate(workflow, 'admission', admission, draft, results, draft=True)
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn('A draft never admits', refused.stdout)
            ready = fixture.plan(self, candidate=candidate)
            self.assertEqual(ready['change_kind'], 'normal')
            self.assertEqual(ready['draft_run'], 'false')
            self.assertTrue(json.loads(ready['targets']))
            self.assertEqual(ready['pr_job'], 'true')
            selected = dict(results, pr_linux='success')
            self.assertEqual(self.aggregate(workflow, 'linux', linux, ready, selected).returncode, 0)
            for part in ('pr_linux',):
                for value in ('skipped', 'failure', 'cancelled'):
                    with self.subTest(part=part, value=value):
                        self.assertNotEqual(self.aggregate(workflow, 'linux', linux, ready,
                            dict(selected, **{part: value})).returncode, 0)
            for part in ('policy', 'linux_build', 'linux_build_unit', 'linux_suites', 'macos_typecheck'):
                with self.subTest(ran_beside_the_single_job=part):
                    self.assertNotEqual(self.aggregate(workflow, 'linux', linux, ready,
                        dict(selected, **{part: 'success'})).returncode, 0)
            accepted = dict(selected,
                macos='success' if ready['native'] == 'true' else 'skipped',
                cache_execution='success' if ready['cache_execution'] == 'true' else 'skipped')
            result = self.aggregate(workflow, 'admission', admission, ready, accepted)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotEqual(self.aggregate(workflow, 'admission', admission, draft, results).returncode, 0)

    def test_a_branch_that_merged_main_gets_only_its_own_diffs_pr_tier(self):
        workflow = CHECK.read_text()
        linux = step_script(job(workflow, 'linux'), 'Require every selected Linux part')
        with PlanFixture() as fixture:
            fixture.git('checkout', '-qb', 'feature')
            fixture.write('README.md', 'Feature documentation.\n')
            fixture.commit()
            fixture.git('checkout', '-q', 'main')
            fixture.write('src/history_memo.zig', 'const new_main = true;\n')
            main = fixture.commit()
            fixture.git('checkout', '-q', 'feature')
            fixture.git('-c', 'user.name=t', '-c', 'user.email=t@t', 'merge', '--no-ff', '-qm', 'integrate main', 'main')
            branch = fixture.git('rev-parse', 'HEAD')
            fixture.git('checkout', '-qb', 'candidate', 'main')
            fixture.git('-c', 'user.name=t', '-c', 'user.email=t@t', 'merge', '--no-ff', '-qm', 'candidate merge', 'feature')
            candidate = fixture.git('rev-parse', 'HEAD')
            self.assertEqual(fixture.git('rev-parse', 'HEAD^1'), main)
            self.assertEqual(fixture.git('rev-parse', 'HEAD^2'), branch)
            output = fixture.plan(self, base=main, candidate=candidate)
            # The PR tier no longer compiles every unit partition for a branch that merged
            # main: the candidate gets only what its own diff selects (here, documentation).
            self.assertEqual(output['candidate_ref'], candidate)
            self.assertEqual(output['change_kind'], 'documentation')
            self.assertEqual(json.loads(output['targets']), [])
            self.assertEqual(json.loads(output['linux_compile_targets']), [])
            self.assertEqual(output['pr_job'], 'false')
            self.assertEqual(json.loads(output['pr_setup_targets']), [])
            self.assertEqual(output['linux_matrix'], '{"include": []}')
            results = dict(plan='success', policy='skipped', pr_linux='skipped', linux_build='skipped',
                           linux_build_unit='skipped', linux_suites='skipped', macos_typecheck='skipped')
            self.assertEqual(self.aggregate(workflow, 'linux', linux, output, results).returncode, 0)
            self.assertNotEqual(self.aggregate(workflow, 'linux', linux, output,
                dict(results, pr_linux='success')).returncode, 0)

    def test_linux_suite_scheduling_uses_execution_not_compile_selection(self):
        from ci_plan import plan
        from docs_only import ChangeKind
        from types import SimpleNamespace
        expression = re.search(r"(?m)^    if: \$\{\{ (.*) \}\}$", job(CHECK.read_text(), 'linux_suites'))[1]
        expression = expression.replace('&&', 'and').replace('||', 'or').replace('!cancelled()', 'not cancelled()')
        for targets in ([], ['test-native']):
            for required in (False, True):
                source = dict(select([], 'review', set(build_files.steps())), targets=targets,
                              fast_targets=targets, unit_compile_required=required)
                # Shards serve every non-PR run; a ready PR runs its single job instead.
                ready = plan(source, event_name='pull_request', draft=False,
                             promotion=False, change_kind=ChangeKind.NORMAL).outputs
                self.assertTrue(ready['pr_job'])
                output = plan(source, event_name='workflow_dispatch', draft=False,
                              promotion=False, change_kind=ChangeKind.NORMAL).outputs
                encoded = {key: json.dumps(value) if not isinstance(value, str) else value
                           for key, value in output.items()}
                for build in ('success', 'skipped', 'failure'):
                    for unit in ('success', 'skipped', 'failure'):
                        for cancelled in (False, True):
                            with self.subTest(targets=targets, required=required, build=build,
                                              unit=unit, cancelled=cancelled):
                                needs = SimpleNamespace(plan=SimpleNamespace(outputs=SimpleNamespace(**encoded)),
                                    linux_build=SimpleNamespace(result=build),
                                    linux_build_unit=SimpleNamespace(result=unit))
                                scheduled = eval(expression, {'__builtins__': {}, 'needs': needs,
                                    'cancelled': lambda: cancelled, 'contains': lambda values, value: value in values,
                                    'fromJSON': json.loads})
                                self.assertEqual(scheduled, bool(targets) and not cancelled
                                                 and build == 'success' and unit in ('success', 'skipped'))

    def test_linux_producer_and_restore_share_compile_identity_not_execution_targets(self):
        workflow = CHECK.read_text()
        for name in ('linux_build', 'linux_build_unit'):
            self.assertIn('TARGETS: ${{ needs.plan.outputs.linux_compile_targets }}', job(workflow, name))
        suites = job(workflow, 'linux_suites')
        restore = suites.split('- name: Use the verified producer artifact or compile locally', 1)[1].split('      - ', 1)[0]
        self.assertIn('TARGETS: ${{ needs.plan.outputs.linux_compile_targets }}', restore)
        self.assertIn('TARGETS: ${{ toJSON(matrix.targets) }}', suites)

    def test_compile_only_plan_flows_through_the_real_linux_aggregate(self):
        workflow = CHECK.read_text()
        linux = step_script(job(workflow, 'linux'), 'Require every selected Linux part')
        with PlanFixture() as fixture:
            fixture.write('README.md', 'Main moved. Same line.\n')
            candidate = fixture.commit()
            output = fixture.plan(self, candidate=candidate, event='push', compile_only=True)
            self.assertEqual(output['compile_only'], 'true')
            self.assertEqual(json.loads(output['targets']), ['check', 'test-logic'])
            built = {name: 'skipped' for name in ('policy', 'macos', 'cache_execution', 'linux_suites', 'pr_linux')}
            built.update(plan='success', linux_build='success', linux_build_unit='success',
                         macos_typecheck='success')
            result = self.aggregate(workflow, 'linux', linux, output, built)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for part in ('plan', 'linux_build', 'linux_build_unit', 'macos_typecheck'):
                for value in ('skipped', 'failure', 'cancelled'):
                    with self.subTest(part=part, result=value):
                        self.assertNotEqual(self.aggregate(workflow, 'linux', linux, output,
                                                           dict(built, **{part: value})).returncode, 0)
            for part in ('policy', 'linux_suites'):
                with self.subTest(ran=part):
                    self.assertNotEqual(self.aggregate(workflow, 'linux', linux, output,
                                                       dict(built, **{part: 'success'})).returncode, 0)
            for part in ('policy', 'linux_suites'):
                self.assertIn("needs.plan.outputs.compile_only == 'false'", job(workflow, part).split('\n    if:', 1)[1].split('\n', 1)[0])

    def test_only_a_new_head_reopen_or_readiness_starts_a_candidate(self):
        on = CHECK.read_text().split('\npermissions:', 1)[0]
        events = re.search(r'types: \[(.*?)\]', on)[1].split(', ')
        self.assertEqual(set(events), {'opened', 'synchronize', 'reopened', 'ready_for_review'})


class ReleaseFlowTest(unittest.TestCase):
    def test_no_second_promotion_authority_or_global_issue_hold_remains(self):
        for name in ('.github/workflows/auto-land.yml', 'tests/ci/auto_land.py',
                     'tests/ci/stable_hold.py', 'tests/ci/test_stable_hold.py'):
            with self.subTest(path=name):
                self.assertFalse((ROOT / name).exists())
        for path in (ROOT / '.github/workflows').glob('*.yml'):
            with self.subTest(workflow=path.name):
                self.assertNotRegex(path.read_text(), r'auto_land|auto-land\.yml|stable_hold|completed_run')

    def test_only_a_manual_promotion_publishes_main(self):
        # One tier builds and judges the archives for Qualify main and Promote; only Promote publishes them.
        for workflow, expected in ((RELEASE, ['promote.yml']), (RELEASE_BUILD, ['qualification-tier.yml']),
                                   (UPGRADE, ['qualification-tier.yml']), (RENDERER, ['qualification-tier.yml']),
                                   (TIER, ['main-qualifier.yml', 'promote.yml'])):
            release = workflow.read_text().split('\npermissions:', 1)[0]
            self.assertIn('  workflow_call:', release)
            # The upgrade check and renderer contracts also run by hand for diagnosis.
            for trigger in ('push:', 'workflow_dispatch:', 'workflow_run:', 'schedule:'):
                if workflow not in (UPGRADE, RENDERER) or trigger != 'workflow_dispatch:':
                    self.assertNotIn(trigger, release)
            callers = [path.name for path in (ROOT / '.github/workflows').glob('*.yml')
                       if f'uses: ./.github/workflows/{workflow.name}' in path.read_text()]
            self.assertCountEqual(callers, expected)
        promote = PROMOTE.read_text()
        self.assertEqual(re.findall(r'(?m)^  ([a-z_]+):', promote.split('\npermissions:', 1)[0]), ['workflow_dispatch'])
        selected = CHECK.read_text().split('\npermissions:', 1)[0]
        self.assertIn('  pull_request:', selected)
        self.assertNotIn('  push:', selected)
        self.assertNotIn('workflow_run:', selected)

    def test_main_qualifier_runs_promotions_tier_and_records_without_publishing(self):
        self.assertFalse((ROOT / '.github/workflows/main-build.yml').exists())
        text = QUALIFIER.read_text()
        on = text.split('\npermissions:', 1)[0]
        self.assertRegex(on, r"(?m)^  schedule:\n    - cron: '[0-9]+ \*/3 \* \* \*'$")
        self.assertIn('  workflow_dispatch:', on)
        self.assertNotRegex(on, r'push:|pull_request')
        self.assertRegex(text, r'(?m)^concurrency:\n  # .*\n  group: main-qualifier\n  cancel-in-progress: false$')
        self.assertNotRegex(text, r'/release\.yml|id-token|actions: write|secrets')
        self.assertEqual(re.findall(r'(?m)^  ([a-z_]+):', text.split('\njobs:\n', 1)[1]), ['batch', 'qualify'])
        self.assertIn("github.ref == 'refs/heads/main'", job(text, 'batch'))
        self.assertIn('main_qualified.py batch --head "$HEAD_SHA"', job(text, 'batch'))
        qualify = job(text, 'qualify')
        for line in ('uses: ./.github/workflows/qualification-tier.yml', "if: ${{ needs.batch.outputs.needed == 'true' }}",
                     'base: ${{ needs.batch.outputs.base }}', 'head: ${{ needs.batch.outputs.head }}',
                     'red-label: main-red'):
            self.assertIn(line, qualify)
        self.assertEqual(permissions_of(qualify), {'contents': 'write', 'actions': 'read', 'pull-requests': 'read',
                                                   'checks': 'read', 'statuses': 'write', 'issues': 'write'})
        # Promote and Qualify main on one SHA never cancel each other's tiers.
        self.assertIn('${{ github.workflow }}', UPGRADE.read_text().split('\nconcurrency:', 1)[1].split('\n\n', 1)[0])
        self.assertIn('github.workflow', RENDERER.read_text().split('\nconcurrency:', 1)[1].split('\n\n', 1)[0])
        self.assertIn('github.workflow', CHECK.read_text().split('\nconcurrency:', 1)[1].split('\n\n', 1)[0])

    def test_one_tier_owns_qualification_and_its_verdict(self):
        text = TIER.read_text()
        on = text.split('\npermissions:', 1)[0]
        self.assertEqual(re.findall(r'(?m)^  ([a-z_]+):', on), ['workflow_call'])
        self.assertEqual(re.findall(r'(?m)^      ([a-z-]+):\n        description', on), ['base', 'head', 'red-label', 'version'])
        self.assertEqual(re.findall(r'(?m)^  ([a-z_]+):', text.split('\njobs:\n', 1)[1]),
                         ['release_build', 'selected', 'upgrade', 'renderer', 'qualified', 'report'])
        self.assertNotRegex(text, r'/release\.yml|id-token|actions: write')
        build = job(text, 'release_build')
        self.assertIn('uses: ./.github/workflows/release-build.yml', build)
        self.assertIn('sha: ${{ inputs.head }}', build)
        selected = job(text, 'selected')
        self.assertIn('uses: ./.github/workflows/check.yml', selected)
        self.assertIn('promotion: true', selected)
        self.assertIn('base: ${{ inputs.base }}', selected)
        for name, workflow in (('upgrade', 'previous-release-upgrade.yml'), ('renderer', 'renderer-contracts.yml')):
            body = job(text, name)
            self.assertIn(f'uses: ./.github/workflows/{workflow}', body)
            self.assertIn('${{ inputs.head }}', body)
            self.assertIn('batch-base: ${{ inputs.base }}', body)
            # The tiers test the bytes the release publishes.
            self.assertIn('needs: release_build', body)
            self.assertIn('release-version: ${{ needs.release_build.outputs.version }}', body)
        qualified = job(text, 'qualified')
        self.assertIn('needs: [release_build, selected, upgrade, renderer]', qualified)
        self.assertIn('if: ${{ always() }}', qualified)
        self.assertEqual(permissions_of(qualified), {'contents': 'read', 'statuses': 'write'})
        script = step_script(qualified, 'Record the verdict on HEAD')
        self.assertIn('main_qualified.py verdict $RESULTS', script)
        self.assertIn('main_qualified.py record --sha "$HEAD_SHA" --state "$state" --run-id "$GITHUB_RUN_ID" --version "$VERSION"',
                      script)
        for tier in ('release_build', 'selected', 'upgrade', 'renderer'):
            self.assertIn(f'${{{{ needs.{tier}.result }}}}', qualified)
        # The requirement is report_issue.py's aggregate step: it files nothing of its own.
        self.assertIn('      - name: Require every selected qualification tier\n', qualified)
        self.assertIn('run: test "$STATE" = success', qualified.split('Require every selected qualification tier', 1)[1])
        report = job(text, 'report')
        self.assertIn('if: ${{ failure() }}', report)
        self.assertIn('WORKFLOW: ${{ github.workflow }}', report)
        self.assertIn('report_issue.py --workflow "$WORKFLOW" --run-id "$GITHUB_RUN_ID" --sha "$HEAD_SHA" --label "$RED_LABEL"',
                      report)
        # No caller enumerates the tiers, collects their results or records a verdict itself.
        workflows = {path.name: path.read_text() for path in (ROOT / '.github/workflows').glob('*.yml')}
        authorities = {
            'calls the release build': r'uses: \./\.github/workflows/release-build\.yml',
            'calls the upgrade check': r'uses: \./\.github/workflows/previous-release-upgrade\.yml',
            'calls the renderer contracts': r'uses: \./\.github/workflows/renderer-contracts\.yml',
            'runs Selected checks as a promotion': r'promotion: true',
            'derives a verdict': r'main_qualified\.py verdict',
            'records a final verdict': r'main_qualified\.py record [^\n]*--state "\$state"',
        }
        for what, pattern in authorities.items():
            with self.subTest(authority=what):
                self.assertEqual([name for name, body in sorted(workflows.items()) if re.search(pattern, body)],
                                 ['qualification-tier.yml'])

    def test_promotion_publishes_only_after_every_tier_on_the_same_sha(self):
        text = PROMOTE.read_text()
        self.assertEqual(re.findall(r'(?m)^  ([a-z_]+):', text.split('\njobs:\n', 1)[1]), ['batch', 'qualify', 'release'])
        self.assertIn("github.ref == 'refs/heads/main'", job(text, 'batch'))
        self.assertIn('main_qualified.py choose --main "$MAIN_SHA" --sha "$CHOSEN"', job(text, 'batch'))
        qualify = job(text, 'qualify')
        for line in ('uses: ./.github/workflows/qualification-tier.yml',
                     "if: ${{ needs.batch.outputs.size != '0' && needs.batch.outputs.reuse != 'true' }}",
                     'base: ${{ needs.batch.outputs.base }}', 'head: ${{ needs.batch.outputs.head }}',
                     'red-label: promotion-red'):
            self.assertIn(line, qualify)
        self.assertEqual(permissions_of(qualify), {'contents': 'write', 'actions': 'read', 'pull-requests': 'read',
                                                   'checks': 'read', 'statuses': 'write', 'issues': 'write'})
        release = job(text, 'release')
        self.assertIn('needs: [batch, qualify]', release)
        self.assertIn("if: ${{ !cancelled() && needs.batch.result == 'success' && needs.batch.outputs.size != '0' && "
                      "(needs.batch.outputs.reuse == 'true' || needs.qualify.result == 'success') }}", release)
        self.assertIn('sha: ${{ needs.batch.outputs.head }}', release)
        self.assertIn("version: ${{ needs.batch.outputs.reuse == 'true' && needs.batch.outputs.version"
                      " || needs.qualify.outputs.version }}", release)
        self.assertIn('value: ${{ jobs.release_build.outputs.version }}', TIER.read_text())
        # A green qualification publishes that run's archives without qualifying again.
        self.assertIn('artifact-run: ${{ needs.batch.outputs.run }}', release)
        self.assertEqual(RELEASE.read_text().count('gh run download "$ARTIFACT_RUN"'), 3)
        self.assertNotIn('gh run download "$GITHUB_RUN_ID"', RELEASE.read_text())
        # Publication never rebuilds: it checks the archives against the digests recorded at build time.
        publication = RELEASE.read_text()
        self.assertNotRegex(publication, r'zig build|\.github/actions/setup')
        self.assertIn('rui-digests/SHA256SUMS', publication)
        self.assertIn('sha256sum --check --strict SHA256SUMS', publication)
        self.assertIn('name: rui-digests', RELEASE_BUILD.read_text())

    BISECT = 'python3 -B tests/ci/promotion.py --base "$BASE" --head "$HEAD_SHA" --logs "$RUNNER_TEMP/promotion-bisect"'

    @staticmethod
    def step_list(body):
        script = body.split('python3 -B tests/ci/steps.py', 1)[1].split('\n      - ', 1)[0]
        return [steps.parse(argument) for argument in shlex.split(script.replace('\\\n', ' '))
                if not argument.startswith('--') and '=' in argument and not argument.startswith('$')]

    def test_every_promotion_bisect_replays_only_its_jobs_record(self):
        check = CHECK.read_text()
        jobs = [('linux_suites', job(check, 'linux_suites'), 'run_selected.py'),
                ('macos_suites', job(check, 'macos_suites'), 'run_selected.py'),
                ('upgrade', job(UPGRADE.read_text(), 'upgrade'), 'steps.py'),
                ('contracts', job(RENDERER.read_text(), 'contracts'), 'steps.py')]
        for name, body, recorder in jobs:
            with self.subTest(job=name):
                bisect = body.split('      - name: Bisect the promotion batch with each failed step\n', 1)[1]
                bisect = bisect.split('\n      - ', 1)[0]
                self.assertIn(f'        run: {self.BISECT}', bisect)
                self.assertNotIn('steps.', bisect)
                self.assertNotIn('FAILED', bisect)
                self.assertIn(f'tests/ci/{recorder}', body.split('Bisect the promotion batch', 1)[0])

    def test_promotion_step_lists_name_each_check_once_with_a_fresh_output(self):
        upgrade = self.step_list(job(UPGRADE.read_text(), 'upgrade'))
        self.assertEqual([name for name, _ in upgrade],
                         ['startup', 'current-upgrade', 'running-upgrade', 'previous-upgrade'])
        self.assertIn('previous_release_upgrade.py --running-host', dict(upgrade)['running-upgrade'])
        self.assertIn('$RUNNER_TEMP/previous-running-release', dict(upgrade)['running-upgrade'])
        self.assertIn('zig build host-launch-integration', dict(upgrade)['startup'])
        contracts = self.step_list(job(RENDERER.read_text(), 'contracts'))
        self.assertEqual([name for name, _ in contracts],
                         ['selftest', 'pty', 'ghostty', 'controls', 'recovery'])
        for name, command in upgrade + contracts:
            with self.subTest(step=name):
                self.assertNotIn('/contracts/', command)
                if '--output' in command:
                    self.assertIn('--output "$STEP_OUTPUT"', command)

    def test_upgrade_prepares_the_previous_release_before_any_check(self):
        body = job(UPGRADE.read_text(), 'upgrade')
        checks = body.index('tests/ci/steps.py')
        for setup in ('ref: 0e4b2225d106dd63fa9c38801188facb5e9c6335',
                      'mv .amp/previous-release "$RUNNER_TEMP/previous-release"',
                      'uses: actions/cache/restore@'):
            self.assertLess(body.index(setup), checks, setup)
        # Zig 0.17.1 misses a restored cache until its inputs are restatted, and
        # setup's restat ran before the restore, over the candidate's caches only.
        restat = '"$RUNNER_TEMP/zig-cache-restat" "$previous/.zig-cache/h"'
        self.assertLess(body.index('uses: actions/cache/restore@'), body.index(restat))
        self.assertLess(body.index(restat), checks)


    def test_compiler_backed_acceptance_proof_uses_existing_cache_execution_job(self):
        workflow = CHECK.read_text()
        cache = job(workflow, 'cache_execution')
        proof = 'python3 -B -m unittest discover -s tests/ci -p native_acceptance_test.py -v'
        self.assertIn(proof, cache)
        self.assertLess(cache.index('uses: ./.github/actions/setup'), cache.index(proof))
        self.assertNotIn('native_acceptance', job(workflow, 'policy'))
        self.assertIn('timeout-minutes: 10', job(workflow, 'policy'))
        self.assertIn('timeout-minutes: 20', cache)
        discovered = unittest.defaultTestLoader.discover(str(ROOT / 'tests/ci'))
        def ids(suite):
            for test in suite:
                if isinstance(test, unittest.TestSuite):
                    yield from ids(test)
                else:
                    yield test.id()
        self.assertFalse(any('native_acceptance' in name for name in ids(discovered)))

    def test_candidate_jobs_are_read_only_and_cache_proof_adds_macos_in_promotion(self):
        for path in (CHECK, UPGRADE):
            with self.subTest(workflow=path.name):
                self.assertNotRegex(path.read_text(), r'(?:contents|actions|issues): write')
        cache = job(CHECK.read_text(), 'cache_execution')
        self.assertIn("""runner: ${{ fromJSON(inputs.promotion && '["ubuntu-24.04", "macos-15"]' || '["ubuntu-24.04"]') }}""", cache)


if __name__ == '__main__':
    unittest.main()
