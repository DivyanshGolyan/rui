"""Execute candidate planning and fail-closed PR admission without native builds."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

from select_tests import select
from strict_paths import STRICT, strict


ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / '.github/workflows/check.yml'
UPGRADE = ROOT / '.github/workflows/previous-release-upgrade.yml'


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


class AdmissionTest(unittest.TestCase):
    def test_cold_native_compile_budget_does_not_extend_runtime_deadlines(self):
        text = CHECK.read_text()

        def budget(body):
            return int(re.search(r'(?m)^    timeout-minutes: (\d+)$', body)[1])

        release = (ROOT / '.github/workflows/release.yml').read_text()
        self.assertGreaterEqual(budget(job(text, 'macos_build')), budget(job(release, 'build')))
        for name in ('linux_suites', 'macos_suites'):
            self.assertEqual(budget(job(text, name)), 35)
        self.assertEqual(budget(job(UPGRADE.read_text(), 'upgrade')), 45)
        for name in ('linux_build', 'linux_build_unit', 'macos_build_unit'):
            self.assertEqual(budget(job(text, name)), 15)

    def test_main_ruleset_requires_strict_admission_and_prs_without_bypass(self):
        ruleset = json.loads((ROOT / '.github/main-ruleset.json').read_text())
        self.assertEqual(ruleset['target'], 'branch')
        self.assertEqual(ruleset['enforcement'], 'active')
        self.assertEqual(ruleset['bypass_actors'], [])
        self.assertEqual(ruleset['conditions']['ref_name'], {'include': ['refs/heads/main'], 'exclude': []})
        rules = {rule['type']: rule for rule in ruleset['rules']}
        self.assertIn('pull_request', rules)
        self.assertIn('non_fast_forward', rules)
        self.assertIn('deletion', rules)
        checks = rules['required_status_checks']['parameters']
        self.assertTrue(checks['strict_required_status_checks_policy'])
        self.assertEqual(checks['required_status_checks'], [{'context': 'admission', 'integration_id': 15368}])

    def admission(self, **changes):
        env = dict(DRAFT='false', PLAN_RESULT='success', POLICY_RESULT='success',
                   LINUX_RESULT='success', MACOS_RESULT='success', UPGRADE_RESULT='success',
                   NATIVE='true', CACHE_SELECTED='false', CACHE_RESULT='skipped')
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
        for value in ('false', ''):
            self.assertNotEqual(self.admission(NATIVE=value).returncode, 0)

    def test_cache_selection_has_no_unknown_or_unexpected_skips(self):
        for selected, results in (
                ('true', ('skipped', 'cancelled', 'failure', 'queued', 'in_progress', '')),
                ('false', ('success', 'cancelled', 'failure', 'queued', 'in_progress', '')),
                ('', ('success', 'skipped')), ('unexpected', ('success', 'skipped'))):
            for result in results:
                with self.subTest(selected=selected, result=result):
                    self.assertNotEqual(self.admission(CACHE_SELECTED=selected, CACHE_RESULT=result).returncode, 0)

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

    def test_reusable_upgrade_receives_candidate_and_runs_both_native_platforms(self):
        caller = job(CHECK.read_text(), 'previous_release_upgrade')
        self.assertIn('uses: ./.github/workflows/previous-release-upgrade.yml', caller)
        self.assertIn('candidate-ref: ${{ needs.plan.outputs.candidate_ref }}', caller)
        self.assertIn("github.event_name == 'pull_request'", caller)
        self.assertIn('!github.event.pull_request.draft', caller)
        text = UPGRADE.read_text()
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
        # Strict native owner mappings remain available before workflow core acceptance is added.
        available = set(re.findall(r'b\.step\(\s*"([a-z0-9-]+)"', Path('build.zig').read_text()))
        for pattern in STRICT:
            path = pattern.replace('*', '_x')
            self.assertEqual(strict([path]), [path])
            self.assertTrue(select([path], 'review', available)['native_required'], path)

class CandidatePlanTest(unittest.TestCase):
    def test_ready_plan_preserves_owner_selection_and_core_superset(self):
        from select_tests import CHECK_COVERS, select
        available = set(re.findall(r'b\.step\(\s*"([a-z0-9-]+)"', (ROOT / 'build.zig').read_text()))
        script = textwrap.dedent(re.search(
            r"(?ms)^          python3 - <<'PY'\n(.*?)^          PY$", CHECK.read_text())[1])
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            (root / 'tests').symlink_to(ROOT / 'tests', target_is_directory=True)
            for path in ('README.md', 'src/store.zig', 'build.zig', 'src/os/descriptor_limit.zig',
                         'src/AnswerRenderer.zig', 'tests/ci/stack_frames.py'):
                for event, phase in (('pull_request', 'review'),
                                             ('pull_request', 'development'),
                                             ('workflow_dispatch', 'review')):
                    with self.subTest(path=path, event=event, phase=phase):
                        selection = select([path], phase, available)
                        (root / 'selection.json').write_text(json.dumps(selection))
                        (root / 'output').write_text('')
                        result = subprocess.run(['python3', '-B', '-c', script], cwd=root,
                            env=dict(os.environ, EVENT_NAME=event,
                                     GITHUB_REF_NAME='main', CANDIDATE_REF='a' * 40,
                                     GITHUB_OUTPUT=str(root / 'output'), GITHUB_STEP_SUMMARY=str(root / 'summary')),
                            capture_output=True, text=True)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        output = dict(line.split('=', 1) for line in (root / 'output').read_text().splitlines())
                        codegen = event == 'pull_request' and bool({'check', 'stack-frames'} & set(selection['targets']))
                        linux = [t for t in selection['targets'] if not (codegen and t == 'stack-frames')]
                        self.assertEqual(json.loads(output['targets']), linux)
                        required = event == 'pull_request' and phase == 'review'
                        if required:
                            expected = (set(selection['native_targets']) - CHECK_COVERS) | {'admission-debug-integration'}
                            if 'check-full' not in expected:
                                expected.add('check')
                            self.assertEqual(json.loads(output['native_targets']), sorted(expected))
                            self.assertEqual(output['native'], 'true')
                            self.assertEqual(output['retry'], 'false')
                            self.assertTrue(json.loads(output['macos_matrix'])['include'])
                            self.assertFalse({'check', 'check-full'} <= expected)
                        else:
                            self.assertEqual(json.loads(output['native_targets']), [])
                            self.assertEqual(output['native'], 'false')

    def test_executed_plan_uses_pinned_tree_and_recomputes_after_base_change(self):
        # Admission qualifies this tested source tree, not the later final squash SHA.
        script = step_script(job(CHECK.read_text(), 'plan'), 'Select existing targets')
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            repo = root / 'repo'
            repo.mkdir()

            def git(*args):
                return subprocess.run(['git', *args], cwd=repo, check=True,
                                      capture_output=True, text=True).stdout.strip()

            def commit(message):
                git('add', '-A')
                git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', message)
                return git('rev-parse', 'HEAD')

            git('init', '-q', '-b', 'main')
            (repo / 'tests').symlink_to(ROOT / 'tests', target_is_directory=True)
            (repo / 'build.zig').write_text((ROOT / 'build.zig').read_text())
            (repo / 'README.md').write_text('base\n')
            base = commit('base')
            (repo / 'src').mkdir()
            (repo / 'src/history_memo.zig').write_text('changed owner\n')
            retarget = commit('owner')
            (repo / 'README.md').write_text('candidate\n')
            candidate = commit('candidate')
            env = dict(os.environ, PHASE='review', STABLE='false', EVENT_NAME='pull_request',
                       GITHUB_REF_NAME='5/merge', GITHUB_SHA=candidate, CANDIDATE_REF=candidate,
                       GITHUB_OUTPUT=str(root / 'output'), GITHUB_STEP_SUMMARY=str(root / 'summary'))

            def plan(base_ref):
                (root / 'output').write_text('')
                result = subprocess.run(['bash', '-c', script], cwd=repo, env=dict(env, BASE=base_ref),
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                return dict(line.split('=', 1) for line in (root / 'output').read_text().splitlines())

            old_base, new_base = plan(base), plan(retarget)
            for output in (old_base, new_base):
                self.assertEqual(output['candidate_ref'], candidate)
                self.assertEqual(output['native'], 'true')
                self.assertEqual(output['retry'], 'false')
                self.assertTrue({'check', 'admission-debug-integration'} <= set(json.loads(output['native_targets'])))
            self.assertIn('test-logic', json.loads(old_base['native_targets']))
            self.assertNotIn('test-logic', json.loads(new_base['native_targets']))
            self.assertNotEqual(old_base['targets'], new_base['targets'])
            # A mutable merge ref advancing cannot silently select or execute another tree.
            git('checkout', '-q', '--detach', retarget)
            result = subprocess.run(['bash', '-c', script], cwd=repo, env=dict(env, BASE=base),
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)

    def test_pr_base_retarget_and_draft_changes_rebuild_the_candidate(self):
        on = CHECK.read_text().split('\npermissions:', 1)[0]
        events = re.search(r'types: \[(.*?)\]', on)[1].split(', ')
        self.assertTrue({'edited', 'synchronize', 'ready_for_review', 'converted_to_draft'} <= set(events))
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

    def test_only_release_automatically_publishes_main(self):
        text = (ROOT / '.github/workflows/release.yml').read_text()
        entry = text.split('\npermissions:', 1)[0]
        self.assertIn('  push:\n    branches: [main]', entry)
        self.assertIn('  workflow_dispatch:', entry)
        self.assertNotIn('workflow_run:', entry)
        selected = CHECK.read_text().split('\npermissions:', 1)[0]
        self.assertIn('  pull_request:', selected)
        self.assertNotIn('  push:', selected)
        self.assertNotIn('workflow_run:', selected)

    def test_candidate_jobs_are_read_only_and_cache_proof_covers_both_platforms(self):
        for path in (CHECK, UPGRADE):
            with self.subTest(workflow=path.name):
                self.assertNotRegex(path.read_text(), r'(?:contents|actions|issues): write')
        cache = job(CHECK.read_text(), 'cache_execution')
        self.assertIn('runner: [ubuntu-24.04, macos-15]', cache)


if __name__ == '__main__':
    unittest.main()
