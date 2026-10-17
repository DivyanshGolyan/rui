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
    def test_cpu_floor_is_bound_to_platform_and_acceptance_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            previous = Path.cwd()
            self.addCleanup(os.chdir, previous)
            os.chdir(directory)
            manifest = Path('.zig-cache/o/ci-compiled/ci-cpu.json')
            manifest.parent.mkdir(parents=True)
            with patch.dict(os.environ, RUNNER_TEMP=directory, GITHUB_EVENT_NAME='push',
                            GITHUB_WORKFLOW_REF='owner/repo/.github/workflows/check.yml@feature',
                            GITHUB_REF='refs/heads/feature'), \
                    patch.object(evidence, 'git', return_value=''), \
                    patch.object(evidence, 'digest', return_value='tool-hash'):
                for system, machine, arch, model in [('Linux', 'x86_64', 'x86_64', 'x86_64'),
                                                     ('Darwin', 'arm64', 'aarch64', 'apple_m1')]:
                    with self.subTest(system=system), \
                            patch.object(evidence.platform, 'system', return_value=system), \
                            patch.object(evidence.platform, 'machine', return_value=machine):
                        floor = dict(policy='baseline', arch=arch, model=model)
                        self.assertEqual(evidence.identity(['test'], 'all', compiled=True)['cpu'], floor)
                        cpu = dict(floor, features='012345')
                        manifest.write_text(json.dumps(cpu))
                        self.assertEqual(evidence.identity(['test'], 'all')['cpu'], cpu)
                        for changed in (dict(cpu, policy='native'), dict(cpu, model='newer-producer'),
                                        dict(cpu, arch='wrong-architecture')):
                            manifest.write_text(json.dumps(changed))
                            with self.assertRaisesRegex(ValueError, 'CPU identity mismatch'):
                                evidence.identity(['test'], 'all')
                        manifest.unlink()
                        with self.assertRaises(FileNotFoundError):
                            evidence.identity(['test'], 'all')

    def test_compiled_handoff_checks_identity_digest_modes_and_safe_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            caches = {label: root / label for label in ('binaries', 'packages')}
            binary = caches['binaries'] / 'test-tests'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'exact compiled bytes')
            binary.chmod(0o751)
            for cache in caches.values():
                cache.mkdir(exist_ok=True)
            inputs = dict(tree='same-tree', targets=['test'])
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
                                     ('executables', {'binaries/test-tests': ['wrong-hash', 0o751]})]:
                    with self.subTest(field=field), self.assertRaises(ValueError):
                        build_artifact.unpack(archive, dict(receipt, **{field: value}), inputs)
                with self.assertRaisesRegex(ValueError, 'inputs mismatch'):
                    build_artifact.unpack(archive, receipt, dict(inputs, targets=['test-full']))
                # Correct archive digests cannot authorize arbitrary extraction.
                for name, kind, link in [('binaries/../../escaped', tarfile.REGTYPE, ''),
                                         ('/tmp/escaped', tarfile.REGTYPE, ''),
                                         ('binaries/parent', tarfile.SYMTYPE, '/tmp'),
                                         ('binaries/device', tarfile.FIFOTYPE, ''),
                                         ('binaries/hardlink', tarfile.LNKTYPE, '/tmp')]:
                    with tarfile.open(archive, 'w:gz') as output:
                        member = tarfile.TarInfo(name)
                        member.type, member.linkname = kind, link
                        output.addfile(member)
                    with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'Unsafe compiled'):
                        build_artifact.unpack(archive, dict(receipt, archive=evidence.digest(archive)), inputs)

    def test_go_checks_cannot_reuse_unrelated_native_cache_artifacts(self):
        with patch.dict(os.environ, RUNNER_TEMP="/tmp", GITHUB_WORKFLOW_REF="owner/repo/check.yml@feature",
                        GITHUB_EVENT_NAME="push", GITHUB_REF="refs/heads/feature"), \
                patch.object(evidence, "git", return_value=""), \
                patch.object(evidence, "digest", return_value="cached-native-hash"), \
                patch.object(evidence.subprocess, "check_output", return_value="go version go1.27.1"), \
                self.assertRaisesRegex(ValueError, "fresh Go execution"):
            evidence.identity(["measurement-check"], "all")

    def test_temporary_native_helpers_cannot_reuse_product_binary_receipts(self):
        # Both a reported caller and an analogous H2 caller compile helpers via
        # host_process; sanitizer and future unknown gates fail closed as well.
        for targets, part in [(['check-full'], 'execution'), (['check-full'], 'callers'),
                              (['host-launch-integration'], 'all'),
                              (['transport-h2-integration'], 'all'),
                              (['future-native-gate'], 'all')]:
            with self.subTest(targets=targets, part=part), \
                    self.assertRaisesRegex(ValueError, 'temporary native helpers'):
                evidence.identity(targets, part)

    def test_accepts_only_matching_inputs_origin_archive_and_executables(self):
        with tempfile.TemporaryDirectory() as directory:
            previous = Path.cwd()
            self.addCleanup(os.chdir, previous)
            os.chdir(directory)
            executable = Path('.zig-cache/o/ci-compiled/native-test')
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b'exact executable bytes')
            executable.chmod(0o755)
            bootstrap = Path('.zig-cache/o/worker-local/configurer')
            bootstrap.parent.mkdir(parents=True)
            bootstrap.write_bytes(b'worker-specific compiler bootstrap')
            bootstrap.chmod(0o755)
            inputs = dict(tree='a' * 40, targets=['test'], part='all',
                          workflow='owner/repo/.github/workflows/check.yml',
                          event='push', branch='feature', tools='native-tools')
            run = dict(id=123, run_attempt=1, conclusion='success', event='push', head_sha='b' * 40,
                       path='.github/workflows/check.yml', head_branch='feature',
                       head_repository=dict(full_name='owner/repo'))
            with patch.dict(os.environ, RUNNER_TEMP=directory, GITHUB_RUN_ID='123',
                            GITHUB_RUN_ATTEMPT='1', GITHUB_OUTPUT=str(Path(directory) / 'outputs')), \
                    patch.object(evidence, 'git', return_value='b' * 40):
                evidence.record(inputs)
            receipt = json.loads(Path('rui-evidence/evidence.json').read_text())
            self.assertEqual(receipt['executables'],
                             {str(executable): hashlib.sha256(executable.read_bytes()).hexdigest()})

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
                bootstrap.write_bytes(b'another worker-specific bootstrap')
                self.assertEqual(evidence.verify(archive, artifact, run, inputs), receipt)
                data, metadata = archive_for(dict(receipt,
                    executables={str(bootstrap): evidence.digest(bootstrap)}))
                with self.assertRaisesRegex(ValueError, 'Foreign executable path'):
                    evidence.verify(data, metadata, run, inputs)
                bootstrap.unlink()
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
                for invalid in ({}, {'../secret': 'ignored'}, {'/tmp/secret': 'ignored'},
                                {str(bootstrap): 'ignored'},
                                {'.zig-cache/o/ci-compiled-extra/test': 'ignored'},
                                {'.zig-cache/o/ci-compiled/nested/test': 'ignored'}):
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
            binary = Path('.zig-cache/o/ci-compiled/test')
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
            binary = Path('.zig-cache/o/ci-compiled/test')
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
                # GitHub updates nested PR metadata when the branch advances,
                # even on historical runs; run.head_sha remains immutable.
                advanced = dict(run, pull_requests=[dict(base=dict(sha=base),
                                                         head=dict(sha='newer-pr-head'))])
                self.assertEqual(evidence.verify(data, artifact, advanced, inputs), receipt)
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
