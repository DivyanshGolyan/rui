import hashlib
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


def shot(name, fingerprint, ok=True):
    return {'name': name, 'size': '80x24', 'ok': ok, 'reason': None if ok else 'failed',
            'fingerprint': fingerprint, 'files': {'html': name + '.html'}}


def write_shots(path, records):
    path.mkdir()
    (path / 'shots.json').write_text(json.dumps(records))
    for row in records:
        (path / row['files']['html']).write_text(row['name'])


class ShotsTest(unittest.TestCase):
    def setUp(self):
        self.module = runpy.run_path(str(SCRIPT))
        self.globals = self.module['cmd_shots'].__globals__

    def test_shots_rejects_directory_build_before_creating_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            directory = root / 'build'
            directory.mkdir()
            (directory / 'manifest.json').write_text(json.dumps({'sha': 'a' * 40}))
            for identifier in (str(directory), 'build', '../build'):
                with self.subTest(identifier=identifier):
                    args = argparse.Namespace(build=identifier, only=None, shard=None, out=str(root / 'out'),
                                              no_png=True, baseline=None)
                    with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                        self.module['cmd_shots'](args)
                    self.assertEqual(error.exception.code, 2)
                    self.assertFalse(Path(args.out).exists())

    def test_diff_orders_failures_and_omits_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            before, out = root / 'before', root / 'out'
            write_shots(before, [shot('same', 'a'), shot('changed', 'a'), shot('removed', 'a'), shot('fail', 'a')])
            write_shots(out, [shot('same', 'a'), shot('changed', 'b'), shot('new', 'b'), shot('fail', 'b', False)])
            self.module['shots_diff'](out, json.loads((out / 'shots.json').read_text()), before)
            diff = json.loads((out / 'diff.json').read_text())
            self.assertEqual(diff['same_count'], 1)
            for label, name in [('changed', 'changed'), ('new', 'new'), ('removed', 'removed'), ('failed', 'fail')]:
                self.assertEqual([row['name'] for row in diff[label]], [name])
            page = (out / 'index.html').read_text()
            self.assertLess(page.index('fail ·'), page.index('changed ·'))
            self.assertNotIn('same ·', page)
            self.assertEqual((out / 'baseline/fail.html').read_text(), 'fail')

    def test_merge_copies_files_and_rejects_overlap(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            a, b = root / 'a', root / 'b'
            write_shots(a, [shot('one', 'a')])
            write_shots(b, [shot('two', 'b')])
            args = argparse.Namespace(directories=[str(b), str(a)], out=str(root / 'out'), baseline=None)
            with contextlib.redirect_stdout(io.StringIO()):
                self.module['cmd_shots_merge'](args)
            self.assertEqual([r['name'] for r in json.loads((root / 'out/shots.json').read_text())], ['one', 'two'])
            self.assertEqual((root / 'out/one.html').read_text(), 'one')
            args.directories = [str(a), str(a)]
            args.out = str(root / 'bad')
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                self.module['cmd_shots_merge'](args)
            self.assertFalse((root / 'bad').exists())

    def test_shard_uses_recipe_order_and_tree_and_preserves_failure(self):
        scenario = json.loads(SCRIPT.with_name('frames.json').read_text())
        scenario['states'] = scenario['states'][:3]
        selected_name = scenario['states'][1]['name']
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'out'
            args = argparse.Namespace(build='tree-build', only=None, shard='2/2', out=str(out), no_png=True, baseline=None)
            captured = {}
            def frames(child):
                captured['only'] = child.only
                captured['timing'] = child.timing
                captured['shots_fixture'] = child.shots_fixture
                captured['recipe'] = json.loads(Path(child.scenario).read_text())
                Path(child.out, 'frames.json').write_text(json.dumps([{
                    'name': selected_name, 'size': '80x24', 'ok': False, 'reason': 'failed',
                    'cells_sha256': 'abc', 'files': {}}]))
                raise SystemExit(1)
            with patch.dict(self.globals, {'load_build': lambda _: {'source': '/repo', 'tree': 'tree123'},
                                          'run_frames': frames}), \
                 patch('subprocess.check_output', return_value=json.dumps(scenario)) as git, \
                 contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as error:
                self.module['cmd_shots'](args)
            self.assertEqual(error.exception.code, 1)
            self.assertEqual(captured['only'], selected_name)
            self.assertTrue(captured['timing'])
            self.assertTrue(captured['shots_fixture'])
            self.assertIn('tree123:.claude/skills/verify-rui/scripts/frames.json', git.call_args.args[0])
            self.assertTrue(all(not s['record'] for s in captured['recipe']['states']))
            self.assertEqual(json.loads((out / 'shots.json').read_text())[0]['fingerprint'], 'abc')

    def test_explicit_scenario_uses_tool_recipe_instead_of_build_source(self):
        scenario = json.loads(SCRIPT.with_name('frames.json').read_text())
        scenario['states'] = scenario['states'][:1]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            trusted_recipe = root / 'trusted.json'
            trusted_recipe.write_text(json.dumps(scenario))
            args = argparse.Namespace(build='tree-build', only=None, shard='2/2', out=str(root / 'out'),
                                      no_png=True, baseline=None, scenario=str(trusted_recipe))
            with patch.dict(self.globals, {'load_build': lambda _: {'source': '/untrusted', 'tree': 'tree123'}}), \
                 patch('subprocess.check_output') as git, contextlib.redirect_stdout(io.StringIO()):
                self.module['cmd_shots'](args)
            git.assert_not_called()
            metadata = json.loads((root / 'out/shots-meta.json').read_text())
            self.assertEqual(metadata['recipe_sha256'], hashlib.sha256(trusted_recipe.read_bytes()).hexdigest())

    def test_default_build_is_requested_and_empty_shard_skips_runner(self):
        scenario = json.loads(SCRIPT.with_name('frames.json').read_text())
        scenario['states'] = scenario['states'][:1]
        with tempfile.TemporaryDirectory() as tmp:
            args = argparse.Namespace(build=None, only=None, shard='2/2', out=str(Path(tmp) / 'out'),
                                      no_png=True, baseline=None)
            built = []
            def build(options):
                built.append(options)
                print(json.dumps({'sha': 'tree-123'}))
            def unexpected(_):
                self.fail('empty shard must not launch a run')
            with patch.dict(self.globals, {'cmd_build': build,
                    'load_build': lambda _: {'source': '/repo', 'tree': '123'}, 'run_frames': unexpected}), \
                 patch('subprocess.check_output', return_value=json.dumps(scenario)), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.module['cmd_shots'](args)
            self.assertTrue(built[0].here)
            self.assertTrue(built[0].upgrade)
            self.assertEqual(json.loads((Path(args.out) / 'shots.json').read_text()), [])

    def test_merge_failure_exits_one_and_preserves_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_shots(root / 'shard', [shot('broken', 'a', False)])
            args = argparse.Namespace(directories=[str(root / 'shard')], out=str(root / 'out'), baseline=None)
            with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as error:
                self.module['cmd_shots_merge'](args)
            self.assertEqual(error.exception.code, 1)
            self.assertEqual((root / 'out/broken.html').read_text(), 'broken')

    def test_partial_shots_scope_baseline_to_selected_states(self):
        scenario = json.loads(SCRIPT.with_name('frames.json').read_text())
        scenario['states'] = scenario['states'][:2]
        first, second = (s['name'] for s in scenario['states'])
        for only, shard in ((first, None), (None, '1/2'), (None, '3/3')):
            with self.subTest(only=only, shard=shard), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                baseline = root / 'baseline'
                records = [shot(first, 'old'), shot(second, 'bad', False)]
                extra = shot(first, 'old')
                extra['size'] = '46x30'
                extra['files'] = {'html': 'old-small.html'}
                write_shots(baseline, records + [extra])
                args = argparse.Namespace(build='tree-build', only=only, shard=shard, out=str(root / 'out'),
                                          no_png=True, baseline=str(baseline))
                def frames(child):
                    self.assertEqual(child.only, first)
                    (Path(child.out) / 'current.html').write_text('current')
                    Path(child.out, 'frames.json').write_text(json.dumps([{
                        'name': first, 'size': '80x24', 'ok': True, 'reason': None,
                        'cells_sha256': 'new', 'files': {'html': 'current.html'}}]))
                with patch.dict(self.globals, {'load_build': lambda _: {'source': '/repo', 'tree': 'tree'},
                                              'run_frames': frames}), \
                     patch('subprocess.check_output', return_value=json.dumps(scenario)), \
                     contextlib.redirect_stdout(io.StringIO()):
                    self.module['cmd_shots'](args)
                diff = json.loads((root / 'out/diff.json').read_text())
                if shard == '3/3':
                    self.assertEqual(diff, {'changed': [], 'new': [], 'removed': [], 'same_count': 0, 'failed': []})
                else:
                    self.assertEqual([row['name'] for row in diff['changed']], [first])
                    self.assertEqual([(row['name'], row['size']) for row in diff['removed']], [(first, '46x30')])
                    self.assertEqual(diff['failed'], [])
                self.assertFalse((root / 'out/baseline' / (second + '.html')).exists())

    def test_merge_baseline_reports_complete_diff_and_failure_first(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            baseline = root / 'baseline'
            write_shots(baseline, [shot('same', 'a'), shot('changed', 'a'), shot('removed', 'a'), shot('failed', 'a')])
            a, b = root / 'a', root / 'b'
            write_shots(a, [shot('same', 'a'), shot('changed', 'b')])
            write_shots(b, [shot('new', 'b'), shot('failed', 'b', False)])
            args = argparse.Namespace(directories=[str(a), str(b)], out=str(root / 'merged'), baseline=str(baseline))
            with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as error:
                self.module['cmd_shots_merge'](args)
            self.assertEqual(error.exception.code, 1)
            diff = json.loads((root / 'merged/diff.json').read_text())
            self.assertEqual(diff['same_count'], 1)
            for label, name in [('changed', 'changed'), ('new', 'new'), ('removed', 'removed'), ('failed', 'failed')]:
                self.assertEqual([row['name'] for row in diff[label]], [name])
            page = (root / 'merged/index.html').read_text()
            self.assertLess(page.index('failed ·'), page.index('changed ·'))
            self.assertNotIn('same ·', page)
            self.assertEqual((root / 'merged/baseline/failed.html').read_text(), 'failed')
            self.assertEqual((root / 'merged/failed.html').read_text(), 'failed')

    def test_merge_rejects_mixed_or_invalid_provenance_before_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            a, b = root / 'a', root / 'b'
            write_shots(a, [shot('one', '1')])
            write_shots(b, [shot('two', '2')])
            meta = {'build': 'build', 'tree': 'tree', 'recipe_sha256': 'a' * 64}
            (a / 'shots-meta.json').write_text(json.dumps(meta))
            args = argparse.Namespace(directories=[str(a), str(b)], out=str(root / 'out'), baseline=None)
            for second in (None, {**meta, 'build': 'other'}, {**meta, 'tree': 'other'},
                           {**meta, 'recipe_sha256': 'b' * 64}, {'build': 'broken'}):
                with self.subTest(second=second):
                    if second is None:
                        (b / 'shots-meta.json').unlink(missing_ok=True)
                    else:
                        (b / 'shots-meta.json').write_text(json.dumps(second))
                    with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                        self.module['cmd_shots_merge'](args)
                    self.assertEqual(error.exception.code, 2)
                    self.assertFalse(Path(args.out).exists())
            (b / 'shots-meta.json').write_text(json.dumps(meta))
            with contextlib.redirect_stdout(io.StringIO()):
                self.module['cmd_shots_merge'](args)
            self.assertEqual(json.loads((root / 'out/shots-meta.json').read_text()), {**meta, 'failed': False})

    def test_merge_accepts_matching_provenance_with_different_status_and_legacy_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            paths = [root / 'a', root / 'b', root / 'c']
            meta = {'build': 'build', 'tree': 'tree', 'recipe_sha256': 'a' * 64}
            for path, status in zip(paths, (None, False, True)):
                write_shots(path, [])
                (path / 'shots-meta.json').write_text(json.dumps(
                    meta if status is None else {**meta, 'failed': status}))
            args = argparse.Namespace(directories=[str(path) for path in paths], out=str(root / 'out'), baseline=None)
            with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as error:
                self.module['cmd_shots_merge'](args)
            self.assertEqual(error.exception.code, 1)
            self.assertEqual(json.loads((root / 'out/shots-meta.json').read_text()), {**meta, 'failed': True})

    def test_baseline_failure_produces_failure_exit_for_shots_and_merge(self):
        scenario = json.loads(SCRIPT.with_name('frames.json').read_text())
        scenario['states'] = scenario['states'][:1]
        name = scenario['states'][0]['name']
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            baseline = root / 'baseline'
            write_shots(baseline, [shot(name, 'old', False)])
            args = argparse.Namespace(build='tree-build', only=None, shard=None, out=str(root / 'out'),
                                      no_png=True, baseline=str(baseline))
            def frames(child):
                (Path(child.out) / 'current.html').write_text('current')
                Path(child.out, 'frames.json').write_text(json.dumps([{'name': name, 'size': '80x24',
                    'ok': True, 'reason': None, 'cells_sha256': 'new', 'files': {'html': 'current.html'}}]))
            with patch.dict(self.globals, {'load_build': lambda _: {'sha': 'build', 'source': '/repo', 'tree': 'tree'},
                                          'run_frames': frames}), \
                 patch('subprocess.check_output', return_value=json.dumps(scenario)), \
                 contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as error:
                self.module['cmd_shots'](args)
            self.assertEqual(error.exception.code, 1)
            meta = json.loads((root / 'out/shots-meta.json').read_text())
            self.assertEqual((meta['build'], meta['tree']), ('build', 'tree'))
            self.assertEqual(len(meta['recipe_sha256']), 64)
            self.assertTrue(meta['failed'])
            self.assertEqual(len(json.loads((root / 'out/diff.json').read_text())['failed']), 1)
            merge = argparse.Namespace(directories=[args.out], out=str(root / 'merged'), baseline=str(baseline))
            with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as error:
                self.module['cmd_shots_merge'](merge)
            self.assertEqual(error.exception.code, 1)
            self.assertEqual(len(json.loads((root / 'merged/diff.json').read_text())['failed']), 1)

    def test_run_failure_survives_merge_with_successful_or_empty_captures(self):
        scenario = json.loads(SCRIPT.with_name('frames.json').read_text())
        scenario['states'] = scenario['states'][:1]
        name = scenario['states'][0]['name']
        for has_capture in (False, True):
            for use_baseline in (False, True):
                with self.subTest(has_capture=has_capture, baseline=use_baseline), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    baseline = root / 'baseline'
                    write_shots(baseline, [])
                    args = argparse.Namespace(build='tree-build', only=None, shard=None, out=str(root / 'out'),
                                              no_png=True, baseline=None)
                    def frames(child):
                        rows = []
                        if has_capture:
                            rows.append({'name': name, 'size': '80x24', 'ok': True, 'reason': None,
                                         'cells_sha256': 'abc', 'files': {}})
                        Path(child.out, 'frames.json').write_text(json.dumps(rows))
                        raise SystemExit(1)
                    with patch.dict(self.globals, {'load_build': lambda _: {'source': '/repo', 'tree': 'tree'},
                                                  'run_frames': frames}), \
                         patch('subprocess.check_output', return_value=json.dumps(scenario)), \
                         contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as error:
                        self.module['cmd_shots'](args)
                    self.assertEqual(error.exception.code, 1)
                    self.assertTrue(json.loads((root / 'out/shots-meta.json').read_text())['failed'])
                    self.assertFalse((root / 'out/shots-status.json').exists())
                    merge = argparse.Namespace(directories=[args.out], out=str(root / 'merged'),
                                               baseline=str(baseline) if use_baseline else None)
                    with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as error:
                        self.module['cmd_shots_merge'](merge)
                    self.assertEqual(error.exception.code, 1)
                    self.assertTrue(json.loads((root / 'merged/shots-meta.json').read_text())['failed'])
                    merge.directories = [merge.out]
                    merge.out = str(root / 'again')
                    with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as error:
                        self.module['cmd_shots_merge'](merge)
                    self.assertEqual(error.exception.code, 1)

    def test_real_frames_failures_propagate_through_shots_and_merge(self):
        scenario = {'sizes': ['80x24'], 'states': [{'name': 'screen', 'open': 'overview', 'steps': []}]}
        for failure in ('capture', 'render', 'cleanup'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                run = types.SimpleNamespace(root=root, home=root / 'home', evidence=root / 'evidence',
                                            meta={'sha': 'abc', 'sessions': {}})
                args = argparse.Namespace(build='abc', only=None, shard=None, out=str(root / 'out'),
                                          no_png=failure != 'render', baseline=None)
                class Terminal:
                    def __init__(self, *_args):
                        self.frame = types.SimpleNamespace(columns=80, lines=24)
                    def close(self):
                        pass
                def capture(_run, _terminal, out, state, size, reason):
                    if failure == 'capture':
                        raise RuntimeError('capture failed')
                    name = 'screen@80x24.html'
                    (out / name).write_text('screen')
                    return {'name': state['name'], 'size': '80x24', 'files': {'html': name},
                            'status': 'ok', 'ok': True, 'reason': reason, 'note': '', 'sha': 'abc'}
                def cleanup(_):
                    if failure == 'cleanup':
                        raise SystemExit(1)
                def process(command, **_kwargs):
                    if command[-1] != '--check':
                        # Rendering can fail after producing a usable capture.
                        (Path(command[-1]).parent / 'screen@80x24.png').write_bytes(b'png')
                        return types.SimpleNamespace(returncode=1, stderr='render failed')
                    return types.SimpleNamespace(returncode=0, stderr='')
                @contextlib.contextmanager
                def upgrade(run, state, _build):
                    yield run, state, None
                replacements = {'Run': lambda _: run, 'cmd_new': lambda _: print(root),
                    'cmd_cleanup': cleanup, 'load_build': lambda _: {'source': '/repo', 'tree': 'tree',
                                                                      'screen_library': '/test'},
                    'require_screen': lambda _: None, 'FrameTerminal': Terminal, 'frame_upgrade_run': upgrade,
                    'seed_cast': lambda *_a, **_k: None, 'shots_fixture_env': lambda: {},
                    'frame_initial_ready': lambda *_a, **_k: None,
                    'frame_drive_upgrade': lambda *_: None, 'frame_steps': lambda *_a, **_k: False,
                    'frame_upgrade_viewport': lambda *_: None, 'frame_ready': lambda *_a, **_k: None,
                    'frame_capture': capture, 'frame_upgrade_journey': lambda *_: None,
                    'frame_host_suspension': lambda *_: None, 'frame_finish_held_upgrade': lambda *_: None}
                with patch.dict(self.globals, replacements), patch('subprocess.check_output', return_value=json.dumps(scenario)), \
                     patch('subprocess.run', side_effect=process), patch('shutil.which', return_value='/test/node'), \
                     contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()), \
                     self.assertRaises(SystemExit) as error:
                    self.module['cmd_shots'](args)
                self.assertEqual(error.exception.code, 1)
                records = json.loads((root / 'out/shots.json').read_text())
                self.assertEqual(records[0]['ok'], failure != 'capture')
                self.assertTrue(json.loads((root / 'out/shots-meta.json').read_text())['failed'])
                merge = argparse.Namespace(directories=[args.out], out=str(root / 'merged'), baseline=None)
                with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as error:
                    self.module['cmd_shots_merge'](merge)
                self.assertEqual(error.exception.code, 1)
                self.assertTrue(json.loads((root / 'merged/shots-meta.json').read_text())['failed'])

    def test_merge_validates_all_statuses_before_creating_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            a, b = root / 'a', root / 'b'
            write_shots(a, [])
            write_shots(b, [])
            (a / 'shots-meta.json').write_text(json.dumps({'failed': True}))
            args = argparse.Namespace(directories=[str(a), str(b)], out=str(root / 'out'), baseline=None)
            for invalid in ({'failed': 'false'}, {}, {'failed': False, 'extra': 1}):
                with self.subTest(invalid=invalid):
                    (b / 'shots-meta.json').write_text(json.dumps(invalid))
                    with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                        self.module['cmd_shots_merge'](args)
                    self.assertEqual(error.exception.code, 2)
                    self.assertFalse(Path(args.out).exists())

    def test_resize_failure_saves_last_committed_frame_and_timing(self):
        run_frames = self.module['run_frames']
        for actual in ((140, 40), (46, 30), None):
            with self.subTest(actual=actual), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                scenario = {'sizes': ['140x40', '46x30'], 'states': [
                    {'name': 'screen', 'open': 'overview', 'steps': []}]}
                recipe = root / 'recipe.json'
                recipe.write_text(json.dumps(scenario))
                run = types.SimpleNamespace(root=root, home=root / 'home', evidence=root / 'evidence',
                                            meta={'sha': 'abc', 'sessions': {}})
                args = argparse.Namespace(sha='abc', scenario=str(recipe), sizes=None, only=None,
                                          out=str(root / 'out'), no_png=True, keep=False, record=False,
                                          timing=True)
                captures = []
                class Terminal:
                    def __init__(self, *_args):
                        self.frame = types.SimpleNamespace(columns=140, lines=40)
                    def resize(self, _size):
                        if actual is None:
                            self.frame = None
                        else:
                            self.frame = types.SimpleNamespace(columns=actual[0], lines=actual[1])
                        raise RuntimeError('resize timed out')
                    def close(self):
                        captures.append('closed')
                def capture(_run, terminal, out, state, size, reason):
                    frame = terminal.frame
                    captures.append((size, (frame.columns, frame.lines), reason))
                    name = f"{state['name']}@{size[0]}x{size[1]}.html"
                    (out / name).write_text(f'{frame.columns}x{frame.lines}')
                    return {'name': state['name'], 'size': f'{size[0]}x{size[1]}',
                            'files': {'html': name}, 'status': 'failed' if reason else 'ok',
                            'ok': not bool(reason), 'reason': reason, 'note': '', 'sha': 'abc'}
                @contextlib.contextmanager
                def upgrade(run, state, _build):
                    yield run, state, None
                replacements = {'Run': lambda _: run, 'cmd_new': lambda _: print(root),
                    'cmd_cleanup': lambda _: None, 'load_build': lambda _: {'screen_library': '/test'},
                    'require_screen': lambda _: None, 'FrameTerminal': Terminal,
                    'frame_upgrade_run': upgrade, 'seed_cast': lambda *_a, **_k: None,
                    'frame_initial_ready': lambda *_a, **_k: None,
                    'frame_drive_upgrade': lambda *_: None, 'frame_steps': lambda *_a, **_k: False,
                    'frame_upgrade_viewport': lambda *_: None, 'frame_ready': lambda *_a, **_k: None,
                    'frame_capture': capture, 'frame_upgrade_journey': lambda *_: None,
                    'frame_host_suspension': lambda *_: None, 'frame_finish_held_upgrade': lambda *_: None}
                with patch.dict(run_frames.__globals__, replacements), patch.dict('os.environ'), \
                     contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()), \
                     self.assertRaises(SystemExit) as error:
                    run_frames(args)
                self.assertEqual(error.exception.code, 1)
                records = json.loads((root / 'out/frames.json').read_text())
                self.assertEqual(records[1]['size'], '46x30')
                self.assertFalse(records[1]['ok'])
                self.assertIn('resize timed out', records[1]['reason'])
                if actual:
                    self.assertEqual((root / 'out' / records[1]['files']['html']).read_text(),
                                     f'{actual[0]}x{actual[1]}')
                    if actual != (46, 30):
                        self.assertIn('last committed frame is 140x40; requested 46x30', records[1]['reason'])
                else:
                    self.assertEqual(records[1]['files'], {})
                timings = [json.loads(line) for line in (root / 'out/state-timings.jsonl').read_text().splitlines()]
                self.assertEqual([r['name'] for r in timings], ['screen'])
                self.assertGreaterEqual(timings[0]['elapsed_ns'], 0)
                self.assertEqual(captures[-1], 'closed')


if __name__ == '__main__':
    unittest.main()
