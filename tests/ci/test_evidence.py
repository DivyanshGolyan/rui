import copy
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import evidence
import build_artifact


class EvidenceTest(unittest.TestCase):
    def test_compiled_handoff_checks_identity_digest_modes_and_safe_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            caches = {label: root / label for label in ('local', 'global', 'packages')}
            binary = caches['local'] / 'o/hash/test'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'exact compiled bytes')
            binary.chmod(0o751)
            for cache in caches.values():
                cache.mkdir(exist_ok=True)
            inputs = dict(tree='same-tree', targets=['test'], paths={k: str(v) for k, v in caches.items()})
            with patch.dict(os.environ, GITHUB_RUN_ID='123', GITHUB_RUN_ATTEMPT='2',
                            GITHUB_REPOSITORY='owner/repo'), \
                    patch.object(build_artifact, 'roots', return_value=caches), \
                    patch.object(build_artifact, 'identity', return_value=inputs), \
                    patch.object(evidence, 'git', return_value='source'):
                build_artifact.package(['test'], root / 'upload')
                receipt = json.loads((root / 'upload/compiled.json').read_text())
                archive = root / 'upload/compiled.tar.gz'
                # Restore over a contaminated cache and check real bytes/mode.
                binary.write_bytes(b'old worker bytes')
                build_artifact.unpack(archive, receipt, inputs)
                self.assertEqual(binary.read_bytes(), b'exact compiled bytes')
                self.assertEqual(binary.stat().st_mode & 0o777, 0o751)
                downloaded = io.BytesIO()
                with zipfile.ZipFile(downloaded, 'w') as output:
                    output.write(archive, 'compiled.tar.gz')
                    output.writestr('compiled.json', json.dumps(receipt))
                data = downloaded.getvalue()
                metadata = dict(expired=False, workflow_run=dict(id=123),
                                digest='sha256:' + hashlib.sha256(data).hexdigest())

                def download(command, *, stdout, **kwargs):
                    stdout.write(data)

                with patch.object(evidence, 'api', return_value=metadata), \
                        patch.object(build_artifact.subprocess, 'run', side_effect=download):
                    binary.write_bytes(b'contaminated')
                    build_artifact.restore('101', ['test'])
                    self.assertEqual(binary.read_bytes(), b'exact compiled bytes')
                    for changed in (dict(metadata, digest='sha256:' + '0' * 64),
                                    dict(metadata, workflow_run=dict(id=999)),
                                    dict(metadata, expired=True)):
                        with patch.object(evidence, 'api', return_value=changed), self.assertRaises(ValueError):
                            build_artifact.restore('101', ['test'])
                for field, value in [('run_attempt', 1), ('run_id', 456), ('source_sha', 'other'),
                                     ('verdict', 'passed'), ('archive', '0' * 64),
                                     ('executables', {'local/o/hash/test': ['wrong-hash', 0o751]})]:
                    with self.subTest(field=field), self.assertRaises(ValueError):
                        build_artifact.unpack(archive, dict(receipt, **{field: value}), inputs)
                with self.assertRaisesRegex(ValueError, 'inputs mismatch'):
                    build_artifact.unpack(archive, receipt, dict(inputs, targets=['test-full']))
                # Correct archive digests cannot authorize arbitrary extraction.
                for name, kind, link in [('local/../../escaped', tarfile.REGTYPE, ''),
                                         ('/tmp/escaped', tarfile.REGTYPE, ''),
                                         ('local/parent', tarfile.SYMTYPE, '/tmp'),
                                         ('local/device', tarfile.FIFOTYPE, ''),
                                         ('local/hardlink', tarfile.LNKTYPE, '/tmp')]:
                    with tarfile.open(archive, 'w:gz') as output:
                        member = tarfile.TarInfo(name)
                        member.type, member.linkname = kind, link
                        output.addfile(member)
                    with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'Unsafe compiled'):
                        build_artifact.unpack(archive, dict(receipt, archive=evidence.digest(archive)), inputs)
                # The SDK exception is exact, not permission for arbitrary links.
                with patch.object(build_artifact.os, 'uname') as uname, \
                        patch.object(build_artifact.subprocess, 'check_output', return_value='/SDK\n'):
                    uname.return_value.sysname = 'Darwin'
                    path = 'local/o/hash/pinned-transport-aarch64-macos/sdk/usr/include'
                    self.assertTrue(build_artifact.sdk_link(path, '/SDK/usr/include'))
                    self.assertFalse(build_artifact.sdk_link(path, '/other/usr/include'))
                    self.assertFalse(build_artifact.sdk_link('local/o/hash/elsewhere', '/SDK/usr/include'))

    def test_go_checks_cannot_reuse_unrelated_native_cache_artifacts(self):
        with patch.dict(os.environ, RUNNER_TEMP="/tmp", GITHUB_WORKFLOW_REF="owner/repo/check.yml@feature",
                        GITHUB_EVENT_NAME="push", GITHUB_REF="refs/heads/feature"), \
                patch.object(evidence, "git", return_value=""), \
                patch.object(evidence, "digest", return_value="cached-native-hash"), \
                patch.object(evidence.subprocess, "check_output", return_value="go version go1.27.1"), \
                self.assertRaisesRegex(ValueError, "fresh Go execution"):
            evidence.identity(["measurement-check"], "all")

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
                self.assertEqual(evidence.verify(archive, artifact,
                    dict(run, path=run['path'] + '@refs/heads/feature'), inputs), receipt)
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
                for verdict in ('compiled-not-tested', 'failed'):
                    data, metadata = archive_for(dict(receipt, verdict=verdict))
                    with self.assertRaisesRegex(ValueError, 'No passing executable evidence'):
                        evidence.verify(data, metadata, run, inputs)
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
