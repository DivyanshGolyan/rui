"""Frames `host restart` and `serves` steps: serve validation, launch verification, restore ordering."""
import copy
import json
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile
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

    def test_recipe_witness_is_valid(self):
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
            for action in ('restart', 'serves'):
                with self.subTest(label, action=action), self.assertRaises(ValueError):
                    self.check([{'host': action, 'serve': serve}])

    def test_accepts_known_provider_sets(self):
        self.check([{'host': 'restart'}])
        self.check([{'host': 'restart', 'serve': ['openai']}])
        self.check([{'host': 'serves', 'serve': ['codex', 'openai', 'chatgpt']}])

    def test_serve_requires_a_restart_or_serves_step(self):
        with self.assertRaises(ValueError):
            self.check([{'host': 'start', 'serve': ['openai']}])

    def test_serves_requires_the_provider_set(self):
        with self.assertRaises(ValueError):
            self.check([{'host': 'serves'}])

    def test_restart_rejected_while_suspended(self):
        with self.assertRaises(ValueError):
            self.check([{'host': 'suspend'}, {'host': 'restart', 'serve': ['openai']}])

    def test_restart_rejected_in_upgrade_states(self):
        with self.assertRaises(ValueError):
            self.check([{'host': 'restart'}], upgrade=True)


class FakeHostStore:
    """A Store with one serving Host at a time: stubs `rui host status|pause`, Popen and lsof."""

    def __init__(self, root, race=(), child_providers=None):
        self.store = root / 'store'
        self.serving = None
        self.race = list(race)             # Hosts another process starts right after a spawn
        self.child_providers = child_providers
        self.exits = set()                 # child pids that lose the Store and exit at once
        self.pauses = 0
        self.next_pid = 100
        self.spawned = []

    def body(self, host):
        providers = {name: 'unserved' for name in ('codex', 'openai', 'chatgpt')}
        providers.update(host['providers'])
        return {'instance': f"instance-{host['pid']}", 'capabilities': {'providers': providers}}

    def rui_cmd(self, *args, **kwargs):
        if args[:2] == ('host', 'status'):
            if self.serving is None:
                return types.SimpleNamespace(returncode=1, stdout='', stderr='rui: host unavailable')
            return types.SimpleNamespace(returncode=0, stdout=json.dumps(self.body(self.serving)), stderr='')
        if args[:2] == ('host', 'pause'):
            self.pauses += 1
            self.serving = None
            return types.SimpleNamespace(returncode=0, stdout='', stderr='')
        raise AssertionError(args)

    def Popen(self, argv, **kwargs):
        pid = self.next_pid
        self.next_pid += 1
        providers = {}
        for item in argv:
            if item.startswith('providers.') and '.endpoint=' in item:
                name = item.split('.')[1]
                providers[name] = 'chatgpt_device' if name == 'codex' else 'key_file'
        child = types.SimpleNamespace(pid=pid, providers=self.child_providers or providers,
                                      rc=1 if pid in self.exits else None)
        child.poll = lambda: child.rc
        child.terminate = lambda: None
        child.wait = lambda timeout=None: 0
        self.spawned.append(pid)
        if self.race:
            self.serving = {'pid': self.race.pop(0), 'providers': {'codex': 'chatgpt_device'}}
        if child.rc is None and self.serving is None:
            self.serving = {'pid': pid, 'providers': child.providers}
        return child

    def run(self, argv, **kwargs):
        held = [f'n{self.store}/rui.sqlite3'] if self.serving and f"-p" in argv and str(self.serving['pid']) in argv else []
        return types.SimpleNamespace(stdout='\n'.join(held))


class LaunchVerificationTest(unittest.TestCase):
    def setUp(self):
        self.helper = runpy.run_path(str(SCRIPT))
        self.launch = self.helper['launch_host']
        self.stop = self.helper['stop_host']
        self.globals = self.launch.__globals__
        self.temp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.temp, True)
        self.clock = [0.0]

    def fake_time(self):
        def monotonic():
            self.clock[0] += 0.5
            return self.clock[0]
        return types.SimpleNamespace(sleep=lambda seconds: None, monotonic=monotonic)

    def make(self, **fake_kwargs):
        fake = FakeHostStore(self.temp, **fake_kwargs)
        run = types.SimpleNamespace(meta={'host_options': {'active_capacity': 2, 'host_setenv': []},
                                          'fixture_url': 'http://127.0.0.1:1/responses'},
                                    store=fake.store, project=self.temp, rui=Path('/bin/true'),
                                    evidence=self.temp, env=lambda: {}, owned=lambda: [],
                                    own=lambda *a, **k: None, rui_cmd=fake.rui_cmd)
        patches = patch.dict(self.globals, {'subprocess': types.SimpleNamespace(
                                 Popen=fake.Popen, run=fake.run, TimeoutExpired=subprocess.TimeoutExpired,
                                 DEVNULL=subprocess.DEVNULL),
                             'time': self.fake_time(),
                             'process_start': lambda pid: None})
        patches.start()
        self.addCleanup(patches.stop)
        return fake, run

    def test_launch_retries_after_losing_the_store_to_another_host(self):
        # The TUI starts its own Host right after our first child spawns; that child exits.
        fake, run = self.make(race=[1000])
        fake.exits.add(100)
        self.launch(run, serve=('codex',))
        self.assertEqual(fake.serving['pid'], 101)
        self.assertEqual(fake.pauses, 1)
        self.assertEqual(fake.spawned, [100, 101])

    def test_launch_gives_up_after_bounded_attempts(self):
        fake, run = self.make(race=[1000, 1001, 1002, 1003, 1004])
        fake.exits.update({100, 101, 102, 103, 104})
        with self.assertRaises(SystemExit):
            self.launch(run, serve=('codex',))
        self.assertEqual(len(fake.spawned), self.helper['LAUNCH_ATTEMPTS'])

    def test_launch_requires_the_requested_provider_set(self):
        fake, run = self.make(child_providers={'codex': 'chatgpt_device'})
        with self.assertRaises(SystemExit):
            self.launch(run, serve=('openai',))

    def test_launch_succeeds_for_the_requested_provider_set(self):
        fake, run = self.make()
        self.launch(run, serve=('openai',))
        self.assertEqual(fake.serving['pid'], 100)
        self.assertEqual(fake.pauses, 0)

    def test_stop_pauses_whatever_serves_the_store(self):
        fake, run = self.make()
        fake.serving = {'pid': 900, 'providers': {'codex': 'chatgpt_device'}}
        self.assertEqual(self.stop(run), [])
        self.assertEqual(fake.pauses, 1)
        self.assertIsNone(fake.serving)

    def test_stop_fails_when_a_host_keeps_serving(self):
        fake, run = self.make()
        fake.serving = {'pid': 900, 'providers': {'codex': 'chatgpt_device'}}
        def pause_but_keep_serving(*args, **kwargs):
            if args[:2] == ('host', 'pause'):
                fake.pauses += 1
                return types.SimpleNamespace(returncode=0, stdout='', stderr='')
            return fake.rui_cmd(*args, **kwargs)
        run.rui_cmd = pause_but_keep_serving
        with self.assertRaises(SystemExit):
            self.stop(run)


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

    def make_run(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        return types.SimpleNamespace(meta={}, evidence=root, root=root, frame_served=None)

    def terminal(self):
        return types.SimpleNamespace(status=None)

    def test_failed_restart_is_still_restored(self):
        run = self.make_run()
        with self.stubs(launch_error=SystemExit(2)):
            with self.assertRaises(SystemExit):
                self.steps(run, self.terminal(), [{'host': 'restart', 'serve': ['openai']}])
            self.assertEqual(run.frame_served, ('openai',))
            self.restore(run)
        self.assertEqual(self.events[-2:], [('stop',), ('launch', {})])
        self.assertIsNone(run.frame_served)

    def test_restart_and_restore_use_default_launch_options(self):
        run = self.make_run()
        with self.stubs():
            self.steps(run, self.terminal(), [{'host': 'restart', 'serve': ['openai']}])
            self.restore(run)
        launches = [e[1] for e in self.events if e[0] == 'launch']
        self.assertEqual(launches, [{'serve': ('openai',)}, {}])

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

    def test_serves_step_fails_on_mismatch(self):
        run = self.make_run()
        run.rui_cmd = lambda *a, **k: types.SimpleNamespace(
            returncode=0, stdout=json.dumps({'capabilities': {'providers': {'codex': 'chatgpt_device', 'openai': 'unserved'}}}), stderr='')
        with self.assertRaises(Exception):
            self.steps(run, self.terminal(), [{'host': 'serves', 'serve': ['openai']}])


if __name__ == '__main__':
    unittest.main()
