"""Frames `host restart` steps: serve validation, restore ordering and launch-option reuse."""
import copy
import json
from pathlib import Path
import runpy
import types
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).parents[2] / '.claude/skills/verify-rui/scripts/verify-rui'
RECIPE = SCRIPT.with_name('frames.json')


def unserved_state(steps, **extra):
    state = copy.deepcopy(next(s for s in json.loads(RECIPE.read_text())['states']
                               if s['name'] == 'provider-unserved-night'))
    state['steps'] = steps
    state.update(extra)
    return state


class HostServeValidationTest(unittest.TestCase):
    def setUp(self):
        self.helper = runpy.run_path(str(SCRIPT))
        self.validate = self.helper['validate_scenario']

    def check(self, steps, **extra):
        self.validate({'sizes': ['140x40'], 'states': [unserved_state(steps, **extra)]})

    def test_recipe_restart_state_is_valid(self):
        self.check(unserved_state([])['steps'])

    def test_rejects_invalid_serve_lists(self):
        bad = {
            'wrong type': 'openai',
            'empty list': [],
            'duplicates': ['openai', 'openai'],
            'unknown provider': ['gemini'],
            'non-string entry': [1],
        }
        for label, serve in bad.items():
            with self.subTest(label), self.assertRaises(ValueError):
                self.check([{'host': 'restart', 'serve': serve}])

    def test_accepts_known_provider_sets(self):
        self.check([{'host': 'restart'}])
        self.check([{'host': 'restart', 'serve': ['openai']}])
        self.check([{'host': 'restart', 'serve': ['codex', 'openai', 'chatgpt']}])

    def test_serve_requires_a_restart_step(self):
        with self.assertRaises(ValueError):
            self.check([{'host': 'start', 'serve': ['openai']}])

    def test_restart_rejected_while_suspended(self):
        with self.assertRaises(ValueError):
            self.check([{'host': 'suspend'}, {'host': 'restart', 'serve': ['openai']}])

    def test_restart_rejected_in_upgrade_states(self):
        with self.assertRaises(ValueError):
            self.check([{'host': 'restart'}], upgrade=True)


class HostRestartRuntimeTest(unittest.TestCase):
    def setUp(self):
        self.helper = runpy.run_path(str(SCRIPT))
        self.steps = self.helper['frame_steps']
        self.restore = self.helper['frame_restore_served']
        self.events = []

    def stubs(self, launch_error=None):
        def stop_host(run):
            self.events.append(('stop',))
            return []

        def launch_host(run, **kwargs):
            self.events.append(('launch', kwargs))
            if launch_error is not None and sum(e[0] == 'launch' for e in self.events) == 1:
                raise launch_error  # only the restart launch fails; the restore must still run
        return patch.dict(self.steps.__globals__, {'stop_host': stop_host, 'launch_host': launch_host})

    def make_run(self, meta=None, **extra):
        root = Path(self.id().replace('.', '_'))
        return types.SimpleNamespace(meta=meta or {}, evidence=root, root=root, frame_served=None, **extra)

    def terminal(self):
        return types.SimpleNamespace(status=None)

    def test_failed_restart_is_still_restored(self):
        run = self.make_run()
        with self.stubs(launch_error=SystemExit(2)):
            with self.assertRaises(SystemExit):
                self.steps(run, self.terminal(), [{'host': 'restart', 'serve': ['openai']}])
            self.assertEqual(run.frame_served, ('openai',))
            self.restore(run)
        self.assertEqual(self.events[-2:], [('stop',), ('launch', {'restartable': False, 'without_preload': False})])
        self.assertIsNone(run.frame_served)

    def test_restore_reuses_first_launch_options(self):
        run = self.make_run({'host_launch': {'restartable': True, 'without_preload': True}})
        with self.stubs():
            self.steps(run, self.terminal(), [{'host': 'restart', 'serve': ['openai']}])
            self.restore(run)
        restart_call = [e for e in self.events if e[0] == 'launch'][0][1]
        restore_call = [e for e in self.events if e[0] == 'launch'][1][1]
        self.assertEqual(restart_call, {'serve': ('openai',), 'restartable': True, 'without_preload': True})
        self.assertEqual(restore_call, {'restartable': True, 'without_preload': True})

    def test_start_resets_restore(self):
        run = self.make_run()
        with self.stubs():
            self.steps(run, self.terminal(), [{'host': 'restart', 'serve': ['openai']}, {'host': 'start'}])
            self.restore(run)
        self.assertEqual([e[0] for e in self.events], ['stop', 'launch', 'launch'])
        self.assertIsNone(run.frame_served)

    def test_restore_is_noop_without_restart(self):
        run = self.make_run()
        with self.stubs():
            self.restore(run)
        self.assertEqual(self.events, [])

    def test_default_restart_is_still_restored(self):
        run = self.make_run()
        with self.stubs():
            self.steps(run, self.terminal(), [{'host': 'restart'}])
            self.assertEqual(run.frame_served, ('codex',))
            self.restore(run)
        self.assertEqual([e[0] for e in self.events], ['stop', 'launch', 'stop', 'launch'])


if __name__ == '__main__':
    unittest.main()
