"""Frames `host restart` and `serves` steps: serve validation, launch verification, restore ordering."""
import copy
import json
from pathlib import Path
import runpy
import shutil
import tempfile
import types
import unittest

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


class FakeHostProcesses:
    """One Store with at most one serving Host. It supplies the `rui host` replies and the
    process probes (spawn, Store holder, clock, sleep) that launch_host and stop_host take."""

    def __init__(self, root, race=(), exits=(), child_providers=None, fail_spawn=0):
        self.store = root / 'store'
        self.serving = None                # {'pid': int, 'providers': {...}}
        self.race = list(race)             # Hosts another process starts right after a spawn
        self.exits = set(exits)            # children that lose the Store and exit at once
        self.child_providers = child_providers
        self.fail_spawn = fail_spawn       # the next N spawns raise SystemExit
        self.pauses = 0
        self.pause_keeps_serving = False
        self.spawned = []                  # argv of each spawn
        self.next_pid = 100
        self.now = 0.0

    def body(self, host):
        providers = {name: 'unserved' for name in ('codex', 'openai', 'chatgpt')}
        providers.update(host['providers'])
        return {'instance': f"instance-{host['pid']}", 'capabilities': {'connections': [
            {'name': name, 'route': route} for name, route in providers.items() if route != 'unserved']}}

    def rui_cmd(self, *args, **_kwargs):
        if args[:2] == ('host', 'status'):
            if self.serving is None:
                return types.SimpleNamespace(returncode=1, stdout='', stderr='rui: host unavailable')
            return types.SimpleNamespace(returncode=0, stdout=json.dumps(self.body(self.serving)), stderr='')
        if args[:2] == ('host', 'pause'):
            self.pauses += 1
            if not self.pause_keeps_serving:
                self.serving = None
            return types.SimpleNamespace(returncode=0, stdout='', stderr='')
        raise AssertionError(args)

    def spawn(self, argv, **kwargs):
        if self.fail_spawn:
            self.fail_spawn -= 1
            raise SystemExit(2)
        kwargs['stdout'].close()
        kwargs['stderr'].close()
        pid = self.next_pid
        self.next_pid += 1
        self.spawned.append(list(argv))
        providers = {}
        for item in argv:
            if item.startswith('providers.') and '.endpoint=' in item:
                name = item.split('.')[1]
                providers[name] = 'chatgpt_device' if name == 'codex' else 'key_file'
        child = types.SimpleNamespace(pid=pid, rc=1 if pid in self.exits else None)
        child.poll = lambda: child.rc
        child.terminate = lambda: None
        child.wait = lambda timeout=None: 0
        if self.race:
            self.serving = {'pid': self.race.pop(0), 'providers': {'codex': 'chatgpt_device'}}
        if child.rc is None and self.serving is None:
            self.serving = {'pid': pid, 'providers': self.child_providers or providers}
        return child

    def holds_store(self, _run, pid):
        return self.serving is not None and self.serving['pid'] == pid

    def clock(self):
        self.now += 1.0
        return self.now

    def sleep(self, _seconds):
        pass


class LaunchVerificationTest(unittest.TestCase):
    def setUp(self):
        self.helper = runpy.run_path(str(SCRIPT))
        self.launch = self.helper['launch_host']
        self.stop = self.helper['stop_host']
        self.temp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.temp, True)

    def make(self, **kwargs):
        fake = FakeHostProcesses(self.temp, **kwargs)
        run = types.SimpleNamespace(meta={'host_options': {'active_capacity': 2, 'host_setenv': []},
                                          'fixture_url': 'http://127.0.0.1:1/responses'},
                                    store=fake.store, project=self.temp, rui=Path('/bin/true'),
                                    evidence=self.temp, env=lambda: {}, owned=lambda: [],
                                    own=lambda *a, **k: None, rui_cmd=fake.rui_cmd)
        return fake, run

    def test_launch_retries_after_losing_the_store_to_another_host(self):
        # The TUI starts its own Host right after our first child spawns; that child exits.
        fake, run = self.make(race=[1000], exits=[100])
        self.launch(run, serve=('codex',), processes=fake)
        self.assertEqual(fake.serving['pid'], 101)
        self.assertEqual(fake.pauses, 1)
        self.assertEqual(len(fake.spawned), 2)

    def test_launch_gives_up_after_bounded_attempts(self):
        fake, run = self.make(race=[1000, 1001, 1002, 1003, 1004], exits=[100, 101, 102, 103, 104])
        with self.assertRaises(SystemExit):
            self.launch(run, serve=('codex',), processes=fake)
        self.assertEqual(len(fake.spawned), self.helper['LAUNCH_ATTEMPTS'])

    def test_launch_requires_the_requested_provider_set(self):
        fake, run = self.make(child_providers={'codex': 'chatgpt_device'})
        with self.assertRaises(SystemExit):
            self.launch(run, serve=('openai',), processes=fake)

    def test_launch_succeeds_for_the_requested_provider_set(self):
        fake, run = self.make()
        self.launch(run, serve=('openai',), processes=fake)
        self.assertEqual(fake.serving['pid'], 100)
        self.assertEqual(fake.pauses, 0)

    def test_stop_pauses_whatever_serves_the_store(self):
        fake, run = self.make()
        fake.serving = {'pid': 900, 'providers': {'codex': 'chatgpt_device'}}
        self.assertEqual(self.stop(run, processes=fake), [])
        self.assertEqual(fake.pauses, 1)
        self.assertIsNone(fake.serving)

    def test_stop_fails_when_a_host_keeps_serving(self):
        fake, run = self.make()
        fake.serving = {'pid': 900, 'providers': {'codex': 'chatgpt_device'}}
        fake.pause_keeps_serving = True
        with self.assertRaises(SystemExit):
            self.stop(run, processes=fake)


class HostRestartRuntimeTest(unittest.TestCase):
    def setUp(self):
        self.helper = runpy.run_path(str(SCRIPT))
        self.steps = self.helper['frame_steps']
        self.restore = self.helper['frame_restore_served']
        self.temp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.temp, True)

    def make(self, **kwargs):
        fake = FakeHostProcesses(self.temp, **kwargs)
        run = types.SimpleNamespace(meta={'host_options': {'active_capacity': 2, 'host_setenv': []},
                                          'fixture_url': 'http://127.0.0.1:1/responses'},
                                    store=fake.store, project=self.temp, rui=Path('/bin/true'),
                                    evidence=self.temp, env=lambda: {}, owned=lambda: [],
                                    own=lambda *a, **k: None, rui_cmd=fake.rui_cmd, frame_served=None)
        return fake, run

    def terminal(self):
        return types.SimpleNamespace(status=None)

    def served(self, fake):
        return sorted(fake.serving['providers']) if fake.serving else None

    def test_failed_restart_is_still_restored(self):
        fake, run = self.make(fail_spawn=1)
        with self.assertRaises(SystemExit):
            self.steps(run, self.terminal(), [{'host': 'restart', 'serve': ['openai']}], processes=fake)
        self.assertEqual(run.frame_served, ('openai',))
        self.restore(run, processes=fake)
        self.assertIsNone(run.frame_served)
        self.assertEqual(self.served(fake), ['codex'])

    def test_restart_and_restore_use_default_launch_options(self):
        fake, run = self.make()
        self.steps(run, self.terminal(), [{'host': 'restart', 'serve': ['openai']}], processes=fake)
        self.assertEqual(self.served(fake), ['openai'])
        self.restore(run, processes=fake)
        restart_argv, restore_argv = fake.spawned
        self.assertIn('providers.openai.endpoint=http://127.0.0.1:1/responses', restart_argv)
        self.assertIn('--test-retry-waits-ms', restart_argv)
        self.assertIn('providers.codex.endpoint=http://127.0.0.1:1/responses', restore_argv)
        self.assertIn('--test-retry-waits-ms', restore_argv)

    def test_start_resets_restore(self):
        fake, run = self.make()
        self.steps(run, self.terminal(), [{'host': 'restart', 'serve': ['openai']}, {'host': 'start'}], processes=fake)
        self.restore(run, processes=fake)
        self.assertEqual(len(fake.spawned), 2)  # restart and start only; the restore is skipped
        self.assertIsNone(run.frame_served)

    def test_restore_is_noop_without_restart(self):
        fake, run = self.make()
        self.restore(run, processes=fake)
        self.assertEqual(fake.spawned, [])

    def test_default_restart_is_still_restored(self):
        fake, run = self.make()
        self.steps(run, self.terminal(), [{'host': 'restart'}], processes=fake)
        self.assertEqual(run.frame_served, ('codex',))
        self.restore(run, processes=fake)
        self.assertEqual(len(fake.spawned), 2)

    def test_serves_step_fails_on_mismatch(self):
        fake, run = self.make()
        fake.serving = {'pid': 900, 'providers': {'codex': 'chatgpt_device'}}
        with self.assertRaises(self.helper['FrameFailure']):
            self.steps(run, self.terminal(), [{'host': 'serves', 'serve': ['openai']}], processes=fake)


if __name__ == '__main__':
    unittest.main()
