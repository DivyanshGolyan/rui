import copy
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import evidence


class EvidenceTest(unittest.TestCase):
    def test_accepts_only_matching_inputs_origin_archive_and_executables(self):
        with tempfile.TemporaryDirectory() as directory:
            previous = Path.cwd()
            self.addCleanup(os.chdir, previous)
            os.chdir(directory)
            executable = Path('.zig-cache/o/0123/native-test')
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b'exact executable bytes')
            inputs = dict(tree='a' * 40, targets=['test'], part='all',
                          workflow='owner/repo/.github/workflows/check.yml',
                          event='push', branch='feature', tools='native-tools')
            run = dict(id=123, run_attempt=1, conclusion='success', event='push', head_sha='b' * 40,
                       path='.github/workflows/check.yml', head_branch='feature',
                       head_repository=dict(full_name='owner/repo'))
            receipt = dict(inputs=inputs, run_id=123, run_attempt=1, verdict='passed',
                           source_sha='b' * 40,
                           executables={str(executable): hashlib.sha256(executable.read_bytes()).hexdigest()})

            def archive_for(value):
                stream = io.BytesIO()
                with zipfile.ZipFile(stream, 'w') as zipped:
                    zipped.writestr('evidence.json', json.dumps(value))
                archive = stream.getvalue()
                artifact = dict(digest='sha256:' + hashlib.sha256(archive).hexdigest(),
                                workflow_run=dict(id=123))
                return archive, artifact

            archive, artifact = archive_for(receipt)
            with patch.dict(os.environ, GITHUB_REPOSITORY='owner/repo'), \
                    patch.object(evidence, 'api', return_value=dict(tree=dict(sha=inputs['tree']))):
                self.assertEqual(evidence.verify(archive, artifact, run, inputs), receipt)
                for field, value in [('conclusion', 'failure'), ('conclusion', 'cancelled'),
                                     ('event', 'pull_request'), ('head_branch', 'other'),
                                     ('head_sha', 'f' * 40),
                                     ('path', '.github/workflows/untrusted.yml'),
                                     ('head_repository', dict(full_name='fork/repo')),
                                     ('run_attempt', 2), ('id', 456)]:
                    with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                        evidence.verify(archive, artifact, dict(run, **{field: value}), inputs)
                for field, value in [('tree', 'c' * 40), ('targets', ['test-full']),
                                     ('part', 'execution'), ('tools', 'changed-sdk')]:
                    with self.subTest(input=field), self.assertRaises(ValueError):
                        evidence.verify(archive, artifact, run, dict(inputs, **{field: value}))
                for invalid in (dict(artifact, digest='sha256:' + '0' * 64),
                                dict(artifact, workflow_run=dict(id=456)), {}):
                    with self.assertRaises(ValueError):
                        evidence.verify(archive, invalid, run, inputs)
                executable.write_bytes(b'changed executable')
                with self.assertRaisesRegex(ValueError, 'executable missing or changed'):
                    evidence.verify(archive, artifact, run, inputs)
                executable.unlink()
                with self.assertRaisesRegex(ValueError, 'executable missing or changed'):
                    evidence.verify(archive, artifact, run, inputs)
                for invalid in ({}, {'../secret': 'ignored'}, {'/tmp/secret': 'ignored'}):
                    changed = copy.deepcopy(receipt)
                    changed['executables'] = invalid
                    data, metadata = archive_for(changed)
                    with self.assertRaises(ValueError):
                        evidence.verify(data, metadata, run, inputs)

    def test_source_tree_is_verified_independently_of_the_receipt(self):
        # A self-consistent artifact cannot supply its own source-tree oracle.
        inputs = dict(tree='expected', workflow='owner/repo/.github/workflows/check.yml',
                      event='push', branch='refs/heads/feature')
        with tempfile.TemporaryDirectory() as directory:
            previous = Path.cwd()
            self.addCleanup(os.chdir, previous)
            os.chdir(directory)
            binary = Path('.zig-cache/o/hash/test')
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'original')
            receipt = dict(inputs=inputs, run_id=1, run_attempt=1, verdict='passed', source_sha='original',
                           executables={str(binary): evidence.digest(binary)})
            stream = io.BytesIO()
            with zipfile.ZipFile(stream, 'w') as zipped:
                zipped.writestr('evidence.json', json.dumps(receipt))
            archive = stream.getvalue()
            artifact = dict(digest='sha256:' + hashlib.sha256(archive).hexdigest(), workflow_run=dict(id=1))
            run = dict(id=1, run_attempt=1, conclusion='success', event='push', head_branch='feature',
                       head_sha='original',
                       path='.github/workflows/check.yml', head_repository=dict(full_name='owner/repo'))
            with patch.dict(os.environ, GITHUB_REPOSITORY='owner/repo'), \
                    patch.object(evidence, 'api', return_value=dict(tree=dict(sha='different'))), \
                    self.assertRaisesRegex(ValueError, 'source tree mismatch'):
                evidence.verify(archive, artifact, run, inputs)

    def test_pr_source_requires_the_actual_origin_merge_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            previous = Path.cwd()
            self.addCleanup(os.chdir, previous)
            os.chdir(directory)

            def git(*args):
                return subprocess.check_output(['git', '-c', 'user.name=Evidence test',
                                                '-c', 'user.email=test@example.invalid', *args],
                                               text=True, stderr=subprocess.DEVNULL).strip()

            git('init', '-b', 'main')
            Path('base').write_text('base')
            git('add', '.')
            git('commit', '-m', 'base')
            base = git('rev-parse', 'HEAD')
            git('checkout', '-b', 'feature')
            Path('feature').write_text('candidate')
            git('add', '.')
            git('commit', '-m', 'candidate')
            head = git('rev-parse', 'HEAD')
            git('checkout', 'main')
            git('merge', '--no-ff', 'feature', '-m', 'merge')
            source, tree = git('rev-parse', 'HEAD'), git('rev-parse', 'HEAD^{tree}')
            # Fetch is real but local: both origin commits exist independently
            # of the artifact; no mock can supply the expected merge result.
            git('remote', 'add', 'origin', directory)
            binary = Path('.zig-cache/o/hash/test')
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'tested binary')
            inputs = dict(tree=tree, workflow='owner/repo/.github/workflows/check.yml',
                          event='pull_request', branch='feature')
            run = dict(id=1, run_attempt=1, conclusion='success', event='pull_request',
                       head_sha=head, head_branch='feature', path='.github/workflows/check.yml',
                       head_repository=dict(full_name='owner/repo'),
                       pull_requests=[dict(base=dict(sha=base), head=dict(sha=head))])
            receipt = dict(inputs=inputs, run_id=1, run_attempt=1, verdict='passed', source_sha=source,
                           executables={str(binary): evidence.digest(binary)})
            stream = io.BytesIO()
            with zipfile.ZipFile(stream, 'w') as zipped:
                zipped.writestr('evidence.json', json.dumps(receipt))
            data = stream.getvalue()
            artifact = dict(digest='sha256:' + hashlib.sha256(data).hexdigest(), workflow_run=dict(id=1))
            commit = dict(tree=dict(sha=tree), parents=[dict(sha=base), dict(sha=head)])
            with patch.dict(os.environ, GITHUB_REPOSITORY='owner/repo'), \
                    patch.object(evidence, 'api', return_value=commit):
                self.assertEqual(evidence.verify(data, artifact, run, inputs), receipt)
                # A self-consistent receipt claiming a candidate different from
                # the origin run cannot pass merely by naming its tree.
                other = dict(run, head_sha=base,
                             pull_requests=[dict(base=dict(sha=base), head=dict(sha=base))])
                with self.assertRaisesRegex(ValueError, 'merge parents mismatch'):
                    evidence.verify(data, artifact, other, inputs)
                forged = dict(tree=dict(sha=tree), parents=[dict(sha=base), dict(sha=base)])
                with patch.object(evidence, 'api', return_value=forged), \
                        self.assertRaisesRegex(ValueError, 'merge tree mismatch'):
                    evidence.verify(data, artifact, other, inputs)
