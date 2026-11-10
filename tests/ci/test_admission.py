"""Execute candidate planning and fail-closed PR admission without native builds."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import shlex
import shutil
import unittest

import build_files
from select_tests import select
import steps
from strict_paths import STRICT, strict


ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / '.github/workflows/check.yml'
UPGRADE = ROOT / '.github/workflows/previous-release-upgrade.yml'
PROMOTE = ROOT / '.github/workflows/promote.yml'
RELEASE = ROOT / '.github/workflows/release.yml'
RENDERER = ROOT / '.github/workflows/renderer-contracts.yml'


def job(text, name):
    match = re.search(rf'(?ms)^  {name}:\n(.*?)(?=^  [a-z_]+:|\Z)', text)
    if not match:
        raise AssertionError(f'missing job {name}')
    return match[1]


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
                UPGRADE_RESULT='skipped', NATIVE='false', UPGRADE='false', TARGETS='[]', NATIVE_TARGETS='[]',
                LINUX_MATRIX='{"include": []}', MACOS_MATRIX='{"include": []}',
                LINUX_SPLIT='false', MACOS_SPLIT='false', CODEGEN='false', LINUX_MEMORY='false')


class PlanFixture:
    def __enter__(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.git('init', '-q', '-b', 'main')
        self.write('.git/info/exclude', 'selection.json\n__pycache__/\n')
        for name in ('select_tests.py', 'docs_only.py', 'qualification.py', 'strict_paths.py', 'platform_boundary.py',
                     'import_architecture.py', 'build_files.py', 'stack_frames.json'):
            self.write('tests/ci/' + name, (ROOT / 'tests/ci' / name).read_text())
        # The selector's import graph reads the source tree.
        for name in subprocess.check_output(['git', 'ls-files', '-z', 'src', 'tests/integration', 'build'], cwd=ROOT).decode().split('\0'):
            if name and (ROOT / name).is_file():
                (self.repo / name).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / name, self.repo / name)
        self.write('build.zig', (ROOT / 'build.zig').read_text())
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

    def run(self, base=None, candidate=None, event='pull_request', phase='review', promotion=False):
        self.output = self.root / 'output'
        self.output.write_text('')
        script = step_script(job(CHECK.read_text(), 'plan'), 'Select existing targets')
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', BASE=base or self.base, PHASE=phase, EVENT_NAME=event,
                   PROMOTION=str(promotion).lower(),
                   GITHUB_REF_NAME='5/merge', CANDIDATE_REF=candidate or self.git('rev-parse', 'HEAD'),
                   GITHUB_OUTPUT=str(self.output), GITHUB_STEP_SUMMARY=str(self.root / 'summary'))
        return subprocess.run(['bash', '-c', script], cwd=self.repo, env=env,
                              capture_output=True, text=True)

    def plan(self, test, **kwargs):
        result = self.run(**kwargs)
        test.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return dict(line.split('=', 1) for line in self.output.read_text().splitlines())


class AdmissionTest(unittest.TestCase):
    def test_cold_native_compile_budget_does_not_extend_runtime_deadlines(self):
        text = CHECK.read_text()

        def budget(body):
            return int(re.search(r'(?m)^    timeout-minutes: (\d+)$', body)[1])

        def step_budget(body, name):
            step = body.split(f'      - name: {name}\n', 1)[1].split('\n      - ', 1)[0]
            return int(re.search(r'(?m)^        timeout-minutes: (\d+)$', step)[1])

        release = RELEASE.read_text()
        self.assertGreaterEqual(budget(job(text, 'macos_build')), budget(job(release, 'build')))
        # Only a promotion's bisect extends a job; the suites keep their deadline.
        for name, step in (('linux_suites', 'Run selected targets'), ('macos_suites', 'Run required native targets')):
            self.assertIn('    timeout-minutes: ${{ inputs.promotion && 300 || 35 }}', job(text, name))
            self.assertEqual(step_budget(job(text, name), step), 35)
        upgrade = job(UPGRADE.read_text(), 'upgrade')
        self.assertIn("    timeout-minutes: ${{ inputs.batch-base && 300 || 45 }}", upgrade)
        self.assertEqual(step_budget(upgrade, 'Start detached, then install, save real work, reinstall and '
                                     'restart the same Store'), 45)
        for name in ('linux_build', 'linux_build_unit', 'macos_build_unit'):
            self.assertEqual(budget(job(text, name)), 15)

    def test_main_ruleset_requires_admission_and_prs_with_only_an_admin_pr_bypass(self):
        ruleset = json.loads((ROOT / '.github/main-ruleset.json').read_text())
        self.assertEqual(ruleset['target'], 'branch')
        self.assertEqual(ruleset['enforcement'], 'active')
        # Admins may merge a PR past a check GitHub never ran; nobody pushes to main directly.
        self.assertEqual(ruleset['bypass_actors'],
                         [{'actor_id': 5, 'actor_type': 'RepositoryRole', 'bypass_mode': 'pull_request'}])
        self.assertEqual(ruleset['conditions']['ref_name'], {'include': ['refs/heads/main'], 'exclude': []})
        rules = {rule['type']: rule for rule in ruleset['rules']}
        self.assertIn('pull_request', rules)
        self.assertIn('non_fast_forward', rules)
        self.assertIn('deletion', rules)
        checks = rules['required_status_checks']['parameters']
        # Promotion qualifies the merged batch, so a green PR need not rerun after main moves.
        self.assertFalse(checks['strict_required_status_checks_policy'])
        self.assertEqual(checks['required_status_checks'], [{'context': 'admission', 'integration_id': 15368}])

    def admission(self, **changes):
        env = dict(CHANGE_KIND='normal', DRAFT='false', PLAN_RESULT='success', POLICY_RESULT='success',
                   LINUX_RESULT='success', MACOS_RESULT='success', UPGRADE_RESULT='success',
                   NATIVE='true', UPGRADE='true', CACHE_SELECTED='false', CACHE_RESULT='skipped')
        env.update(changes)
        script = step_script(job(CHECK.read_text(), 'admission'), 'Require candidate acceptance')
        return subprocess.run(['bash', '-c', script], env=dict(os.environ, **env),
                              capture_output=True, text=True)

    def test_all_green_and_only_unselected_cache_skip_pass(self):
        self.assertEqual(self.admission().returncode, 0)
        self.assertEqual(self.admission(CACHE_SELECTED='true', CACHE_RESULT='success').returncode, 0)

    def test_each_required_part_rejects_pending_cancelled_failed_skipped_or_missing(self):
        for part in ('PLAN_RESULT', 'POLICY_RESULT', 'LINUX_RESULT', 'MACOS_RESULT', 'UPGRADE_RESULT'):
            for result in ('queued', 'pending', 'in_progress', 'cancelled', 'failure', 'skipped', ''):
                with self.subTest(part=part, result=result):
                    self.assertNotEqual(self.admission(**{part: result}).returncode, 0)

    def test_draft_or_reduced_native_run_never_admits(self):
        for value in ('true', ''):
            self.assertNotEqual(self.admission(DRAFT=value).returncode, 0)
        for value in ('', 'unknown'):
            self.assertNotEqual(self.admission(NATIVE=value).returncode, 0)
            self.assertNotEqual(self.admission(UPGRADE=value).returncode, 0)

    def test_mac_and_upgrade_admit_only_their_exact_selection(self):
        # Unselected Mac and upgrade jobs must be skipped, never run or pending.
        for native, upgrade in (('false', 'false'), ('true', 'false'), ('false', 'true')):
            env = dict(NATIVE=native, UPGRADE=upgrade,
                       MACOS_RESULT='success' if native == 'true' else 'skipped',
                       UPGRADE_RESULT='success' if upgrade == 'true' else 'skipped')
            with self.subTest(native=native, upgrade=upgrade):
                self.assertEqual(self.admission(**env).returncode, 0)
            for key, selected in (('MACOS_RESULT', native), ('UPGRADE_RESULT', upgrade)):
                for result in ('success', 'skipped', 'failure', 'cancelled', 'in_progress', ''):
                    if result == env[key]:
                        continue
                    with self.subTest(native=native, upgrade=upgrade, key=key, result=result):
                        self.assertNotEqual(self.admission(**dict(env, **{key: result})).returncode, 0)

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
        env = dict(CHANGE_KIND='documentation', PLAN_RESULT='success', POLICY_RESULT='skipped',
                   TARGETS='[]', SPLIT='false', CODEGEN='false', BUILD_RESULT='skipped',
                   UNIT_RESULT='skipped', CODEGEN_RESULT='skipped', NATIVE_RESULT='skipped',
                   TYPECHECK_RESULT='skipped')

        def run(values):
            return subprocess.run(['bash', '-euc', script], env=values,
                                  capture_output=True, text=True).returncode

        self.assertEqual(run(env), 0)
        for key, good in env.items():
            values = ('success', 'skipped', 'failure', 'cancelled', 'queued', 'pending', 'in_progress', '') if key.endswith('_RESULT') else ('', 'unknown', 'true', '["check"]')
            for value in values:
                if value == good:
                    continue
                with self.subTest(key=key, value=value):
                    self.assertNotEqual(run(dict(env, **{key: value})), 0)
            missing = dict(env)
            del missing[key]
            with self.subTest(missing=key):
                self.assertNotEqual(run(missing), 0)

    def test_linux_legacy_default_cannot_admit_an_explicit_unknown_kind(self):
        script = step_script(job(CHECK.read_text(), 'linux'), 'Require every selected Linux part')
        env = dict(PLAN_RESULT='success', POLICY_RESULT='success', TARGETS='[]', SPLIT='false',
                   CODEGEN='false', BUILD_RESULT='skipped', UNIT_RESULT='skipped',
                   CODEGEN_RESULT='skipped', NATIVE_RESULT='skipped', TYPECHECK_RESULT='skipped')
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
        self.assertIn("needs.plan.outputs.upgrade == 'true'", job(text, 'previous_release_upgrade'))
        for name in ('macos_build', 'macos_suites', 'macos'):
            self.assertIn("needs.plan.outputs.native == 'true'", job(text, name))
        for name in ('plan', 'linux', 'admission'):
            body = job(text, name)
            for forbidden in ('sentence_lines', 'pip install', 'npm ', 'actions/setup-node',
                              'uses: ./.github/actions/setup', 'actionlint', 'unittest discover'):
                self.assertNotIn(forbidden, body)
        self.assertNotIn('paths-ignore', text)

    def test_policy_skips_only_the_named_unchanged_self_checks(self):
        script = step_script(job(CHECK.read_text(), 'policy'), 'Run tests/ci, less self-checks whose inputs are unchanged')
        modules = {
            'test_alpha': 'class Alpha(unittest.TestCase):\n    def test_one(self): pass\n    def test_two(self): pass\n',
            'test_beta': ('class Kept(unittest.TestCase):\n    def test_kept(self): pass\n'
                          'class Skipped(unittest.TestCase):\n    def test_skipped(self): self.fail()\n'),
            'test_gamma': 'class Gamma(unittest.TestCase):\n    def test_gamma(self): self.fail()\n',
            # A skipped unit's name is not a prefix of another module.
            'test_gamma_more': 'class More(unittest.TestCase):\n    def test_more(self): pass\n',
        }
        with tempfile.TemporaryDirectory() as root:
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
        required = ('plan', 'policy', 'linux', 'macos', 'previous_release_upgrade', 'cache_execution')
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
                    expected = '${{ github.sha }}' if name in ('plan', 'policy') else '${{ needs.plan.outputs.candidate_ref }}'
                    self.assertIn('ref: ' + expected, checkout)
        self.assertIn('candidate_ref: ${{ steps.select.outputs.candidate_ref }}', job(text, 'plan'))
        self.assertIn('CANDIDATE_REF: ${{ github.sha }}', job(text, 'plan'))
        self.assertNotIn('refs/pull/', text)

    def test_reusable_upgrade_runs_linux_on_prs_and_both_platforms_in_promotion(self):
        caller = job(CHECK.read_text(), 'previous_release_upgrade')
        self.assertIn("""systems: '["ubuntu-24.04"]'""", caller)
        promotion = job(PROMOTE.read_text(), 'upgrade')
        self.assertIn('uses: ./.github/workflows/previous-release-upgrade.yml', promotion)
        self.assertNotIn('systems:', promotion)
        self.assertIn('uses: ./.github/workflows/previous-release-upgrade.yml', caller)
        self.assertIn('candidate-ref: ${{ needs.plan.outputs.candidate_ref }}', caller)
        self.assertIn("github.event_name == 'pull_request'", caller)
        self.assertIn('!github.event.pull_request.draft', caller)
        text = UPGRADE.read_text()
        self.assertIn('  workflow_call:', text)
        self.assertIn('      candidate-ref:', text)
        upgrade = job(text, 'upgrade')
        self.assertIn("""os: ${{ fromJSON(inputs.systems || '["ubuntu-24.04", "macos-15"]') }}""", upgrade)
        self.assertIn("""default: '["ubuntu-24.04", "macos-15"]'""", text)
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
        # Strict native owner mappings remain available before workflow core acceptance is added.
        available = set(build_files.steps())
        for pattern in STRICT:
            path = pattern.replace('*', '_x')
            self.assertEqual(strict([path]), [path])
            self.assertTrue(select([path], 'review', available)['native_required'], path)

class CandidatePlanTest(unittest.TestCase):
    def test_ready_plan_preserves_owner_selection_and_core_superset(self):
        from qualification import shards, split_build
        from select_tests import CHECK_COVERS
        available = set(build_files.steps())
        with PlanFixture() as fixture:
            for path in ('README.md', 'docs/guide.md', 'docs/assets/diagram.svg',
                         'src/store.zig', 'build.zig', 'src/os/descriptor_limit.zig',
                         'src/AnswerRenderer.zig', 'tests/ci/unknown_policy.py',
                         '.github/workflows/check.yml', 'unknown.txt'):
                fixture.git('reset', '--hard', fixture.base)
                content = ((ROOT / path).read_text() + '\n// fixture change\n' if path == 'build.zig'
                           else 'Changed. Two sentences on one line.\n')
                fixture.write(path, content)
                candidate = fixture.commit()
                for event, phase in (('pull_request', 'review'), ('pull_request', 'development'),
                                     ('workflow_dispatch', 'review')):
                    with self.subTest(path=path, event=event, phase=phase):
                        selection = select([path], phase, available)
                        output = fixture.plan(self, candidate=candidate, event=event, phase=phase)
                        docs = event == 'pull_request' and path in (
                            'README.md', 'docs/guide.md', 'docs/assets/diagram.svg')
                        self.assertEqual(output['change_kind'], 'documentation' if docs else 'normal')
                        self.assertEqual(output['candidate_ref'], candidate)
                        if docs:
                            self.assert_documentation_plan(output)
                            continue
                        codegen = event == 'pull_request' and bool({'check', 'stack-frames'} & set(selection['targets']))
                        linux = [t for t in selection['targets'] if not (codegen and t == 'stack-frames')]
                        self.assertEqual(json.loads(output['targets']), linux)
                        self.assertEqual(json.loads(output['linux_matrix']), shards(linux))
                        self.assertEqual(output['linux_split'], str(split_build(linux)).lower())
                        self.assertEqual(output['linux_codegen'], str(codegen).lower())
                        self.assertEqual(output['cache_execution'], str(selection['cache_execution_checks']).lower())
                        self.assertEqual(output['linux_memory'], str(selection['linux_memory_checks']).lower())
                        self.assertEqual(json.loads(output['policy_skips']), selection['policy_skips'])
                        required = event == 'pull_request' and phase == 'review'
                        self.assertEqual(output['upgrade'], str(required and selection['upgrade_required']).lower())
                        if required and selection['mac_required']:
                            expected = selection['native_targets'] or ['check']
                            self.assertEqual(json.loads(output['native_targets']), expected)
                            self.assertEqual(output['native'], 'true')
                            self.assertEqual(output['retry'], 'false')
                            self.assertEqual(json.loads(output['macos_matrix']), shards(expected, 'macos'))
                        else:
                            # Linux predicts Mac for every other path; promotion runs Mac.
                            self.assertEqual(json.loads(output['native_targets']), [])
                            self.assertEqual(output['native'], 'false')
                            if required:
                                self.assertEqual(output['retry'], 'false')

    def test_ready_prs_run_the_upgrade_only_for_what_it_exercises(self):
        available = set(build_files.steps())
        for path, required in (('src/store/schema.zig', True), ('src/upgrade_process.zig', True),
                               ('install.sh', True), ('build.zig', True),
                               ('.github/workflows/previous-release-upgrade.yml', True),
                               # Owners the upgrade-integration fixture covers, not the installed-release check.
                               ('src/cli.zig', False), ('src/Overview.zig', False), ('src/store/Store.zig', False),
                               ('tests/ci/release.py', False), ('README.md', False)):
            with self.subTest(path=path):
                self.assertEqual(select([path], 'review', available)['upgrade_required'], required)
                self.assertFalse(select([path], 'development', available)['upgrade_required'])

    def assert_documentation_plan(self, output):
        self.assertEqual(output['change_kind'], 'documentation')
        for key in ('targets', 'native_targets'):
            self.assertEqual(output[key], '[]', key)
        for key in ('linux_matrix', 'macos_matrix'):
            self.assertEqual(output[key], '{"include": []}', key)
        for key in ('native', 'upgrade', 'retry', 'linux_split', 'macos_split', 'linux_codegen',
                    'linux_memory', 'cache_execution'):
            self.assertEqual(output[key], 'false', key)

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
            # Retargeting from docs to a wider base restores normal acceptance.
            self.assertEqual(fixture.plan(self, base=fixture.base, candidate=candidate), mixed)
            fixture.git('checkout', '-q', '--detach', retarget)
            self.assertNotEqual(fixture.run(candidate=candidate).returncode, 0)

    def test_plan_checks_whitespace_and_invalid_base(self):
        with PlanFixture() as fixture:
            fixture.write('README.md', 'Trailing whitespace.  \n')
            candidate = fixture.commit()
            failed = fixture.run(candidate=candidate)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn('trailing whitespace', failed.stdout)
            self.assertNotEqual(fixture.run(base='missing-ref', candidate=candidate).returncode, 0)

    def test_empty_deleted_asset_and_draft_plans(self):
        with PlanFixture() as fixture:
            empty = fixture.plan(self)
            self.assertEqual(empty['change_kind'], 'normal')
            self.assertEqual(empty['native'], 'false')
            self.assertEqual(empty['upgrade'], 'false')
            (fixture.repo / 'README.md').unlink()
            deleted = fixture.commit()
            self.assert_documentation_plan(fixture.plan(self, candidate=deleted))
            fixture.git('reset', '--hard', fixture.base)
            fixture.write('docs/images/screen.png', 'asset\n')
            asset = fixture.commit()
            output = fixture.plan(self, candidate=asset, phase='development')
            self.assert_documentation_plan(output)
            # Draft classification does not make draft admission succeed.
            self.assertNotEqual(AdmissionTest().admission(**documentation_env(), DRAFT='true').returncode, 0)

    def test_documentation_plan_flows_through_real_linux_and_admission_scripts(self):
        workflow = CHECK.read_text()
        linux = step_script(job(workflow, 'linux'), 'Require every selected Linux part')
        admission = step_script(job(workflow, 'admission'), 'Require candidate acceptance')
        with PlanFixture() as fixture:
            fixture.write('README.md', 'First sentence. Second sentence.\n')
            candidate = fixture.commit()
            output = fixture.plan(self, candidate=candidate)
            # Resolve the real step's output expressions, rather than duplicating the plan values.
            results = dict(plan='success', policy='skipped', linux='success', macos='skipped',
                           previous_release_upgrade='skipped', cache_execution='skipped',
                           linux_build='skipped', linux_build_unit='skipped', linux_codegen='skipped',
                           linux_suites='skipped', macos_typecheck='skipped')
            for name, script in (('linux', linux), ('admission', admission)):
                body = job(workflow, name)
                env = {}
                for key, expression in re.findall(r'(?m)^          ([A-Z_]+): \$\{\{ (.*?) \}\}$', body):
                    if expression.startswith('needs.plan.outputs.'):
                        env[key] = output[expression.removeprefix('needs.plan.outputs.')]
                    elif expression == 'github.event.pull_request.draft':
                        env[key] = 'false'
                    elif expression == 'github.token':
                        continue  # only the failure explanation reads it
                    else:
                        env[key] = results[expression.split('.')[1]]
                self.assertTrue(env)
                result = subprocess.run(['bash', '-euc', script], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_future_selector_obligations_veto_documentation(self):
        for key, value in (('targets', ['test-logic']), ('native_targets', ['test-logic']),
                           ('native_required', True), ('mac_required', True), ('upgrade_required', True),
                           ('server_targets', ['test-logic']), ('cache_execution_checks', True),
                           ('linux_memory_checks', True), ('manual_checks', ['diagnostic'])):
            with self.subTest(obligation=key), PlanFixture() as fixture:
                path = fixture.repo / 'tests/ci/select_tests.py'
                source = path.read_text().replace('    result["base"] = base',
                    f'    result[{key!r}] = {value!r}\n    result["base"] = base')
                path.write_text(source)
                baseline = fixture.commit()
                fixture.write('README.md', 'Changed documentation.\n')
                candidate = fixture.commit()
                output = fixture.plan(self, base=baseline, candidate=candidate)
                self.assertEqual(output['change_kind'], 'normal')

    def test_only_a_new_head_reopen_or_readiness_starts_a_candidate(self):
        # `edited` (title, body or base) and `converted_to_draft` cancelled a
        # running candidate on an unchanged head 121 times in 14 days.
        on = CHECK.read_text().split('\npermissions:', 1)[0]
        events = re.search(r'types: \[(.*?)\]', on)[1].split(', ')
        self.assertEqual(set(events), {'opened', 'synchronize', 'reopened', 'ready_for_review'})
        self.assertIn('BASE: ${{ github.event.pull_request.base.sha || inputs.base }}', CHECK.read_text())


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
        release = RELEASE.read_text().split('\npermissions:', 1)[0]
        self.assertIn('  workflow_call:', release)
        for trigger in ('push:', 'workflow_dispatch:', 'workflow_run:', 'schedule:'):
            self.assertNotIn(trigger, release)
        promote = PROMOTE.read_text()
        self.assertEqual(re.findall(r'(?m)^  ([a-z_]+):', promote.split('\npermissions:', 1)[0]), ['workflow_dispatch'])
        callers = [path.name for path in (ROOT / '.github/workflows').glob('*.yml')
                   if 'uses: ./.github/workflows/release.yml' in path.read_text()]
        self.assertEqual(callers, ['promote.yml'])
        selected = CHECK.read_text().split('\npermissions:', 1)[0]
        self.assertIn('  pull_request:', selected)
        self.assertNotIn('  push:', selected)
        self.assertNotIn('workflow_run:', selected)

    def test_promotion_publishes_only_after_every_tier_on_the_same_sha(self):
        text = PROMOTE.read_text()
        self.assertIn("github.ref == 'refs/heads/main'", job(text, 'batch'))
        selected = job(text, 'selected')
        self.assertIn('uses: ./.github/workflows/check.yml', selected)
        self.assertIn('promotion: true', selected)
        for name, workflow in (('upgrade', 'previous-release-upgrade.yml'), ('renderer', 'renderer-contracts.yml')):
            body = job(text, name)
            self.assertIn(f'uses: ./.github/workflows/{workflow}', body)
            self.assertIn('${{ needs.batch.outputs.head }}', body)
            self.assertIn('batch-base: ${{ needs.batch.outputs.base }}', body)
        qualified = job(text, 'qualified')
        needs = re.search(r'(?m)^    needs: \[(.*?)\]$', qualified)[1].split(', ')
        self.assertCountEqual(needs, ['batch', 'selected', 'upgrade', 'renderer'])
        release = job(text, 'release')
        self.assertIn('needs: [batch, qualified]', release)
        self.assertNotIn('if:', release)
        self.assertIn('sha: ${{ needs.batch.outputs.head }}', release)
        script = step_script(qualified, 'Require every selected promotion tier')
        good = dict(BATCH_RESULT='success', SELECTED_RESULT='success', UPGRADE_RESULT='success',
                    RENDERER_RESULT='success')
        self.assertEqual(subprocess.run(['bash', '-c', script], env=good).returncode, 0)
        for key in good:
            for result in ('failure', 'cancelled', 'skipped', ''):
                with self.subTest(key=key, result=result):
                    self.assertNotEqual(subprocess.run(['bash', '-c', script],
                        env=dict(good, **{key: result}), capture_output=True).returncode, 0)

    def test_promotion_plan_runs_the_full_tier_on_both_systems(self):
        with PlanFixture() as fixture:
            for path in ('src/history_memo.zig', 'tests/ci/unknown_policy.py'):
                fixture.git('reset', '--hard', fixture.base)
                fixture.write(path, 'changed\n')
                candidate = fixture.commit()
                with self.subTest(path=path):
                    output = fixture.plan(self, candidate=candidate, event='workflow_dispatch', promotion=True)
                    self.assertEqual(output['change_kind'], 'normal')
                    linux, mac = json.loads(output['targets']), json.loads(output['native_targets'])
                    self.assertTrue({'check-full', 'test-logic', 'admission-debug-integration', 'stack-frames'} <= set(linux))
                    self.assertTrue({'check-full', 'test-logic', 'admission-debug-integration'} <= set(mac))
                    self.assertNotIn('check', linux + mac)
                    self.assertEqual(output['native'], 'true')
                    self.assertEqual(output['retry'], 'false')
                    self.assertEqual(output['upgrade'], 'false')  # promote.yml calls it directly
                    self.assertEqual(output['linux_codegen'], 'false')

    BISECT = 'python3 -B tests/ci/promotion.py --base "$BASE" --head "$HEAD_SHA" --logs "$RUNNER_TEMP/promotion-bisect"'

    @staticmethod
    def step_list(body):
        """The NAME=COMMAND arguments a job passes to steps.py, as the shell would split them."""
        script = body.split('python3 -B tests/ci/steps.py', 1)[1].split('\n      - ', 1)[0]
        return [steps.parse(argument) for argument in shlex.split(script.replace('\\\n', ' '))
                if not argument.startswith('--') and '=' in argument and not argument.startswith('$')]

    def test_every_promotion_bisect_replays_only_its_jobs_record(self):
        # The replayed command is the recorded one: no bisect may restate or select commands.
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
        self.assertEqual([name for name, _ in upgrade], ['startup', 'current-upgrade', 'previous-upgrade'])
        contracts = self.step_list(job(RENDERER.read_text(), 'contracts'))
        self.assertEqual([name for name, _ in contracts],
                         ['selftest', 'pty', 'ghostty', 'controls', 'recovery', 'replay', 'sequence'])
        for name, command in upgrade + contracts:
            with self.subTest(step=name):
                # Harnesses refuse an existing output; replays get a fresh $STEP_OUTPUT.
                self.assertNotIn('/contracts/', command)
                if '--output' in command:
                    self.assertIn('--output "$STEP_OUTPUT"', command)

    def test_upgrade_prepares_the_previous_release_before_any_check(self):
        # A failed check must not leave a later check, or its replay, without its setup.
        body = job(UPGRADE.read_text(), 'upgrade')
        checks = body.index('tests/ci/steps.py')
        for setup in ('ref: 0e4b2225d106dd63fa9c38801188facb5e9c6335',
                      'mv .amp/previous-release "$RUNNER_TEMP/previous-release"',
                      'uses: actions/cache/restore@'):
            self.assertLess(body.index(setup), checks, setup)


    def test_candidate_jobs_are_read_only_and_cache_proof_adds_macos_in_promotion(self):
        for path in (CHECK, UPGRADE):
            with self.subTest(workflow=path.name):
                self.assertNotRegex(path.read_text(), r'(?:contents|actions|issues): write')
        cache = job(CHECK.read_text(), 'cache_execution')
        self.assertIn("""runner: ${{ fromJSON(inputs.promotion && '["ubuntu-24.04", "macos-15"]' || '["ubuntu-24.04"]') }}""", cache)


if __name__ == '__main__':
    unittest.main()
