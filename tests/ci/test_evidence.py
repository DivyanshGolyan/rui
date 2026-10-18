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
    def test_suite_inputs_follow_generated_imports_and_fail_closed(self):
        import collect_inputs
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'src').mkdir()
            (root / 'src/logic.zig').write_text('logic')
            (root / 'src/prepare.sh').write_text('generator')
            manifests = {
                'binary': [dict(prefix=4, path='src/logic.zig'),
                           dict(prefix=2, path='o/generated/options.zig')],
                'generated': [dict(prefix=4, path='src/prepare.sh')],
            }
            closure = collect_inputs.closure(root, manifests, 'binary')
            self.assertEqual(closure, ['src/logic.zig', 'src/prepare.sh'])
            # An orphan generated file cannot be treated as independent source.
            del manifests['generated']
            with self.assertRaisesRegex(ValueError, 'generated'):
                collect_inputs.closure(root, manifests, 'binary')
            manifests['generated'] = [dict(prefix=2, path='o/binary/cycle')]
            with self.assertRaisesRegex(ValueError, 'cycle'):
                collect_inputs.closure(root, manifests, 'binary')
            manifests['generated'] = [dict(prefix=0, path='/unowned/native.h')]
            with self.assertRaisesRegex(ValueError, 'unowned'):
                collect_inputs.closure(root, manifests, 'binary')
            # WriteFile manifests have no file dependencies: their generated
            # contents, not an empty closure, carry configuration identity.
            generated = root / '.zig-cache/o/generated/options.zig'
            generated.parent.mkdir(parents=True)
            generated.write_text('first build option')
            manifests['generated'] = []
            first, second = {}, {}
            collect_inputs.closure(root, manifests, 'binary', external=first)
            generated.write_text('changed build option')
            collect_inputs.closure(root, manifests, 'binary', external=second)
            self.assertTrue(first)
            self.assertNotEqual(first, second)

    def test_unrelated_rebase_preserves_suite_key_but_inputs_and_bootstrap_invalidate(self):
        with tempfile.TemporaryDirectory() as directory:
            previous = Path.cwd()
            self.addCleanup(os.chdir, previous)
            os.chdir(directory)

            def commit(message):
                evidence.git('add', 'src', 'build.zig', 'build.zig.zon')
                evidence.git('commit', '-m', message)

            evidence.git('init', '-b', 'main')
            evidence.git('config', 'user.name', 'Evidence test')
            evidence.git('config', 'user.email', 'test@example.invalid')
            Path('src').mkdir()
            for name in ('logic.zig', 'host.zig', 'actor.zig'):
                Path('src', name).write_text(name)
            Path('build.zig').write_text('build')
            Path('build.zig.zon').write_text('pins')
            commit('base')
            evidence.git('branch', 'candidate')
            # A separate base commit really moves the tree; this is not an
            # empty-commit/same-tree test or a path-overlap assertion.
            Path('src/host.zig').write_text('unrelated Host correction')
            commit('base moves')
            evidence.git('checkout', 'candidate')
            Path('src/logic.zig').write_text('candidate logic change')
            commit('candidate change')
            root = Path('.zig-cache/o/ci-compiled')
            root.mkdir(parents=True)
            root.joinpath('ci-targets.json').write_text(json.dumps([
                dict(target='test-logic', executables=['logic', 'actor'])]))
            root.joinpath('ci-inputs.json').write_text(json.dumps({
                'logic': dict(files=['src/logic.zig'], external={'compiler/std': 'full-sha256'}),
                'actor': dict(files=['src/actor.zig'], external={}),
            }))
            before = evidence.suite_sources(['test-logic'])
            origin = evidence.git('rev-parse', 'HEAD')
            evidence.git('rebase', 'main')
            self.assertNotEqual(evidence.git('rev-parse', 'HEAD'), origin)
            self.assertEqual(evidence.suite_sources(['test-logic']), before)
            for path in ('src/logic.zig', 'src/actor.zig', 'build.zig', 'build.zig.zon'):
                old = Path(path).read_text()
                Path(path).write_text(old + ' changed')
                commit('changed ' + path)
                self.assertNotEqual(evidence.suite_sources(['test-logic']), before)
                Path(path).write_text(old)
                commit('restore ' + path)
            # The base movement is genuinely outside this suite's source set.
            self.assertNotEqual(evidence.source_files(origin)['src/host.zig'],
                                evidence.source_files('HEAD')['src/host.zig'])

    def test_acceptance_requires_the_complete_target_closure_not_the_entire_handoff(self):
        with tempfile.TemporaryDirectory() as directory:
            previous = Path.cwd()
            self.addCleanup(os.chdir, previous)
            os.chdir(directory)
            manifest = Path('.zig-cache/o/ci-compiled/ci-targets.json')
            manifest.parent.mkdir(parents=True)
            rows = [dict(target='test-logic', executables=['test-logic_tests', 'rui-allocation-actor']),
                    dict(target='test', executables=['test-tests', 'rui-allocation-actor'])]
            manifest.write_text(json.dumps(rows))
            self.assertEqual(evidence.target_executables(['test-logic']), [
                '.zig-cache/o/ci-compiled/rui-allocation-actor',
                '.zig-cache/o/ci-compiled/test-logic_tests'])
            self.assertEqual(evidence.target_executables(['test', 'test-logic']), [
                '.zig-cache/o/ci-compiled/rui-allocation-actor',
                '.zig-cache/o/ci-compiled/test-logic_tests',
                '.zig-cache/o/ci-compiled/test-tests'])
            for invalid in ([], rows + [rows[0]],
                            [dict(target='test-logic', executables=[])],
                            [dict(target='test-logic', executables=['../test'])],
                            [dict(target='test-logic', executables=['/tmp/test'])]):
                manifest.write_text(json.dumps(invalid))
                with self.assertRaises(ValueError):
                    evidence.target_executables(['test-logic'])
            manifest.unlink()
            with self.assertRaises(FileNotFoundError):
                evidence.target_executables(['test-logic'])

    def test_cpu_floor_is_bound_to_platform_and_acceptance_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            previous = Path.cwd()
            self.addCleanup(os.chdir, previous)
            os.chdir(directory)
            manifest = Path('.zig-cache/o/ci-compiled/ci-cpu.json')
            manifest.parent.mkdir(parents=True)
            manifest.with_name('ci-targets.json').write_text(json.dumps([
                dict(target='test', executables=['test-tests'])]))
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
            unrelated = executable.with_name('unrelated-native-test')
            unrelated.write_bytes(b'OpenSSL build date and random scratch path')
            unrelated.chmod(0o755)
            inputs = dict(tree='a' * 40, targets=['test'], part='all',
                          workflow='owner/repo/.github/workflows/check.yml',
                          event='push', branch='feature', tools='native-tools',
                          executables=[str(executable)])
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
            self.assertEqual(sorted(str(path) for path in Path('rui-evidence').rglob('*') if path.is_file()),
                             ['rui-evidence/evidence.json', 'rui-evidence/executables/native-test'])
            self.assertEqual(Path('rui-evidence/executables/native-test').read_bytes(), executable.read_bytes())

            def archive_for(value, payload=b'exact executable bytes'):
                stream = io.BytesIO()
                with zipfile.ZipFile(stream, 'w') as zipped:
                    zipped.writestr('evidence.json', json.dumps(value))
                    if payload is not None:
                        zipped.writestr('executables/native-test', payload)
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
                with self.assertRaises(ValueError):
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
                    with self.assertRaisesRegex(ValueError, 'No passing evidence'):
                        evidence.verify(data, metadata, run, inputs)
                # Rebuild nondeterminism cannot invalidate the exact retained
                # artifact that passed. It does not accept the new binary.
                executable.write_bytes(b'changed executable')
                unrelated.write_bytes(b'different timestamp and scratch path')
                self.assertEqual(evidence.verify(archive, artifact, run, inputs), receipt)
                executable.unlink()
                self.assertEqual(evidence.verify(archive, artifact, run, inputs), receipt)
                data, metadata = archive_for(receipt, b'changed retained executable')
                with self.assertRaisesRegex(ValueError, 'executable missing or changed'):
                    evidence.verify(data, metadata, run, inputs)
                data, metadata = archive_for(receipt, None)
                with self.assertRaisesRegex(ValueError, 'Unexpected evidence archive'):
                    evidence.verify(data, metadata, run, inputs)
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
                      event='push', branch='refs/heads/feature',
                      executables=['.zig-cache/o/ci-compiled/test'])
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
                zipped.writestr('executables/test', binary.read_bytes())
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
                          event='pull_request', branch='feature', executables=[str(binary)])
            run = dict(id=1, run_attempt=1, conclusion='success', event='pull_request',
                       head_sha=head, head_branch='feature', path='.github/workflows/check.yml',
                       head_repository=dict(full_name='owner/repo'),
                       pull_requests=[dict(base=dict(sha=base), head=dict(sha=head))])
            receipt = dict(inputs=inputs, run_id=1, run_attempt=1, verdict='passed', source_sha=source,
                           executables={str(binary): evidence.digest(binary)})
            stream = io.BytesIO()
            with zipfile.ZipFile(stream, 'w') as zipped:
                zipped.writestr('evidence.json', json.dumps(receipt))
                zipped.writestr('executables/test', binary.read_bytes())
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
                # Narrow identities still independently verify origin blobs,
                # both for real merge refs and direct push sources.
                for event in ('push', 'pull_request'):
                    scoped = dict(inputs, tree=None, event=event, sources=dict(
                        tracked={'feature': evidence.source_files(source)['feature']}, external={}))
                    origin_run = dict(run, event=event, head_sha=source if event == 'push' else head)
                    for valid in (True, False):
                        current = copy.deepcopy(scoped)
                        if not valid:
                            current['sources']['tracked']['feature'][1] = '0' * 40
                        value = dict(receipt, inputs=current)
                        stream = io.BytesIO()
                        with zipfile.ZipFile(stream, 'w') as zipped:
                            zipped.writestr('evidence.json', json.dumps(value))
                            zipped.writestr('executables/test', binary.read_bytes())
                        payload = stream.getvalue()
                        metadata = dict(artifact, digest='sha256:' + hashlib.sha256(payload).hexdigest())
                        if valid:
                            self.assertEqual(evidence.verify(payload, metadata, origin_run, current), value)
                        else:
                            with self.assertRaisesRegex(ValueError, 'transitive source inputs mismatch'):
                                evidence.verify(payload, metadata, origin_run, current)
