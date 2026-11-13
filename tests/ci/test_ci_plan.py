"""CI routing's value domain; Git and workflow handoffs live in test_admission."""

from copy import deepcopy
from itertools import product
import unittest
from unittest.mock import patch

from ci_plan import plan
from docs_only import ChangeKind
from qualification import shards, split_build


def selection(documentation=False):
    """Representative selector values, independent of Git and selector rules."""
    return dict(
        base='base', head='head',
        targets=[] if documentation else ['check', 'stack-frames', 'test-native', 'transport-h2-integration'],
        native_targets=[] if documentation else ['test-native', 'transport-h2-integration'],
        server_targets=[] if documentation else ['server'],
        manual_checks=[] if documentation else ['diagnostic'],
        native_required=not documentation, mac_required=not documentation,
        upgrade_required=not documentation, cache_execution_checks=not documentation,
        typecheck_macos=not documentation, linux_memory_checks=not documentation,
        retry=True, mysql_suites=['host-status-integration'], policy_skips=['test_unchanged'],
    )


class PlanTest(unittest.TestCase):
    def test_event_and_change_kind_domain(self):
        # Each event's expected policy, not a replay of the owner's branches.
        cases = (
            ('draft', 'pull_request', True, False),
            ('ready', 'pull_request', False, False),
            ('manual', 'workflow_dispatch', False, False),
            ('promotion', 'workflow_dispatch', False, True),
        )
        normal_linux = ['check', 'test-native', 'transport-h2-integration']
        promoted_linux = ['admission-debug-integration', 'check-full', 'host-status-integration',
                          'stack-frames', 'test-logic', 'transport-h2-integration']
        promoted_mac = ['admission-debug-integration', 'check-full', 'test-logic', 'transport-h2-integration']
        expected_targets = {
            ('draft', False): ([], []), ('draft', True): ([], []),
            ('ready', False): (normal_linux, ['test-native', 'transport-h2-integration']),
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
                # Matrix generation must use the supplied MySQL facts, never read a source tree.
                with patch('select_tests.tree_graph', side_effect=AssertionError('plan performed I/O')):
                    result = plan(original, event_name=event, draft=draft,
                                  promotion=promotion, change_kind=kind)
                linux, mac = expected_targets[name, documentation]
                expected = dict(
                    change_kind='documentation' if documentation and event == 'pull_request' else 'normal',
                    draft_run=draft, targets=linux, native_targets=mac,
                    linux_matrix=shards(linux, mysql_suites=original['mysql_suites']),
                    macos_matrix=shards(mac, 'macos', mysql_suites=original['mysql_suites']),
                    linux_split=split_build(linux), macos_split=split_build(mac),
                    linux_codegen=name == 'ready' and not documentation,
                    native=bool(mac), upgrade=name == 'ready' and not documentation,
                    retry=name == 'manual',
                    quarantine={'draft': 'off', 'ready': 'admission', 'manual': 'admission',
                                'promotion': 'promotion'}[name],
                    linux_memory=not documentation and name != 'draft',
                    cache_execution=not documentation and name != 'draft',
                    typecheck_macos=not documentation and name != 'draft',
                    policy_skips=['test_unchanged'],
                    compile_only=False,
                )
                self.assertEqual(result.outputs, expected)
                self.assertEqual(original, before, 'the selector result is borrowed, not mutated')
                self.assertEqual(result.selection['targets'], linux)
                self.assertEqual(result.selection['native_targets'], mac)
                self.assertEqual(result.selection['base'], 'base')
                self.assertEqual(result.selection['head'], 'head')
                if draft:
                    self.assertEqual(result.selection['server_targets'], [])
                    self.assertFalse(result.outputs['native'])
                    self.assertFalse(result.outputs['upgrade'])
                    self.assertTrue(result.outputs['draft_run'])  # policy's plan-owned skip

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
                    self.assertFalse(result.outputs['upgrade'])

    def test_ready_normal_retains_selection_and_exact_native_and_upgrade_obligations(self):
        for mac_required, native_targets, upgrade, retry in product(
                (False, True), ([], ['test-logic']), (False, True), (False, True)):
            with self.subTest(mac=mac_required, native=native_targets, upgrade=upgrade, retry=retry):
                original = dict(selection(), targets=['test-logic'], mac_required=mac_required,
                    native_targets=native_targets, upgrade_required=upgrade, retry=retry)
                output = plan(original, event_name='pull_request', draft=False,
                              promotion=False, change_kind=ChangeKind.NORMAL).outputs
                self.assertEqual(output['targets'], ['test-logic'])
                self.assertEqual(output['native_targets'], (native_targets or ['check']) if mac_required else [])
                self.assertEqual(output['native'], mac_required)
                self.assertEqual(output['upgrade'], upgrade)
                self.assertEqual(output['quarantine'], 'admission' if retry else 'off')
                self.assertFalse(output['retry'])
                self.assertFalse(output['linux_codegen'])

    def test_macos_matrix_and_split_use_the_final_native_selection(self):
        for native, mac_required, expected, split in (
                ([], True, ['check'], True),
                (['test'], True, ['test'], False),
                (['check-full'], True, ['check-full'], True),
                (['test-logic'], True, ['test-logic'], False),
                (['check'], False, [], False)):
            with self.subTest(native=native, mac_required=mac_required):
                output = plan(dict(selection(), targets=[], native_targets=native, mac_required=mac_required),
                              event_name='pull_request', draft=False, promotion=False,
                              change_kind=ChangeKind.NORMAL).outputs
                self.assertEqual(output['native_targets'], expected)
                self.assertEqual(output['macos_split'], split)
                self.assertEqual(output['macos_matrix'], shards(expected, 'macos', mysql_suites=[]))
                self.assertFalse(output['linux_split'])

    def test_compile_only_builds_every_gate_and_unit_root_and_runs_nothing(self):
        # main-build.yml after a push: whatever the push selected, or did not.
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
                for key in ('linux_codegen', 'upgrade', 'retry', 'cache_execution', 'linux_memory', 'draft_run'):
                    self.assertFalse(output[key], key)
                self.assertEqual(output['quarantine'], 'off')
                self.assertTrue(output['compile_only'])
        with self.assertRaises(ValueError):
            plan(selection(), event_name='workflow_dispatch', draft=False, promotion=True,
                 change_kind=ChangeKind.NORMAL, compile_only=True)

    def test_pr_codegen_selects_check_or_stack_or_both_without_changing_other_targets(self):
        for targets in (['check'], ['stack-frames'], ['check', 'stack-frames'], ['test-logic'], []):
            with self.subTest(targets=targets):
                output = plan(dict(selection(), targets=targets), event_name='pull_request',
                              draft=False, promotion=False, change_kind=ChangeKind.NORMAL).outputs
                self.assertEqual(output['linux_codegen'], targets not in (['test-logic'], []))
                self.assertEqual(output['targets'], [target for target in targets if target != 'stack-frames'])


if __name__ == '__main__':
    unittest.main()
