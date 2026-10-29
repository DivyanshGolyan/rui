"""Exercise the compiled handoff through the real restore and gate drivers."""
import contextlib
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import build_artifact
import run_selected


class HandoffTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        previous = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, previous)
        self.enterContext(patch.dict(os.environ, dict(
            RUNNER_TEMP=str(self.root), GITHUB_RUN_ID='123', GITHUB_RUN_ATTEMPT='2',
            GITHUB_REPOSITORY='owner/repo', GATE_LOG=str(self.root / 'gates'), GATE_EXIT='0',
            BUILD_EXIT='0', FLAKY=str(self.root / 'flaky'), ImageOS='ubuntu24', ImageVersion='20261012.334.1',
            GITHUB_STEP_SUMMARY=str(self.root / 'summary'),
            PATH=str(self.root) + os.pathsep + os.environ['PATH'])))
        self.inputs = dict(format=3, tree='same-tree', targets=['test'], system='Linux', machine='x86_64',
                           compiler='b' * 64)
        self.enterContext(patch.object(build_artifact, 'git', return_value='source'))
        self.enterContext(patch.object(build_artifact, 'identity',
                                       side_effect=lambda _, part: dict(copy.deepcopy(self.inputs), part=part)))
        binary = build_artifact.roots()['binaries'] / 'test-tests'
        binary.parent.mkdir(parents=True)
        binary.write_text('#!/bin/sh\necho producer >> "$GATE_LOG"\nexit "$GATE_EXIT"\n')
        binary.chmod(0o751)
        packages = build_artifact.roots()['packages']
        packages.mkdir()
        (packages / 'pinned-source').write_text('downloaded source')
        build_artifact.package(['test'], self.root / 'upload')
        self.receipt = json.loads((self.root / 'upload/compiled.json').read_text())
        self.archive = (self.root / 'upload/compiled.tar.gz').read_bytes()
        # A later rollout image on the consumer is logged, never compared.
        os.environ['ImageVersion'] = '20261018.339.1'
        # Local packages come from the hash-pinned fetch, not the download.
        fetch = self.root / 'src/fetch_dependencies.sh'
        fetch.parent.mkdir()
        fetch.write_text('mkdir -p zig-pkg && echo fetched > zig-pkg/pinned-source\n')
        # A child compiler stand-in emits a distinguishable executable; the real
        # gate driver executes whichever binary the handoff left in place.
        zig = self.root / 'zig'
        zig.write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import sys
if sys.argv[2] == 'ci-build':
    Path('compiled').write_text(' '.join(sys.argv[1:]))
    assert Path('zig-pkg/pinned-source').read_text() == 'fetched\\n'
    assert not Path('.zig-cache/o/ci-compiled').exists()
    if int(os.environ['BUILD_EXIT']):
        sys.exit(int(os.environ['BUILD_EXIT']))
    destination = Path(sys.argv[sys.argv.index('--prefix') + 1]) / 'bin'
    destination.mkdir(parents=True, exist_ok=True)
    binary = destination / 'test-tests'
    binary.write_text('#!/bin/sh\\necho consumer >> "$GATE_LOG"\\nexit "$GATE_EXIT"\\n')
    binary.chmod(0o755)
else:
    flaky = Path(os.environ['FLAKY'])
    if flaky.exists():
        flaky.unlink()
        sys.exit(9)
    sys.exit(subprocess.run(['.zig-cache/o/ci-compiled/test-tests']).returncode)
''')
        zig.chmod(0o755)
        self.real_run = subprocess.run
        self.enterContext(patch.object(build_artifact.subprocess, 'run', side_effect=self.download_or_run))
        self.enterContext(patch.object(build_artifact, 'api',
                                       side_effect=lambda path: self.downloads[path.split('/')[-1]][1]))
        self.refresh_download()

    def refresh_download(self):
        output = io.BytesIO()
        with zipfile.ZipFile(output, 'w') as zipped:
            zipped.writestr('compiled.json', json.dumps(self.receipt))
            zipped.writestr('compiled.tar.gz', self.archive)
        self.download = output.getvalue()
        self.metadata = dict(expired=False, workflow_run=dict(id=123),
                             digest='sha256:' + hashlib.sha256(self.download).hexdigest())
        self.downloads = {'101': (self.download, self.metadata)}

    def download_or_run(self, command, **kwargs):
        if command[:2] == ['gh', 'api']:
            kwargs['stdout'].write(self.downloads[command[2].split('/')[-2]][0])
            return subprocess.CompletedProcess(command, 0)
        return self.real_run(command, **kwargs)

    def gates(self, *options, targets='["test"]'):
        (self.root / 'gates').unlink(missing_ok=True)
        with patch.object(sys, 'argv', ['run_selected.py', targets,
                                       '--ci-artifacts', '.zig-cache/o/ci-compiled', *options]):
            run_selected.main()
        return (self.root / 'gates').read_text().splitlines()

    def test_matching_identity_executes_the_exact_producer_across_image_rollouts(self):
        build_artifact.restore(['101'], ['test'])
        self.assertEqual(self.gates(), ['producer'])
        self.assertFalse((self.root / 'compiled').exists())
        self.assertEqual((self.root / 'zig-pkg/pinned-source').read_text(), 'downloaded source')
        self.assertEqual(self.receipt['runner'], ['ubuntu24', '20261012.334.1'])
        self.assertIn('Using verified producer artifact 101', (self.root / 'summary').read_text())

    def test_identity_or_origin_mismatch_rebuilds_this_checkout_before_gates(self):
        original = copy.deepcopy(self.receipt)
        mismatches = [('inputs', field, value) for field, value in [
            ('tree', 'foreign-tree'), ('targets', ['test-full']), ('system', 'Darwin'),
            ('machine', 'arm64'), ('compiler', 'd' * 64), ('format', 2)]]
        mismatches += [(None, 'source_sha', 'foreign'), (None, 'run_id', 456), (None, 'run_attempt', 1)]
        for scope, field, value in mismatches:
            with self.subTest(field=field):
                self.receipt = copy.deepcopy(original)
                (self.receipt['inputs'] if scope else self.receipt)[field] = value
                self.refresh_download()
                (self.root / 'compiled').unlink(missing_ok=True)
                build_artifact.restore(['101'], ['test'])
                self.assertIn('-Dci-targets=test', (self.root / 'compiled').read_text())
                self.assertEqual(self.gates(), ['consumer'])
                self.assertIn('differs from this worker: Compiled', (self.root / 'summary').read_text())

    def test_corrupt_or_unsafe_downloads_are_never_executed(self):
        original = copy.deepcopy(self.receipt)
        unsafe = io.BytesIO()
        with tarfile.open(fileobj=unsafe, mode='w:gz') as output:
            member = tarfile.TarInfo('binaries/../../escaped')
            output.addfile(member)
        corruptions = [
            ('archive digest', dict(original, archive='0' * 64), None),
            ('executable hash', dict(original, executables={'binaries/test-tests': ['wrong', 0o751]}), None),
            ('missing field', {k: v for k, v in original.items() if k != 'executables'}, None),
            ('unsafe path', dict(original, archive=hashlib.sha256(unsafe.getvalue()).hexdigest()), unsafe.getvalue()),
        ]
        for name, receipt, archive in corruptions:
            with self.subTest(name=name):
                self.receipt, self.archive = receipt, archive or self.archive
                self.refresh_download()
                build_artifact.restore(['101'], ['test'])
                self.assertEqual(self.gates(), ['consumer'])
                self.assertIn('was rejected', (self.root / 'summary').read_text())
        self.assertFalse((self.root.parent / 'escaped').exists())
        for name, metadata in [('GitHub digest', dict(self.metadata, digest='sha256:' + '0' * 64)),
                               ('foreign run', dict(self.metadata, workflow_run=dict(id=999))),
                               ('expired', dict(self.metadata, expired=True))]:
            with self.subTest(name=name):
                self.downloads['101'] = (self.download, metadata)
                build_artifact.restore(['101'], ['test'])
                self.assertEqual(self.gates(), ['consumer'])

    def split_downloads(self):
        # Two producers: the unit binary alone, and everything else with packages.
        downloads = {}
        unit_root = self.root / 'unit-bin'
        unit_root.mkdir()
        (build_artifact.roots()['binaries'] / 'test-tests').rename(unit_root / 'test-tests')
        rest = build_artifact.roots()['binaries'] / 'ci-cpu.json'
        rest.write_text('{}')
        (build_artifact.roots()['binaries'] / 'test-logic_tests').write_text('#!/bin/sh\n')
        (build_artifact.roots()['binaries'] / 'test-logic_tests').chmod(0o755)
        for artifact, part, binaries in (('201', 'unit', unit_root), ('202', 'rest', None)):
            build_artifact.package(['test'], self.root / part, binaries, part)
            self.receipt = json.loads((self.root / part / 'compiled.json').read_text())
            self.archive = (self.root / part / 'compiled.tar.gz').read_bytes()
            self.refresh_download()
            downloads[artifact] = (self.download, self.metadata)
        self.downloads = downloads

    def test_split_producers_merge_into_one_verified_selection(self):
        self.split_downloads()
        build_artifact.restore(['202', '201'], ['test'])
        self.assertEqual(self.gates(), ['producer'])
        self.assertFalse((self.root / 'compiled').exists())
        self.assertEqual((self.root / 'zig-pkg/pinned-source').read_text(), 'downloaded source')
        self.assertTrue((build_artifact.roots()['binaries'] / 'test-logic_tests').exists())

    def test_a_missing_or_repeated_part_rebuilds_locally(self):
        self.split_downloads()
        for ids in (['202'], ['201'], ['201', '201']):
            with self.subTest(ids=ids):
                (self.root / 'compiled').unlink(missing_ok=True)
                build_artifact.restore(ids, ['test'])
                self.assertIn('-Dci-part=all', (self.root / 'compiled').read_text())
                self.assertEqual(self.gates(), ['consumer'])

    def test_failed_local_compilation_stops_with_its_exit_and_executes_nothing(self):
        self.receipt['inputs']['compiler'] = 'd' * 64
        self.refresh_download()
        with patch.dict(os.environ, BUILD_EXIT='37'), \
                patch.object(sys, 'argv', ['build_artifact.py', 'restore', '["test"]', '--artifact-id', '101']), \
                self.assertRaises(SystemExit) as failure:
            build_artifact.main()
        self.assertEqual(failure.exception.code, 37)
        self.assertFalse(build_artifact.roots()['binaries'].exists())
        self.assertFalse((self.root / 'gates').exists())

    def test_one_retry_only_when_requested(self):
        build_artifact.restore(['101'], ['test'])
        # A retryable shard reports its failure, reruns once and passes.
        (self.root / 'flaky').touch()
        # Capture the retry's ::warning so this job does not annotate a fake failure.
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(self.gates('--retry', targets='["test-logic"]'), ['producer'])
        self.assertIn('::warning::test-logic failed (exit 9); one automatic retry', output.getvalue())
        summary = (self.root / 'summary').read_text()
        self.assertIn('test-logic failed (exit 9); one automatic retry', summary)
        self.assertIn('test-logic passed on its automatic retry after failing', summary)
        # A persistent failure keeps the gate's own exit after one retry.
        with patch.dict(os.environ, GATE_EXIT='23'), self.assertRaises(SystemExit) as failure, \
                contextlib.redirect_stdout(io.StringIO()):
            self.gates('--retry', targets='["test-logic"]')
        self.assertEqual(failure.exception.code, 23)
        self.assertEqual((self.root / 'gates').read_text().splitlines(), ['producer'] * 2)
        # Without --retry (strict-path selections) the first failure stands.
        (self.root / 'flaky').touch()
        with self.assertRaises(SystemExit) as failure:
            self.gates(targets='["test-logic"]')
        self.assertEqual(failure.exception.code, 9)
        self.assertFalse((self.root / 'gates').exists())


if __name__ == '__main__':
    unittest.main()
