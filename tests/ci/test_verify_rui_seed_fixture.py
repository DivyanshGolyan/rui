import argparse
import contextlib
import io
import json
from pathlib import Path
import runpy
import tempfile
import types
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).parents[2] / '.claude/skills/verify-rui/scripts/verify-rui'


class SeedFixtureTest(unittest.TestCase):
    def setUp(self):
        self.helper = runpy.run_path(str(SCRIPT))

    def test_ordered_cast_spaces_settlements_and_retains_allocated_labels(self):
        seed = self.helper['seed_cast']
        for ordered in (False, True):
            with self.subTest(ordered=ordered), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                run = types.SimpleNamespace(home=root, root=root, store=root / 'store',
                                            meta={'sessions': {}})
                events = []
                def command(*args, **kwargs):
                    label = args[args.index('--label') + 1]
                    events.append(('start', label))
                    return types.SimpleNamespace(returncode=0, stderr='request: key',
                        stdout=json.dumps({'context': {'session': f'id{len(events)}'}}))
                run.rui_cmd = command
                entries = [{'label': 'Batch {n}', 'count': 3, 'workspace': 'code/rui',
                            'mode': 'bypass', 'messages': ['Ready']}]
                def settled(*_args):
                    events.append(('settled',))
                with patch.dict(seed.__globals__, frame_request=settled), \
                     patch.object(seed.__globals__['time'], 'sleep', side_effect=lambda n: events.append(('sleep', n))):
                    seed(run, entries, ordered=ordered)
                self.assertEqual(list(run.meta['sessions']), ['Batch 1', 'Batch 2', 'Batch 3'])
                self.assertEqual([e[0] for e in events],
                                 ['start', 'settled'] + (['sleep'] if ordered else []) +
                                 ['start', 'settled'] + (['sleep'] if ordered else []) + ['start', 'settled'])
                self.assertTrue(all(e[1] >= 1 for e in events if e[0] == 'sleep'))

    def test_ordering_carries_across_state_casts(self):
        seed = self.helper['seed_cast']
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            run = types.SimpleNamespace(home=root, root=root, store=root / 'store', meta={'sessions': {}})
            run.rui_cmd = lambda *args, **kwargs: types.SimpleNamespace(returncode=0, stderr='request: key',
                stdout=json.dumps({'context': {'session': args[args.index('--label') + 1]}}))
            entry = {'label': 'First', 'workspace': 'code/rui', 'mode': 'bypass', 'messages': ['Ready']}
            with patch.dict(seed.__globals__, frame_request=lambda *_: None), \
                 patch.object(seed.__globals__['time'], 'monotonic', side_effect=[10.0, 10.2, 11.01]), \
                 patch.object(seed.__globals__['time'], 'sleep') as sleep:
                seed(run, [entry], ordered=True)
                seed(run, [{**entry, 'label': 'Second'}], ordered=True)
            self.assertAlmostEqual(sleep.call_args.args[0], 0.81)

    def test_shot_clock_uses_one_offset_and_explicit_library(self):
        fixture_env = self.helper['shots_fixture_env']
        with tempfile.TemporaryDirectory() as temp:
            library = Path(temp) / 'libfaketime.so.1'
            library.touch()
            with patch.dict('os.environ', {'VERIFY_RUI_FAKETIME_LIB': str(library)}):
                self.assertEqual(fixture_env('/tmp/clock'), {'LD_PRELOAD': str(library),
                    'FAKETIME_TIMESTAMP_FILE': '/tmp/clock', 'FAKETIME_NO_CACHE': '1',
                    'FAKETIME_DONT_FAKE_MONOTONIC': '1', 'TZ': 'UTC', 'RUI_TEST_MEMORY_BYTES': '33554432'})
            with patch.dict('os.environ', {'VERIFY_RUI_FAKETIME_LIB': str(library / 'missing')}):
                with self.assertRaisesRegex(ValueError, 'requires libfaketime'):
                    fixture_env('/tmp/clock')

    def test_shot_clock_resets_each_state_and_cast_ordinal_persists(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'clock'
            clock = self.helper['ShotsClock'](path, 83)
            self.assertEqual(path.read_text(), '2026-01-01 12:00:00\n')
            clock.next_cast()
            self.assertEqual(path.read_text(), '2026-01-01 11:58:38\n')
            clock.reset()
            self.assertEqual(path.read_text(), '2026-01-01 12:00:00\n')
            clock.next_cast()
            self.assertEqual(path.read_text(), '2026-01-01 11:58:39\n')
            clock.ordinal = 83
            with self.assertRaisesRegex(Exception, 'planned cast'):
                clock.next_cast()
            self.assertEqual(path.read_text(), '2026-01-01 11:58:39\n')

    def test_shot_cast_uses_distinct_seconds_across_calls_without_real_sleep(self):
        seed = self.helper['seed_cast']
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            clock = self.helper['ShotsClock'](root / 'clock', 83)
            run = types.SimpleNamespace(home=root, root=root, store=root / 'store',
                                        meta={'sessions': {}}, _shot_clock=clock)
            seen = []
            def command(*args, **kwargs):
                label = args[args.index('--label') + 1]
                seen.append((label, clock.path.read_text().strip()))
                return types.SimpleNamespace(returncode=0, stderr='request: key',
                    stdout=json.dumps({'context': {'session': label}}))
            run.rui_cmd = command
            entry = {'label': 'First', 'workspace': 'code/rui', 'mode': 'bypass', 'messages': ['Ready']}
            with patch.dict(seed.__globals__, frame_request=lambda *_: None), \
                 patch.object(seed.__globals__['time'], 'sleep') as sleep:
                seed(run, [entry], ordered=True)
                clock.reset()
                seed(run, [{**entry, 'label': 'Second'}], ordered=True)
                sleep.assert_not_called()
            self.assertEqual(seen, [('First', '2026-01-01 11:58:38'),
                                    ('Second', '2026-01-01 11:58:39')])

    def test_last_cast_is_noon_and_minute_recipe_crosses_one_minute(self):
        recipe_path = SCRIPT.with_name('frames.json')
        scenario = json.loads(recipe_path.read_text())
        entries = [(state, entry) for state in scenario['states']
                   for entry in self.helper['cast_entries'](state.get('cast', []))]
        self.assertEqual(entries[-1][0]['name'], 'chatfeed-night-empty')
        step = next(step for step in entries[-1][0]['steps'] if step.get('sleep') == 61)
        self.assertEqual(step['shot_clock_advance'], 61)
        with tempfile.TemporaryDirectory() as temp:
            clock = self.helper['ShotsClock'](Path(temp) / 'clock', len(entries))
            clock.ordinal = len(entries) - 1
            clock.next_cast()
            self.assertEqual(clock.path.read_text(), '2026-01-01 12:00:00\n')
            clock.reset()
            clock.advance(step['shot_clock_advance'])
            self.assertEqual(clock.path.read_text(), '2026-01-01 12:01:01\n')
            clock.reset()
            self.assertEqual(clock.path.read_text(), '2026-01-01 12:00:00\n')

    def test_explicit_sleep_advances_shots_only(self):
        steps = self.helper['frame_steps']
        with tempfile.TemporaryDirectory() as temp:
            clock = self.helper['ShotsClock'](Path(temp) / 'clock', 83)
            terminal = types.SimpleNamespace(status=None)
            with patch.object(steps.__globals__['time'], 'sleep') as sleep:
                steps(types.SimpleNamespace(_shot_clock=clock), terminal, [{'sleep': 61, 'shot_clock_advance': 61}])
                sleep.assert_called_once_with(61)
                self.assertEqual(clock.path.read_text(), '2026-01-01 12:01:01\n')
                clock.reset()
                steps(types.SimpleNamespace(), terminal, [{'sleep': 61, 'shot_clock_advance': 61}])
                self.assertEqual(clock.path.read_text(), '2026-01-01 12:00:00\n')

    def test_run_frames_resets_clock_after_different_elapsed_durations(self):
        frames = self.helper['run_frames']
        for earlier_duration in (3, 7200):
            with self.subTest(earlier_duration=earlier_duration), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                run = types.SimpleNamespace(root=root, home=root / 'home', evidence=root / 'evidence',
                                            meta={'sha': 'abc', 'sessions': {}})
                scenario = {'sizes': ['80x24'], 'states': [
                    {'name': 'first', 'open': 'overview', 'first_frame': True, 'steps': [
                        {'sleep': earlier_duration}, {'sleep': 61, 'shot_clock_advance': 61}]},
                    {'name': 'second', 'open': 'overview', 'steps': [{'sleep': 19}]}]}
                path = root / 'recipe.json'
                path.write_text(json.dumps(scenario))
                observed = []
                clock_path = None
                elapsed = 0
                def fixture_env(path):
                    nonlocal clock_path
                    clock_path = path
                    return {'FAKETIME_TIMESTAMP_FILE': str(path)}
                def sleep(seconds):
                    nonlocal elapsed
                    observed.append(('sleep', seconds, clock_path.read_text().strip()))
                    elapsed += seconds
                fake_time = types.SimpleNamespace(sleep=sleep, time=lambda: 1000 + elapsed,
                    monotonic=lambda: elapsed, monotonic_ns=lambda: elapsed * 1_000_000_000)
                def seed_cast(run, entries, **kwargs):
                    observed.append(('seed', clock_path.read_text().strip()))
                    return self.helper['seed_cast'](run, entries, **kwargs)
                class Terminal:
                    def __init__(self, _run, state, _size):
                        self.status = None
                        self.frame = types.SimpleNamespace(columns=80, lines=24)
                        self.name = state['name']
                        observed.append(('start', state['name'], clock_path.read_text().strip()))
                    def settle_shot(self, **_kwargs):
                        observed.append(('settle', self.name, clock_path.read_text().strip()))
                        return self.frame
                    def close(self):
                        pass
                def capture(_run, _terminal, _out, state, _size, reason):
                    observed.append(('capture', state['name'], clock_path.read_text().strip()))
                    return {'name': state['name'], 'size': '80x24', 'ok': True,
                            'status': 'ok', 'reason': reason, 'files': {}}
                @contextlib.contextmanager
                def upgrade(run, state, _build):
                    yield run, state, None
                replacements = {'Run': lambda _: run, 'cmd_new': lambda _: print(root),
                    'cmd_cleanup': lambda _: None, 'load_build': lambda _: {'screen_library': '/test'},
                    'require_screen': lambda _: None, 'shots_fixture_env': fixture_env,
                    'FrameTerminal': Terminal, 'frame_upgrade_run': upgrade, 'seed_cast': seed_cast,
                    'frame_initial_ready': lambda *_a, **_k: None,
                    'frame_drive_upgrade': lambda *_: None, 'frame_upgrade_viewport': lambda *_: None,
                    'frame_ready': lambda *_a, **_k: None, 'frame_capture': capture,
                    'frame_upgrade_journey': lambda *_: None, 'frame_host_suspension': lambda *_: None,
                    'frame_finish_held_upgrade': lambda *_: None, 'frames_index': lambda *_: None,
                    'time': fake_time}
                args = argparse.Namespace(sha='abc', scenario=str(path), sizes=None, only=None,
                    no_png=True, keep=False, record=False, shots_fixture=True,
                    out=str(root / 'output'), timing=True)
                with patch.dict(frames.__globals__, replacements), patch.dict('os.environ'), \
                     contextlib.redirect_stdout(io.StringIO()):
                    frames(args)
                self.assertEqual(observed, [
                    ('seed', '2026-01-01 12:00:00'),
                    ('start', 'first', '2026-01-01 12:00:00'),
                    ('settle', 'first', '2026-01-01 12:00:00'),
                    ('sleep', earlier_duration, '2026-01-01 12:00:00'),
                    ('sleep', 61, '2026-01-01 12:00:00'),
                    ('settle', 'first', '2026-01-01 12:01:01'),
                    ('capture', 'first', '2026-01-01 12:01:01'),
                    ('seed', '2026-01-01 12:00:00'),
                    ('start', 'second', '2026-01-01 12:00:00'),
                    ('settle', 'second', '2026-01-01 12:00:00'),
                    ('sleep', 19, '2026-01-01 12:00:00'),
                    ('settle', 'second', '2026-01-01 12:00:00'),
                    ('capture', 'second', '2026-01-01 12:00:00')])
                self.assertEqual(elapsed, earlier_duration + 80)
                self.assertFalse(clock_path.exists())

    def test_run_frames_seeds_normal_cast_once_and_skips_preseeded_upgrade_cast(self):
        frames = self.helper['run_frames']
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            run = types.SimpleNamespace(root=root, home=root / 'home', evidence=root / 'evidence',
                                        meta={'sha': 'abc', 'sessions': {}})
            def cast(label):
                return {'label': label, 'workspace': 'code/rui', 'mode': 'bypass', 'messages': ['Ready']}
            scenario = {'sizes': ['80x24'], 'states': [
                {'name': 'plain', 'open': 'overview', 'cast': [cast('Plain')], 'steps': []},
                {'name': 'upgrade', 'upgrade': 'chat', 'open': 'overview', 'cast': [cast('Upgrade')], 'steps': []}]}
            path = root / 'recipe.json'
            path.write_text(json.dumps(scenario))
            events = []
            class Terminal:
                def __init__(self, *_args):
                    self.status = None
                    self.frame = types.SimpleNamespace(columns=80, lines=24)
                def settle_shot(self, **_kwargs):
                    return self.frame
                def close(self):
                    pass
                def resize(self, size):
                    self.frame = types.SimpleNamespace(columns=size[0], lines=size[1])
            def seed(_run, entries, *, ordered):
                events.append(('seed', [entry['label'] for entry in entries], ordered))
            @contextlib.contextmanager
            def upgrade(current, state, _build):
                if state.get('upgrade'):
                    events.append(('stage', [entry['label'] for entry in state['cast']]))
                    isolated = types.SimpleNamespace(**vars(current))
                    isolated._upgrade_seeded = True
                    yield isolated, state, None
                else:
                    yield current, state, None
            def capture(_run, _terminal, _out, state, _size, reason):
                return {'name': state['name'], 'size': '80x24', 'ok': True,
                        'status': 'ok', 'reason': reason, 'files': {}}
            replacements = {'Run': lambda _: run, 'cmd_new': lambda _: print(root),
                'cmd_cleanup': lambda _: None, 'load_build': lambda _: {'screen_library': '/test'},
                'require_screen': lambda _: None, 'require_upgrade_fixture_user': lambda: None,
                'upgrade_actor': lambda _: None, 'shots_fixture_env': lambda _: {},
                'FrameTerminal': Terminal, 'frame_upgrade_run': upgrade, 'seed_cast': seed,
                'frame_pause_owned_host': lambda *_: None, 'frame_initial_ready': lambda *_a, **_k: None,
                'frame_drive_upgrade': lambda *_: None, 'frame_upgrade_viewport': lambda *_: None,
                'frame_ready': lambda *_a, **_k: None, 'frame_capture': capture,
                'frame_upgrade_journey': lambda *_: None, 'frame_host_suspension': lambda *_: None,
                'frame_finish_held_upgrade': lambda *_: None, 'frames_index': lambda *_: None}
            args = argparse.Namespace(sha='abc', scenario=str(path), sizes=None, only=None,
                no_png=True, keep=False, record=False, shots_fixture=True, out=str(root / 'output'), timing=False)
            with patch.dict(frames.__globals__, replacements), patch.dict('os.environ'), \
                 contextlib.redirect_stdout(io.StringIO()):
                frames(args)
            self.assertEqual(events, [('seed', ['Plain'], True), ('stage', ['Upgrade'])])

    def test_suspended_message_annotation_requires_host_suspend(self):
        validate = self.helper['validate_scenario']
        def scenario(step):
            return {'sizes': ['80x24'], 'states': [
                {'name': 'first', 'open': 'overview', 'steps': [step]}]}
        validate(scenario({'host': 'suspend', 'shot_settle_message': True}))
        for step in ({'host': 'resume', 'shot_settle_message': True},
                     {'host': 'suspend', 'shot_settle_message': False},
                     {'sleep': 1, 'shot_settle_message': True}):
            with self.subTest(step=step), self.assertRaises(ValueError):
                validate(scenario(step))

    def test_suspended_shot_records_binding_before_stopping_host(self):
        suspend = self.helper['frame_host_suspension']
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            clock = self.helper['ShotsClock'](root / 'clock', 2)
            clock.next_cast()
            clock.cast_times['Witness'] = clock.current
            clock.reset()
            events = []
            def command(*args, **_kwargs):
                events.append(args[:2])
                return types.SimpleNamespace(returncode=0, stderr='', stdout='["prior"]')
            run = types.SimpleNamespace(_shot_clock=clock, _shot_open_label='Witness',
                evidence=root, rui_cmd=command, sid=lambda _: 'session1',
                owned=lambda: [{'kind': 'host', 'pid': 42, 'lstart': 'start'}])
            with patch.dict(suspend.__globals__, {'process_start': lambda _: ('start',),
                    'append_jsonl': lambda *_: None}), patch('os.kill', side_effect=lambda *_: events.append('stop')):
                suspend(run, True, settle_message=True)
            self.assertEqual(events, [('request', 'list'), 'stop'])
            self.assertEqual(run._shot_suspended['before'], {'prior'})
            self.assertEqual(run._shot_suspended['session'], 'session1')
            self.assertEqual(run._shot_suspended['at'], clock.cast_times['Witness'])

    def test_suspended_shot_recovers_exact_original_before_reset(self):
        resume = self.helper['frame_resume_settled_shot']
        for case in ('completed', 'ambiguous', 'recover-error', 'wrong-target', 'missing'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                directory = root / '.config/rui/requests'
                directory.mkdir(parents=True)
                handle = '11111111-1111-4111-8111-111111111111'
                other = '22222222-2222-4222-8222-222222222222'
                store = root / 'store'
                record = {'key': handle, 'kind': 'message', 'session': 'session1', 'store': str(store)}
                (directory / (handle + '.json')).write_text(json.dumps(record))
                if case == 'ambiguous':
                    (directory / (other + '.json')).write_text(json.dumps({**record, 'key': other}))
                clock = self.helper['ShotsClock'](root / 'clock', 2)
                clock.next_cast()
                cast_at = clock.current
                clock.reset()
                run = types.SimpleNamespace(home=root, store=store, _shot_clock=clock,
                    frame_suspended_host=object(),
                    _shot_suspended={'before': set(), 'session': 'session1', 'at': cast_at})
                events = []
                def command(*args, **kwargs):
                    events.append((args[:2], clock.path.read_text().strip()))
                    if args[:2] == ('request', 'list'):
                        return types.SimpleNamespace(returncode=0, stderr='', stdout=json.dumps([handle] + ([other] if case == 'ambiguous' else [])))
                    if args[:2] == ('request', 'recover'):
                        self.assertIn(str(directory / (handle + '.json')), [str(x) for x in args])
                        return types.SimpleNamespace(returncode=1 if case == 'recover-error' else 0, stderr='failed', stdout='')
                    observed = {'target': 'other' if case == 'wrong-target' else 'session1',
                                'kind': 'message', 'state': 'completed'}
                    return types.SimpleNamespace(returncode=0, stderr='', stdout=json.dumps({'observation': observed}))
                run.rui_cmd = command
                def suspension(_run, value):
                    self.assertFalse(value)
                    if _run.frame_suspended_host is not None:
                        events.append(('resume', clock.path.read_text().strip()))
                        _run.frame_suspended_host = None
                replacements = {'frame_host_suspension': suspension}
                if case == 'missing':
                    tick = iter((0, 11))
                    replacements['time'] = types.SimpleNamespace(monotonic=lambda: next(tick), sleep=lambda _: None)
                with patch.dict(resume.__globals__, replacements):
                    expectation = contextlib.nullcontext() if case == 'completed' else self.assertRaises(self.helper['FrameFailure'])
                    with expectation:
                        resume(run)
                self.assertEqual(clock.path.read_text(), '2026-01-01 12:00:00\n')
                self.assertIsNone(run.frame_suspended_host)
                self.assertEqual(sum(event[0] == 'resume' for event in events), 1)
                if case == 'completed':
                    self.assertEqual(events, [(('request', 'list'), '2026-01-01 12:00:00'),
                                              ('resume', '2026-01-01 11:59:59'),
                                              (('request', 'recover'), '2026-01-01 11:59:59'),
                                              (('request', 'inspect'), '2026-01-01 11:59:59')])
                if case in ('ambiguous', 'missing'):
                    self.assertFalse(any(event[0] == ('request', 'recover') for event in events))

    def test_explicit_resume_settles_shot_before_next_step(self):
        steps = self.helper['frame_steps']
        resume = self.helper['frame_resume_settled_shot']
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            directory = root / '.config/rui/requests'
            directory.mkdir(parents=True)
            handle = '11111111-1111-4111-8111-111111111111'
            store = root / 'store'
            record_path = directory / (handle + '.json')
            record_path.write_text(json.dumps({'key': handle, 'kind': 'message',
                'session': 'session1', 'store': str(store)}))
            clock = self.helper['ShotsClock'](root / 'clock', 2)
            clock.next_cast()
            cast_at = clock.current
            clock.reset()
            run = types.SimpleNamespace(home=root, store=store, _shot_clock=clock,
                frame_suspended_host=object(),
                _shot_suspended={'before': set(), 'session': 'session1', 'at': cast_at})
            events = []
            def command(*args, **_kwargs):
                events.append((args[:2], clock.path.read_text().strip()))
                if args[:2] == ('request', 'list'):
                    return types.SimpleNamespace(returncode=0, stderr='', stdout=json.dumps([handle]))
                if args[:2] == ('request', 'recover'):
                    self.assertIn(str(record_path), [str(arg) for arg in args])
                    return types.SimpleNamespace(returncode=0, stderr='', stdout='')
                return types.SimpleNamespace(returncode=0, stderr='', stdout=json.dumps({
                    'observation': {'target': 'session1', 'kind': 'message', 'state': 'completed'}}))
            run.rui_cmd = command
            def suspension(_run, value):
                self.assertFalse(value)
                if _run.frame_suspended_host is not None:
                    events.append(('resume', clock.path.read_text().strip()))
                    _run.frame_suspended_host = None
            with patch.dict(steps.__globals__, {'frame_host_suspension': suspension}):
                steps(run, types.SimpleNamespace(status=None), [{'host': 'resume'}])
                self.assertIsNone(run.frame_suspended_host)
                self.assertIsNone(run._shot_suspended)
                self.assertEqual(clock.path.read_text(), '2026-01-01 12:00:00\n')
                resume(run)  # Cleanup after explicit resume must not recover twice.
            self.assertEqual(events, [(('request', 'list'), '2026-01-01 12:00:00'),
                                      ('resume', '2026-01-01 11:59:59'),
                                      (('request', 'recover'), '2026-01-01 11:59:59'),
                                      (('request', 'inspect'), '2026-01-01 11:59:59')])

    def test_explicit_resume_without_shot_uses_regular_host_resume(self):
        steps = self.helper['frame_steps']
        run = types.SimpleNamespace(frame_suspended_host=object())
        calls = []
        with patch.dict(steps.__globals__, {'frame_host_suspension':
                lambda _run, suspended: calls.append((_run, suspended))}):
            steps(run, types.SimpleNamespace(status=None), [{'host': 'resume'}])
        self.assertEqual(calls, [(run, False)])

    def test_only_shots_pass_fixture_environment_before_host_start(self):
        frames = self.helper['run_frames']
        class Stopped(Exception):
            pass
        for shots in (False, True):
            with self.subTest(shots=shots), tempfile.TemporaryDirectory() as temp:
                path = Path(temp) / 'recipe.json'
                path.write_text(json.dumps({'sizes': ['80x24'], 'states': [
                    {'name': 'first', 'open': 'overview', 'first_frame': True, 'steps': []}]}))
                received = []
                def new(args):
                    received.append(args)
                    raise Stopped()
                args = argparse.Namespace(sha='abc', scenario=str(path), sizes=None, only=None,
                    no_png=True, keep=True, record=False, shots_fixture=shots)
                with patch.dict(frames.__globals__, {'cmd_new': new,
                        'load_build': lambda _: {'screen_library': '/test'}, 'require_screen': lambda _: None,
                        'shots_fixture_env': lambda _: {'fixture': 'shot'}}), \
                     patch.dict('os.environ'), contextlib.redirect_stdout(io.StringIO()), self.assertRaises(Stopped):
                    frames(args)
                self.assertEqual(received[0].frame_env, {'fixture': 'shot'} if shots else {})


if __name__ == '__main__':
    unittest.main()
