
from copy import deepcopy
from itertools import product
import unittest
from unittest.mock import patch

from ci_plan import plan
from docs_only import ChangeKind
from qualification import shards, split_build


def selection(documentation=False):
    return dict(
        base='base', head='head',
        targets=[] if documentation else ['check', 'test-native', 'transport-h2-integration'],
        fast_targets=[] if documentation else ['test-logic', 'test-native', 'transport-h2-integration'],
        native_targets=[] if documentation else ['test-native', 'transport-h2-integration'],
        server_targets=[] if documentation else ['server'],
        manual_checks=[] if documentation else ['diagnostic'],
        native_required=not documentation, mac_required=not documentation,
        upgrade_required=not documentation, cache_execution_checks=not documentation,
        typecheck_macos=not documentation, linux_memory_checks=not documentation,
        retry=True, mysql_suites=['host-status-integration'], policy_skips=['test_unchanged'],
    )


class PlanTest(unittest.TestCase):
    def test_only_a_pull_request_may_skip_policy_self_checks(self):
        # Every event check.yml can start: pull_request (ready and draft), schedule, workflow_dispatch and promotion.
        for event_name, draft, promotion, skips in (('pull_request', False, False, ['test_unchanged']),
                                                    ('pull_request', True, False, ['test_unchanged']),
                                                    ('schedule', False, False, []),
                                                    ('workflow_dispatch', False, False, []),
                                                    ('workflow_dispatch', False, True, [])):
            with self.subTest(event_name=event_name, draft=draft, promotion=promotion):
                result = plan(selection(), event_name=event_name, draft=draft, promotion=promotion,
                              change_kind=ChangeKind.NORMAL).outputs
                self.assertEqual(result['policy_skips'], skips)

    def test_manual_native_diagnostics_keep_exact_targets_and_disable_retries(self):
        targets = ['test', 'test-logic', 'upgrade-integration']
        for mac_required in (False, True):
            with self.subTest(mac_required=mac_required):
                selected = selection()
                selected['mac_required'] = mac_required
                result = plan(selected, event_name='workflow_dispatch', draft=False, promotion=False,
                              change_kind=ChangeKind.NORMAL, native_targets=targets).outputs
                self.assertEqual(result['native_targets'], targets)
                self.assertIsNot(result['native_targets'], targets)
                self.assertEqual(result['macos_matrix'], shards(targets, 'macos', mysql_suites=selected['mysql_suites'], split_native_full=True))
                self.assertTrue(result['native'])
                self.assertFalse(result['retry'])
                self.assertEqual(result['quarantine'], 'off')
        for targets in (None, False, 1, 1.5, {}, {'target': 'test'}, [], ['test', 'test'],
                        '--help', ['--help'], ['test;false'], [1]):
            with self.subTest(targets=targets), self.assertRaises(ValueError):
                plan(selection(), event_name='workflow_dispatch', draft=False, promotion=False,
                     change_kind=ChangeKind.NORMAL, native_targets=targets)
        for event, promotion, compile_only in (('pull_request', False, False),
                                              ('workflow_dispatch', True, False),
                                              ('workflow_dispatch', False, True)):
            with self.subTest(event=event, promotion=promotion, compile_only=compile_only), self.assertRaises(ValueError):
                plan(selection(), event_name=event, draft=False, promotion=promotion,
                     compile_only=compile_only, change_kind=ChangeKind.NORMAL, native_targets=['test'])

    def test_event_and_change_kind_domain(self):
        cases = (
            ('draft', 'pull_request', True, False),
            ('ready', 'pull_request', False, False),
            ('manual', 'workflow_dispatch', False, False),
            ('promotion', 'workflow_dispatch', False, True),
        )
        normal_linux = ['check', 'test-native', 'transport-h2-integration']
        # CI-69: promotion, scheduled or by hand, runs every check the PR tier skips, whatever the batch touched.
        promoted_linux = ['admission-debug-integration', 'check-full', 'deep-modules', 'host-status-integration',
                          'mysql-wire-integration', 'rsql-table', 'test-logic', 'transport-h2-integration']
        promoted_mac = ['admission-debug-integration', 'check-full', 'test-logic', 'transport-h2-integration']
        expected_targets = {
            ('draft', False): ([], []), ('draft', True): ([], []),
            ('ready', False): (selection()['fast_targets'], []),
            ('ready', True): ([], []),
            ('manual', False): (selection()['targets'], []), ('manual', True): ([], []),
            ('promotion', False): (promoted_linux, promoted_mac),
            ('promotion', True): (promoted_linux[:-1], promoted_mac[:-1]),
        }
        for (name, event, draft, promotion), documentation in product(cases, (False, True)):
            with self.subTest(event=name, documentation=documentation):
                original = selection(documentation)
                before = deepcopy(original)
                kind = ChangeKind.DOCUMENTATION if documentation else ChangeKind.NORMAL
                pr_job = name == 'ready' and not documentation
                with patch('select_tests.tree_graph', side_effect=AssertionError('plan performed I/O')):
                    result = plan(original, event_name=event, draft=draft,
                                  promotion=promotion, change_kind=kind)
                linux, mac = expected_targets[name, documentation]
                expected = dict(
                    change_kind='documentation' if documentation and event == 'pull_request' else 'normal',
                    draft_run=draft, targets=linux, linux_compile_targets=linux, native_targets=mac,
                    linux_matrix=shards([] if pr_job else linux, mysql_suites=original['mysql_suites']),
                    macos_matrix=shards(mac, 'macos', mysql_suites=original['mysql_suites'],
                                        split_native_full=promotion),
                    linux_split=not pr_job and split_build(linux),
                    pr_job=pr_job, pr_setup_targets=sorted(linux) if pr_job else [],
                    native=bool(mac),
                    retry=name == 'manual',
                    quarantine={'draft': 'off', 'ready': 'admission', 'manual': 'admission',
                                'promotion': 'promotion'}[name],
                    linux_memory=not documentation and name in ('manual', 'promotion'),
                    cache_execution=not documentation and name in ('manual', 'promotion'),
                    typecheck_macos=not documentation and name in ('manual', 'promotion'),
                    policy_skips=['test_unchanged'] if event == 'pull_request' else [],
                    compile_only=False,
                    pr_mysql_migration=False,
                )
                self.assertEqual(result.outputs, expected)
                if promotion:
                    self.assertEqual(result.outputs['macos_matrix']['include'][0]['part'], 'both')
                self.assertEqual(original, before, 'the selector result is borrowed, not mutated')
                self.assertEqual(result.selection['targets'], linux)
                self.assertEqual(result.selection['native_targets'], mac)
                self.assertEqual(result.selection['base'], 'base')
                self.assertEqual(result.selection['head'], 'head')
                if draft:
                    self.assertEqual(result.selection['server_targets'], [])
                    self.assertFalse(result.outputs['native'])
                    self.assertTrue(result.outputs['draft_run'])

    def test_every_selector_obligation_vetoes_documentation_even_on_a_draft(self):
        obligations = dict(targets=['test-logic'], native_targets=['test-logic'],
            native_required=True, mac_required=True, upgrade_required=True,
            server_targets=['server'], cache_execution_checks=True, typecheck_macos=True,
            linux_memory_checks=True, manual_checks=['diagnostic'])
        for (key, value), draft in product(obligations.items(), (False, True)):
            with self.subTest(obligation=key, draft=draft):
                result = plan(dict(selection(True), **{key: value}), event_name='pull_request',
                              draft=draft, promotion=False, change_kind=ChangeKind.DOCUMENTATION)
                self.assertEqual(result.outputs['change_kind'], 'normal')
                if draft:
                    self.assertEqual(result.outputs['targets'], [])
                    self.assertEqual(result.outputs['native_targets'], [])

    def test_ready_pr_tier_runs_only_linux_compile_and_selected_linux_suites(self):
        promotion_only = ('cache_execution_checks', 'typecheck_macos', 'linux_memory_checks')
        for mac_required, native_targets, upgrade, retry, obligations in product(
                (False, True), ([], ['test-logic']), (False, True), (False, True), (False, True)):
            with self.subTest(mac=mac_required, native=native_targets, upgrade=upgrade, retry=retry,
                              obligations=obligations):
                original = dict(selection(), targets=['check', 'test-store'],
                    fast_targets=['test-logic', 'test-store'], mac_required=mac_required,
                    native_targets=native_targets, upgrade_required=upgrade, retry=retry,
                    **{key: obligations for key in promotion_only})
                output = plan(original, event_name='pull_request', draft=False,
                              promotion=False, change_kind=ChangeKind.NORMAL).outputs
                self.assertEqual(output['targets'], ['test-logic', 'test-store'])
                self.assertEqual(output['native_targets'], [])
                self.assertFalse(output['native'])
                self.assertEqual(output['macos_matrix'], shards([], 'macos', mysql_suites=original['mysql_suites']))
                self.assertEqual(output['linux_matrix'], {'include': []}, 'one PR job, no shards or live engines')
                self.assertTrue(output['pr_job'])
                for key in ('cache_execution', 'typecheck_macos', 'linux_memory', 'retry'):
                    self.assertFalse(output[key], key)
                self.assertNotIn('upgrade', output)
                self.assertEqual(output['quarantine'], 'admission' if retry else 'off')
                promoted = plan(original, event_name='workflow_dispatch', draft=False,
                                promotion=True, change_kind=ChangeKind.NORMAL).outputs
                for target in ('rsql-table', 'mysql-wire-integration', 'check-full', 'test-logic',
                               'admission-debug-integration'):
                    self.assertIn(target, promoted['targets'])
                self.assertEqual(promoted['native_targets'],
                                 ['admission-debug-integration', 'check-full', 'test-logic'])
                self.assertTrue(promoted['native'])
                for key in ('cache_execution', 'typecheck_macos', 'linux_memory'):
                    self.assertEqual(promoted[key], obligations, key)

    def test_all_unit_obligation_widens_only_compilation_on_ready_candidates(self):
        for targets in ([], ['test-native'], ['test-store'], ['test-logic'], ['test'], ['check'], ['check-full']):
            for required, draft in product((False, True), (False, True)):
                with self.subTest(targets=targets, required=required, draft=draft):
                    source = dict(selection(True), targets=targets, fast_targets=targets, unit_compile_required=required)
                    result = plan(source, event_name='pull_request', draft=draft,
                                  promotion=False, change_kind=ChangeKind.NORMAL).outputs
                    execution = [] if draft else targets
                    compiled = list(execution)
                    if required and not draft and not {'test', 'check', 'check-full'} & set(targets):
                        compiled = sorted(set(targets) | {'test'})
                    self.assertEqual(result['targets'], execution)
                    self.assertEqual(result['linux_compile_targets'], compiled)
                    self.assertEqual(result['linux_matrix'], shards([], mysql_suites=[]))
                    self.assertFalse(result['linux_split'], 'a ready PR compiles in its single job')
                    self.assertEqual(result['pr_job'], not draft)
                    self.assertEqual(result['pr_setup_targets'], [] if draft else sorted(set(execution) | set(compiled)))
                    self.assertFalse(result['native'])
                    self.assertEqual(source['targets'], targets)

    def test_only_a_store_schema_edit_compiles_every_unit_partition_on_the_pr_tier(self):
        # CI-4: of these diffs only the Store schema edit widens the ready compile; promotion compiles all.
        import build_files
        from select_tests import select
        available = set(build_files.steps())
        for paths, ready_compile in (
                (['src/store/schema.zig'], ['deep-modules', 'test', 'test-native', 'test-store']),
                (['src/request_encoding.zig'], ['deep-modules', 'test-logic', 'test-native']),
                (['README.md', 'src/request_encoding.zig'], ['deep-modules', 'test-logic', 'test-native'])):
            with self.subTest(paths=paths):
                selected = select(paths, 'review', available)
                self.assertEqual(selected['unit_compile_required'], paths == ['src/store/schema.zig'])
                ready = plan(selected, event_name='pull_request', draft=False, promotion=False,
                             change_kind=ChangeKind.NORMAL).outputs
                self.assertEqual(ready['linux_compile_targets'], ready_compile)
                promoted = plan(selected, event_name='workflow_dispatch', draft=False, promotion=True,
                                change_kind=ChangeKind.NORMAL).outputs
                self.assertIn('check-full', promoted['linux_compile_targets'], 'promotion compiles every partition')

    def test_macos_matrix_is_one_row_and_never_splits_the_build(self):
        for native in (['check'], ['test'], ['check-full'], ['test-logic'], ['check-full', 'test-logic']):
            with self.subTest(native=native):
                output = plan(dict(selection(), targets=[]), event_name='workflow_dispatch', draft=False,
                              promotion=False, change_kind=ChangeKind.NORMAL, native_targets=native).outputs
                self.assertEqual(output['native_targets'], native)
                self.assertNotIn('macos_split', output)
                self.assertEqual(output['macos_matrix'], shards(native, 'macos', mysql_suites=['host-status-integration'], split_native_full=True))
                self.assertEqual([row['name'] for row in output['macos_matrix']['include']], ['native'])
                self.assertEqual(output['macos_matrix']['include'][0]['part'],
                                 'both' if 'check-full' in native else 'all')
                self.assertFalse(output['linux_split'])

    def test_compile_only_builds_every_gate_and_unit_root_and_runs_nothing(self):
        for documentation, retry in product((False, True), (False, True)):
            with self.subTest(documentation=documentation, retry=retry):
                original = dict(selection(documentation), retry=retry)
                before = deepcopy(original)
                kind = ChangeKind.DOCUMENTATION if documentation else ChangeKind.NORMAL
                output = plan(original, event_name='push', draft=False, promotion=False,
                              change_kind=kind, compile_only=True).outputs
                self.assertEqual(original, before)
                self.assertEqual(output['change_kind'], 'normal')
                self.assertEqual(output['targets'], ['check', 'test-logic'])
                self.assertTrue(output['linux_split'], 'the unit roots compile on their own producer')
                self.assertTrue(output['typecheck_macos'])
                self.assertEqual(output['native_targets'], [])
                self.assertFalse(output['native'])
                self.assertEqual(output['macos_matrix'], shards([], 'macos', mysql_suites=[]))
                for key in ('retry', 'cache_execution', 'linux_memory', 'draft_run'):
                    self.assertFalse(output[key], key)
                self.assertEqual(output['quarantine'], 'off')
                self.assertTrue(output['compile_only'])
        with self.assertRaises(ValueError):
            plan(selection(), event_name='workflow_dispatch', draft=False, promotion=True,
                 change_kind=ChangeKind.NORMAL, compile_only=True)

    def test_ready_pr_runs_the_fast_tier_and_every_other_event_the_full_selection(self):
        for targets, fast in ((['check'], ['test-logic', 'test-native']), (['rsql-table'], []),
                              (['check-full', 'test-store'], ['test-logic', 'test-native', 'test-store']),
                              (['test-logic'], ['test-logic']), ([], [])):
            with self.subTest(targets=targets):
                source = dict(selection(), targets=targets, fast_targets=fast)
                ready = plan(source, event_name='pull_request',
                             draft=False, promotion=False, change_kind=ChangeKind.NORMAL).outputs
                self.assertEqual(ready['targets'], fast)
                manual = plan(source, event_name='workflow_dispatch',
                              draft=False, promotion=False, change_kind=ChangeKind.NORMAL).outputs
                self.assertEqual(manual['targets'], targets)
                promoted = plan(source, event_name='workflow_dispatch',
                                draft=False, promotion=True, change_kind=ChangeKind.NORMAL).outputs
                self.assertTrue({'check-full', 'rsql-table'} <= set(promoted['targets']))


class PrMySqlMigrationTest(unittest.TestCase):
    """pr_mysql_migration: only a ready normal PR whose diff touches a Store migration starts MySQL 8.4."""

    def test_only_a_ready_normal_pull_request_with_a_migration_change_starts_mysql(self):
        cases = (
            ('ready', 'pull_request', False, False, ChangeKind.NORMAL, True, True),
            ('ready, no migration change', 'pull_request', False, False, ChangeKind.NORMAL, False, False),
            ('ready, documentation', 'pull_request', False, False, ChangeKind.DOCUMENTATION, True, False),
            ('draft', 'pull_request', True, False, ChangeKind.NORMAL, True, False),
            ('manual', 'workflow_dispatch', False, False, ChangeKind.NORMAL, True, False),
            ('promotion', 'workflow_dispatch', False, True, ChangeKind.NORMAL, True, False),
            ('compile only', 'push', False, False, ChangeKind.NORMAL, True, False),
        )
        for name, event, draft, promotion, kind, migration, expected in cases:
            with self.subTest(case=name):
                # A documentation-only diff selects nothing, so it is documentation whatever the selection says.
                base = selection(kind is ChangeKind.DOCUMENTATION)
                source = dict(base, fast_targets=['test-logic', 'test-store'], mysql_migration=migration)
                output = plan(source, event_name=event, draft=draft, promotion=promotion, change_kind=kind,
                              compile_only=name == 'compile only').outputs
                self.assertIs(output['pr_mysql_migration'], expected)
        # A selection from before the owner existed has no key: no MySQL.
        output = plan(selection(), event_name='pull_request', draft=False, promotion=False,
                      change_kind=ChangeKind.NORMAL).outputs
        self.assertIs(output['pr_mysql_migration'], False)

    def test_the_migration_change_adds_no_target_and_no_other_output(self):
        base = dict(selection(), fast_targets=['test-logic', 'test-store'])
        without = plan(dict(base, mysql_migration=False), event_name='pull_request', draft=False,
                       promotion=False, change_kind=ChangeKind.NORMAL).outputs
        with_change = plan(dict(base, mysql_migration=True), event_name='pull_request', draft=False,
                           promotion=False, change_kind=ChangeKind.NORMAL).outputs
        self.assertEqual(with_change.pop('pr_mysql_migration'), True)
        without.pop('pr_mysql_migration')
        self.assertEqual(with_change, without)

    def test_a_schema_step_change_selects_test_store_on_the_pr(self):
        import build_files
        from select_tests import select
        available = set(build_files.steps())
        before = """pub const schema_version: u32 = 92;
pub const migrations = [_]Migration{
    .{ .from = 91, .sqlite = &.{"A"}, .mysql = &.{"B"} },
    .{ .from = 92, .sqlite = &.{"C"}, .mysql = &.{"D"} },
};
"""
        cases = (
            (['src/store/schema.zig'], {'src/store/schema.zig': (before, before.replace('"D"', '"E"'))}, True),
            (['src/store/schema.zig'], {'src/store/schema.zig': (before, before + '// a note\n')}, False),
            (['src/store/migration_expected_rows.sql'], {}, True),
            (['src/store/migration_expected_rows.sql', 'README.md'], {}, True),
            (['README.md'], {}, False),
            # Test code with a MySQL leg starts MySQL too (#2179 changed only history.zig, a MySQL user).
            (['src/store/history.zig'], {'src/store/history.zig': ('', 'const mysql_testing = @import("mysql_testing.zig");')}, True),
            (['src/store/tests/agent.zig'], {'src/store/tests/agent.zig': ('', 'try store_testing.forEachEngine(run);')}, True),
            (['src/store/tests/agent.zig'], {'src/store/tests/agent.zig': ('', 'test "sqlite only" {}')}, False),
            # Production code that names the loop is not a MySQL leg.
            (['src/store/Store.zig'], {'src/store/Store.zig': ('', '// forEachEngine runs both')}, False),
        )
        for paths, contents, expected in cases:
            with self.subTest(paths=paths, changed=bool(contents)):
                selected = select(paths, 'review', available, contents=contents)
                self.assertIs(selected['mysql_migration'], expected)
                if expected:
                    self.assertIn('test-store', selected['fast_targets'])
                ready = plan(selected, event_name='pull_request', draft=False, promotion=False,
                             change_kind=ChangeKind.NORMAL).outputs
                self.assertIs(ready['pr_mysql_migration'], expected)
                if expected:
                    self.assertIn('test-store', ready['linux_compile_targets'])
                    self.assertIn('test-store', ready['targets'])


class PrLinuxMySqlWorkflowTest(unittest.TestCase):
    """check.yml's pr_linux starts, waits for and verifies MySQL only behind the migration output."""

    def test_the_mysql_steps_are_guarded_and_the_run_step_names_its_engines(self):
        import re
        from pathlib import Path
        text = Path(__file__).resolve().parents[2].joinpath('.github/workflows/check.yml').read_text()
        plan_job = re.search(r'(?ms)^  plan:\n(.*?)(?=^  [\w-]+:\n|\Z)', text)[1]
        self.assertIn("pr_mysql_migration: ${{ steps.select.outputs.pr_mysql_migration }}", plan_job)
        job = re.search(r'(?ms)^  pr_linux:\n(.*?)(?=^  [\w-]+:\n|\Z)', text)[1]
        guard = "if: ${{ needs.plan.outputs.pr_mysql_migration == 'true' }}"
        steps = re.split(r'(?m)^      - ', job)
        by_name = {}
        for step in steps:
            name = re.match(r'name: (.*)', step)
            if name:
                by_name[name[1].strip()] = step
        start = by_name['Start MySQL 8.4 for the live migration check']
        wait = by_name['Wait for MySQL 8.4']
        verify = by_name['Require that the live MySQL migration check ran']
        run = [name for name in by_name if name.startswith('Run selected targets')]
        self.assertEqual(run, ['Run selected targets, stopping at the first failure (SQLite; MySQL 8.4 when a migration step changed)'])
        self.assertNotIn('on SQLite,', job)
        self.assertIn(guard, start)
        self.assertIn(guard, wait)
        self.assertIn("if: ${{ !cancelled() && needs.plan.outputs.pr_mysql_migration == 'true' }}", verify)
        self.assertIn('tests/integration/mysql_server.py', start)
        self.assertIn('tests/ci/live_engine_step.py export mysql', start)
        # The MySQL steps come before the compile, and the wait before the run.
        order = [name for name in by_name]
        self.assertLess(order.index('Start MySQL 8.4 for the live migration check'),
                        order.index('Compile only the binaries the selected targets need'))
        self.assertLess(order.index('Wait for MySQL 8.4'), order.index(run[0]))
        self.assertLess(order.index(run[0]), order.index('Require that the live MySQL migration check ran'))
        # Every other PR keeps its steps: only the three new ones and the renamed run step carry the output.
        self.assertEqual(job.count('needs.plan.outputs.pr_mysql_migration'), 3)


if __name__ == '__main__':
    unittest.main()
