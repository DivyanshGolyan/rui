import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / '.claude/skills/verify-rui/scripts/verify-rui'


def git(repo, *args, env=None):
    return subprocess.check_output(['git', '-C', str(repo), *args], text=True, env=env).strip()


def setup(tmp_path):
    repo = tmp_path / 'repo'
    repo.mkdir()
    git(repo, 'init', '-q')
    git(repo, 'config', 'user.email', 'test@example.com')
    git(repo, 'config', 'user.name', 'Test')
    (repo / 'tracked').write_text('initial')
    (repo / '.gitignore').write_text('ignored\nzig-out/\n')
    git(repo, 'add', '.')
    git(repo, 'commit', '-qm', 'initial')
    bindir = tmp_path / 'tools'
    bindir.mkdir()
    zig = bindir / 'zig'
    zig.write_text('''#!/usr/bin/env python3
import os, pathlib, subprocess, sys
if sys.argv[1:] == ['version']:
    print('fake')
    raise SystemExit
with open(os.environ['ZIG_CALLS'], 'a') as f:
    f.write(' '.join(sys.argv[1:]) + '\\n')
if os.environ.get('TAG_DURING_BUILD') and sys.argv[1:2] == ['build']:
    subprocess.run(['git', 'tag', 'v1.2.3'], check=True)
if os.environ.get('MUTATE_DURING_BUILD') and sys.argv[1:2] == ['build']:
    pathlib.Path('tracked').write_text('changed during build')
if os.environ.get('MUTATE_DURING_ACTOR') and 'upgrade-fixture' in sys.argv:
    pathlib.Path('tracked').write_text('changed during actor build')
if '--prefix' in sys.argv:
    lib = pathlib.Path(sys.argv[sys.argv.index('--prefix') + 1]) / 'lib'
    lib.mkdir(parents=True, exist_ok=True)
    (lib / 'screen.so').write_text('screen')
out = pathlib.Path('zig-out/bin')
out.mkdir(parents=True, exist_ok=True)
(out / 'rui').write_text('binary')
(out / 'rui-upgrade-release-fixture').write_text('actor')
''')
    zig.chmod(0o755)
    env = dict(os.environ, VERIFY_RUI_CACHE=str(tmp_path / 'cache'),
               PATH=str(bindir) + os.pathsep + os.environ['PATH'], ZIG_CALLS=str(tmp_path / 'calls'))
    env.pop('RUI_BUILD_JOBS', None)
    return repo, tmp_path, env


def build(repo, env, *args):
    return subprocess.run([sys.executable, str(SCRIPT), 'build', '--here', '--no-screen', *args],
                          cwd=repo, env=env, text=True, capture_output=True, check=True)


def check_here_content_cache_and_index(tmp_path):
    repo, tmp, env = setup(tmp_path)
    (repo / 'tracked').write_text('modified')
    (repo / 'new').write_text('untracked')
    (repo / 'ignored').write_text('ignored')
    before = (repo / '.git/index').read_bytes()
    first = json.loads(build(repo, env, '--upgrade').stdout)
    assert first['sha'].startswith('tree-')
    assert first['head'] == git(repo, 'rev-parse', 'HEAD')
    assert first['dirty'] is True
    assert (repo / '.git/index').read_bytes() == before
    assert Path(first['upgrade_actor']['binary']).is_file()
    calls = (tmp / 'calls').read_text()
    assert f'-j{os.cpu_count() or 1}' in calls
    assert json.loads(build(repo, env, '--upgrade').stdout)['sha'] == first['sha']
    assert (tmp / 'calls').read_text() == calls
    (repo / 'ignored').write_text('still ignored')
    assert json.loads(build(repo, env).stdout)['sha'] == first['sha']
    (repo / 'new').write_text('changed')
    assert json.loads(build(repo, env).stdout)['sha'] != first['sha']


def check_here_out_jobs_and_load_build(tmp_path):
    repo, tmp, env = setup(tmp_path)
    env['RUI_BUILD_JOBS'] = '3'
    out = tmp / 'artifacts'
    record = json.loads(build(repo, env, '--out', str(out)).stdout)
    assert record['dirty'] is False
    assert Path(record['upgrade_actor']['binary']).is_file()
    manifest = out / 'manifest.json'
    assert manifest.exists()
    Path(record['upgrade_actor']['binary']).unlink()
    del record['upgrade_actor']
    manifest.write_text(json.dumps(record))
    assert Path(json.loads(build(repo, env, '--out', str(out)).stdout)['upgrade_actor']['binary']).is_file()
    assert '-j3' in (tmp / 'calls').read_text()
    loader = importlib.machinery.SourceFileLoader('verify_rui_build_test', str(SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    module.CACHE = tmp / 'cache'
    assert module.load_build(str(out))['sha'] == record['sha']
    default = json.loads(build(repo, env).stdout)
    assert module.load_build(default['sha'])['sha'] == default['sha']


class BuildHereTests(unittest.TestCase):
    def test_content_cache_and_index(self):
        with tempfile.TemporaryDirectory() as tmp:
            check_here_content_cache_and_index(Path(tmp))

    def test_force_added_ignored_file_is_in_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo, tmp, env = setup(Path(tmp))
            (repo / 'ignored').write_text('force staged')
            git(repo, 'add', '-f', 'ignored')
            before = (repo / '.git/index').read_bytes()
            record = json.loads(build(repo, env).stdout)
            self.assertEqual(git(repo, 'show', record['tree'] + ':ignored'), 'force staged')
            self.assertEqual((repo / '.git/index').read_bytes(), before)

    def test_cache_distinguishes_head_for_same_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo, tmp, env = setup(Path(tmp))
            first = json.loads(build(repo, env).stdout)
            calls = (tmp / 'calls').read_text()
            git(repo, 'commit', '--allow-empty', '-qm', 'same tree')
            second = json.loads(build(repo, env).stdout)
            self.assertNotEqual(first['sha'], second['sha'])
            self.assertNotEqual(first['head'], second['head'])
            self.assertEqual(second['head'], git(repo, 'rev-parse', 'HEAD'))
            self.assertFalse(second['dirty'])
            (repo / 'tracked').write_text('different committed tree')
            git(repo, 'add', 'tracked')
            git(repo, 'commit', '-qm', 'different tree')
            (repo / 'tracked').write_text('initial')
            third = json.loads(build(repo, env).stdout)
            self.assertNotEqual(first['sha'], third['sha'])
            self.assertEqual(third['head'], git(repo, 'rev-parse', 'HEAD'))
            self.assertTrue(third['dirty'])
            self.assertGreater(len((tmp / 'calls').read_text()), len(calls))

    def test_dirty_tree_then_committed_rebuilds(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo, tmp, env = setup(Path(tmp))
            (repo / 'tracked').write_text('new content')
            dirty = json.loads(build(repo, env).stdout)
            calls = (tmp / 'calls').read_text()
            git(repo, 'add', 'tracked')
            git(repo, 'commit', '-qm', 'commit same content')
            clean = json.loads(build(repo, env).stdout)
            self.assertEqual(dirty['tree'], clean['tree'])
            self.assertNotEqual(dirty['sha'], clean['sha'])
            self.assertTrue(dirty['dirty'])
            self.assertFalse(clean['dirty'])
            self.assertGreater(len((tmp / 'calls').read_text()), len(calls))

    def test_explicit_output_requires_force_for_new_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo, tmp, env = setup(Path(tmp))
            out = tmp / 'artifacts'
            first = json.loads(build(repo, env, '--out', str(out)).stdout)
            git(repo, 'commit', '--allow-empty', '-qm', 'new identity')
            result = subprocess.run([sys.executable, str(SCRIPT), 'build', '--here', '--no-screen',
                                     '--out', str(out)], cwd=repo, env=env, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('different build; use --force', result.stderr)
            self.assertEqual(json.loads((out / 'manifest.json').read_text())['sha'], first['sha'])
            replacement = json.loads(build(repo, env, '--out', str(out), '--force').stdout)
            self.assertNotEqual(first['sha'], replacement['sha'])
            self.assertEqual(replacement['head'], git(repo, 'rev-parse', 'HEAD'))

    def test_release_tag_changes_cache_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo, tmp, env = setup(Path(tmp))
            first = json.loads(build(repo, env).stdout)
            calls = (tmp / 'calls').read_text()
            self.assertIsNone(first['release_tag'])
            git(repo, 'tag', 'v1.2.3')
            tagged = json.loads(build(repo, env).stdout)
            self.assertEqual(tagged['release_tag'], 'v1.2.3')
            self.assertNotEqual(first['sha'], tagged['sha'])
            self.assertGreater(len((tmp / 'calls').read_text()), len(calls))
            calls = (tmp / 'calls').read_text()
            self.assertEqual(json.loads(build(repo, env).stdout)['sha'], tagged['sha'])
            self.assertEqual((tmp / 'calls').read_text(), calls)
            git(repo, 'tag', '-d', 'v1.2.3')
            self.assertEqual(json.loads(build(repo, env).stdout)['sha'], first['sha'])

    def test_pinned_build_rebuilds_when_tag_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo, tmp, env = setup(Path(tmp))
            head = git(repo, 'rev-parse', 'HEAD')
            command = [sys.executable, str(SCRIPT), 'build', head, '--source', str(repo), '--no-screen']
            def run():
                return json.loads(subprocess.run(command, cwd=repo, env=env, text=True,
                                                 capture_output=True, check=True).stdout)
            self.assertIsNone(run()['release_tag'])
            calls = (tmp / 'calls').read_text()
            git(repo, 'tag', 'v1.2.3')
            self.assertEqual(run()['release_tag'], 'v1.2.3')
            self.assertGreater(len((tmp / 'calls').read_text()), len(calls))

    def test_tag_change_during_build_rejects_manifest(self):
        for pinned in (False, True):
            with self.subTest(pinned=pinned), tempfile.TemporaryDirectory() as tmp:
                repo, tmp, env = setup(Path(tmp))
                env['TAG_DURING_BUILD'] = '1'
                identity = [git(repo, 'rev-parse', 'HEAD'), '--source', str(repo)] if pinned else ['--here']
                result = subprocess.run([sys.executable, str(SCRIPT), 'build', *identity, '--no-screen'],
                                        cwd=repo, env=env, text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('source changed', result.stderr)
                self.assertFalse(list((tmp / 'cache/builds').glob('*/manifest.json')))

    def test_screen_cache_upgrade_and_source_change(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo, tmp, env = setup(Path(tmp))
            build(repo, env)
            result = subprocess.run([sys.executable, str(SCRIPT), 'build', '--here'],
                                    cwd=repo, env=env, text=True, capture_output=True, check=True)
            self.assertTrue(Path(json.loads(result.stdout)['screen_library']).is_file())
            self.assertIn('screen-emulator', (tmp / 'calls').read_text())
        with tempfile.TemporaryDirectory() as tmp:
            repo, tmp, env = setup(Path(tmp))
            env['MUTATE_DURING_BUILD'] = '1'
            result = subprocess.run([sys.executable, str(SCRIPT), 'build', '--here', '--no-screen', '--upgrade'],
                                    cwd=repo, env=env, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('source changed', result.stderr)
        with tempfile.TemporaryDirectory() as tmp:
            repo, tmp, env = setup(Path(tmp))
            env['MUTATE_DURING_ACTOR'] = '1'
            result = subprocess.run([sys.executable, str(SCRIPT), 'build', '--here', '--no-screen'],
                                    cwd=repo, env=env, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('source changed', result.stderr)
            self.assertFalse(list((tmp / 'cache/builds').glob('*/manifest.json')))

    def test_output_jobs_and_load(self):
        with tempfile.TemporaryDirectory() as tmp:
            check_here_out_jobs_and_load_build(Path(tmp))


if __name__ == '__main__':
    unittest.main()
