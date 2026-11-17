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
            with patch.dict('os.environ', {'VERIFY_RUI_FAKETIME_LIB': str(library)}), \
                 patch.object(fixture_env.__globals__['time'], 'time', return_value=1767268812):
                self.assertEqual(fixture_env(), {'LD_PRELOAD': str(library), 'FAKETIME': '-12s',
                    'FAKETIME_DONT_FAKE_MONOTONIC': '1', 'TZ': 'UTC', 'RUI_TEST_MEMORY_BYTES': '33554432'})
            with patch.dict('os.environ', {'VERIFY_RUI_FAKETIME_LIB': str(library / 'missing')}):
                with self.assertRaisesRegex(ValueError, 'requires libfaketime'):
                    fixture_env()

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
                        'shots_fixture_env': lambda: {'fixture': 'shot'}}), \
                     patch.dict('os.environ'), contextlib.redirect_stdout(io.StringIO()), self.assertRaises(Stopped):
                    frames(args)
                self.assertEqual(received[0].frame_env, {'fixture': 'shot'} if shots else {})


if __name__ == '__main__':
    unittest.main()
