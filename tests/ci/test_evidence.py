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

import evidence
import build_artifact
import suite_inputs


class SuiteInputsTest(unittest.TestCase):
    def setUp(self):
        owner = suite_inputs.Source('HEAD')
        build_sources = {name: (owner.read(name), owner.entries[name])
                         for name in suite_inputs.build_files(owner)}
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        previous = Path.cwd()
        self.addCleanup(os.chdir, previous)
        os.chdir(temporary.name)
        self.git('init', '-b', 'main')
        for name in suite_inputs.POLICY:
            self.write(name, 'reviewed policy')
        for name, (data, mode) in build_sources.items():
            path = Path(name)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            path.chmod(0o755 if mode == '100755' else 0o644)
        self.write('src/logic_tests.zig', 'test { _ = @import("core.zig"); }')
        self.write('src/core.zig', 'const leaf = @import("leaf.zig");')
        self.write('src/leaf.zig', 'pub const answer = 41;')
        self.write('src/tests.zig', 'test { _ = @import("core.zig"); }')
        self.write('tests/integration/answer_renderer_allocation.zig', 'pub fn main() void {}')
        self.write('tests/integration/fixture.json', '{"asymmetric": 7}')
        self.write('src/SessionFrontend.zig', 'pub const unrelated_renderer = 1;')
        self.trusted = self.commit()
        self.git('update-ref', 'refs/remotes/origin/main', self.trusted)

    def git(self, *args):
        return subprocess.check_output(['git', '-c', 'user.name=Evidence test',
                                        '-c', 'user.email=test@example.invalid', *args],
                                       text=True, stderr=subprocess.DEVNULL).strip()

    def write(self, name, text):
        path = Path(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self):
        self.git('add', '.')
        self.git('commit', '-m', 'input revision')
        return self.git('rev-parse', 'HEAD')

    def test_rebase_reuses_only_unchanged_transitive_inputs(self):
        original = suite_inputs.source_inputs(['test-logic'], 'all')
        self.git('checkout', '-b', 'candidate')
        self.write('src/unreachable.zig', 'pub const unrelated = 17;')
        candidate = self.commit()
        self.git('checkout', 'main')
        self.write('src/SessionFrontend.zig', 'pub const unrelated_renderer = 2;')
        self.commit()
        self.git('checkout', 'candidate')
        self.git('rebase', 'main')
        self.assertNotEqual(self.git('rev-parse', 'HEAD'), candidate)
        self.assertEqual(suite_inputs.source_inputs(['test-logic'], 'all'), original)
        self.write('src/leaf.zig', 'pub const answer = 42;')
        self.commit()
        self.assertNotEqual(suite_inputs.source_inputs(['test-logic'], 'all'), original)
        # Independently reconstruct the origin, never trust its claimed hashes.
        self.assertEqual(suite_inputs.source_inputs(['test-logic'], 'all', self.trusted), original)

    def test_retained_receipt_is_verified_against_origin_after_an_unrelated_rebase(self):
        self.git('remote', 'add', 'origin', str(Path.cwd()))
        Path('.git/info/exclude').write_text('.zig-cache/\n.retained/\n')
        binary = Path('.zig-cache/o/ci-compiled/test-logic_tests')
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b'original executed artifact, not a rebuild')
        binary.chmod(0o755)
        inputs = dict(format=3, source=suite_inputs.source_inputs(['test-logic'], 'all'),
                      targets=['test-logic'], part='all', executables=[str(binary)],
                      event='push', branch='main', workflow='owner/repo/.github/workflows/check.yml')
        run = dict(id=123, run_attempt=1, conclusion='success', event='push', head_sha=self.trusted,
                   path='.github/workflows/check.yml', head_branch='main',
                   head_repository=dict(full_name='owner/repo'))
        retained = Path('.retained').resolve()
        retained.mkdir()
        with patch.dict(os.environ, RUNNER_TEMP=str(retained), GITHUB_RUN_ID='123',
                        GITHUB_RUN_ATTEMPT='1', GITHUB_OUTPUT=str(retained / 'output')):
            evidence.record(inputs)
        receipt = json.loads((retained / 'rui-evidence/evidence.json').read_text())

        def archive_for(value):
            data = io.BytesIO()
            with zipfile.ZipFile(data, 'w') as zipped:
                zipped.writestr('evidence.json', json.dumps(value))
                zipped.writestr('executables/' + binary.name, b'original executed artifact, not a rebuild')
            archive = data.getvalue()
            return archive, dict(digest='sha256:' + hashlib.sha256(archive).hexdigest(), workflow_run=dict(id=123))

        archive, artifact = archive_for(receipt)
        origin_commit = dict(tree=dict(sha=self.git('rev-parse', self.trusted + '^{tree}')))
        self.write('src/SessionFrontend.zig', 'pub const unrelated_renderer = 19;')
        self.commit()
        self.assertNotEqual(self.git('rev-parse', 'HEAD^{tree}'), receipt['source_tree'])
        binary.write_bytes(b'nondeterministic new build is NOT accepted')
        with patch.dict(os.environ, GITHUB_REPOSITORY='owner/repo'), \
                patch.object(evidence, 'api', return_value=origin_commit):
            self.assertEqual(evidence.verify(archive, artifact, run, inputs), receipt)
            self.write('src/leaf.zig', 'pub const answer = 99;')
            self.commit()
            changed = dict(inputs, source=suite_inputs.source_inputs(['test-logic'], 'all'))
            with self.assertRaisesRegex(ValueError, 'inputs or run identity mismatch'):
                evidence.verify(archive, artifact, run, changed)
            # Even a self-consistent forged manifest cannot replace origin bytes.
            forged, metadata = archive_for(dict(receipt, inputs=changed))
            with self.assertRaisesRegex(ValueError, 'Origin suite input closure mismatch'):
                evidence.verify(forged, metadata, run, changed)

    def test_fixture_runner_and_build_changes_invalidate_or_refuse_reuse(self):
        original = suite_inputs.source_inputs(['test-logic'], 'all')
        for name in ('tests/integration/fixture.json', 'tests/ci/test_evidence.py'):
            with self.subTest(name=name):
                self.write(name, 'changed input')
                self.commit()
                self.assertNotEqual(suite_inputs.source_inputs(['test-logic'], 'all'), original)
        self.write('build.zig', 'candidate-authored gate deletion')
        self.commit()
        with self.assertRaisesRegex(ValueError, 'policy differs from trusted main'):
            suite_inputs.source_inputs(['test-logic'], 'all')
        self.git('update-ref', 'refs/remotes/origin/main', 'HEAD')
        with self.assertRaisesRegex(ValueError, 'no reviewed suite-input declaration'):
            suite_inputs.source_inputs(['test-logic'], 'all')

    def test_native_include_or_bootstrap_change_cannot_acquire_undeclared_inputs(self):
        self.write('native-config.h', '#define NATIVE_VALUE 41\n')
        self.commit()
        self.git('checkout', '-b', 'candidate')
        self.write('src/bash_platform.c', '#include "../native-config.h"\nint value = NATIVE_VALUE;\n')
        self.commit()
        # Reject this new consumer before it can publish a reusable origin.
        with self.assertRaisesRegex(ValueError, 'no reviewed suite-input declaration'):
            suite_inputs.source_inputs(['test-full'], 'all')
        self.git('checkout', 'main')
        self.write('native-config.h', '#define NATIVE_VALUE 99\n')
        self.commit()
        self.git('checkout', 'candidate')
        self.git('rebase', 'main')
        self.git('update-ref', 'refs/remotes/origin/main', 'HEAD')
        with self.assertRaisesRegex(ValueError, 'no reviewed suite-input declaration'):
            suite_inputs.source_inputs(['test-full'], 'all')
        # The same owner covers scripts that could start reading new inputs.
        self.git('checkout', self.trusted, '--', 'src/bash_platform.c')
        self.write('src/prepare_vaxis.sh', 'cat ../undeclared-native-input\n')
        self.commit()
        with self.assertRaisesRegex(ValueError, 'no reviewed suite-input declaration'):
            suite_inputs.source_inputs(['test-logic'], 'all')

    def test_missing_undeclared_and_computed_dependencies_fail_closed(self):
        for text, message in [('const x = @import("missing.zig");', 'missing tracked input'),
                              ('const x = @import("undeclared");', 'Undeclared module'),
                              ('const x = @import(computed);', 'computed dependency'),
                              ('const x = @embedFile(computed);', 'computed dependency'),
                              ('const x = @cImport({ @cInclude("../native.h"); });', 'Undeclared native dependency')]:
            with self.subTest(text=text):
                self.write('src/leaf.zig', text)
                self.commit()
                with self.assertRaisesRegex(ValueError, message):
                    suite_inputs.source_inputs(['test-logic'], 'all')
        self.write('tests/ci/suite_inputs.py', 'candidate manifest says no dependencies')
        self.commit()
        with self.assertRaisesRegex(ValueError, 'policy differs from trusted main'):
            suite_inputs.source_inputs(['test-logic'], 'all')

    def test_suite_environment_and_always_fresh_boundaries(self):
        ordinary = suite_inputs.source_inputs(['test'], 'all')
        long = suite_inputs.source_inputs(['test-full'], 'all')
        self.assertEqual(ordinary['declarations']['test']['environment']['RUI_TEST_EXACT_INACTIVITY'], '0')
        self.assertEqual(long['declarations']['test-full']['environment']['RUI_TEST_EXACT_INACTIVITY'], '1')
        for targets, part in [(['check-full'], 'all'), (['test-logic', 'check-full'], 'execution'),
                              (['terminal-restoration-integration'], 'all'), (['final-mac'], 'all'),
                              (['future-suite'], 'all')]:
            with self.subTest(targets=targets), self.assertRaisesRegex(ValueError, 'fresh execution'):
                suite_inputs.source_inputs(targets, part)

    def test_toolchain_content_hash_does_not_trust_inode_or_mtime(self):
        directory = Path('compiler-lib')
        directory.mkdir()
        path = directory / 'transitive-header.h'
        path.write_bytes(b'old')
        metadata = path.stat()
        original = evidence.directory_digest(directory)
        path.write_bytes(b'new')
        os.utime(path, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
        self.assertEqual(path.stat().st_ino, metadata.st_ino)
        self.assertEqual(path.stat().st_mtime_ns, metadata.st_mtime_ns)
        self.assertNotEqual(evidence.directory_digest(directory), original)
        path.unlink()
        with self.assertRaisesRegex(ValueError, 'Empty toolchain'):
            evidence.directory_digest(directory)


class EvidenceTest(unittest.TestCase):
    def test_repository_suite_closures_include_renderer_test_imports(self):
        previous = Path.cwd()
        self.addCleanup(os.chdir, previous)
        os.chdir(Path(__file__).resolve().parents[2])
        revision = evidence.git('rev-parse', 'HEAD')
        # Explicit local trust tests the detector, not hosted bypass authority.
        for target in suite_inputs.SUITES:
            with self.subTest(target=target):
                inputs = suite_inputs.source_inputs([target], 'all', revision, revision)
                self.assertIn('src/TerminalEditor.zig', inputs['files'])
                self.assertIn('src/socket_fixture.zig', inputs['files'])
        with patch.dict(suite_inputs.DYNAMIC_EMBEDS, {'src/logic_tests.zig': 'unreviewed'}), \
                self.assertRaisesRegex(ValueError, 'Incomplete computed dependency'):
            suite_inputs.source_inputs(['test-logic'], 'all', revision, revision)

    def test_optional_evidence_errors_execute_the_real_gate_and_preserve_its_exit(self):
        runner = Path(__file__).with_name('run_selected.py').resolve()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / 'zig'
            fake.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$INVOCATIONS"\nexit "$GATE_EXIT"\n')
            fake.chmod(0o755)
            executed = root / 'tested-binary'
            executed.write_bytes(b'exact retained test executable')
            # Run the public CLI with a real child gate. Only the optional
            # evidence boundary is faulted; actual gate exits are never mocked.
            setup = '''import evidence, run_selected, os, builtins
mode = os.environ['FAULT']
original_import = builtins.__import__
def optional_import(name, *args, **kwargs):
    if mode == 'import' and name == 'evidence': raise ImportError('optional evidence unavailable')
    return original_import(name, *args, **kwargs)
def identify(*args):
    if mode == 'detector': raise RuntimeError('detector failed')
    return {'executables': [os.environ['EXECUTABLE']]}
def restore(*args):
    if mode == 'hash': raise OSError('hash failed')
    if mode == 'truncated': raise ValueError('invalid receipt')
    return mode in {'matching', 'unbound', 'different'}
evidence.identity = identify
evidence.restore = restore
evidence.record = lambda inputs: None
builtins.__import__ = optional_import
run_selected.main()
'''
            for fault in ('import', 'detector', 'hash', 'truncated', 'missing', 'matching', 'unbound', 'different'):
                for gate_exit in (0, 7):
                    with self.subTest(fault=fault, gate_exit=gate_exit):
                        invocations = root / 'invocations'
                        invocations.unlink(missing_ok=True)
                        environment = dict(os.environ, PATH=directory + os.pathsep + os.environ['PATH'],
                                           PYTHONPATH=str(runner.parent), FAULT=fault,
                                           EXECUTABLE=str(executed), INVOCATIONS=str(invocations),
                                           GATE_EXIT=str(gate_exit))
                        artifacts = ([] if fault == 'unbound' else
                                     ['--ci-artifacts=' + ('other-artifacts' if fault == 'different'
                                                          else '.zig-cache/o/ci-compiled')])
                        result = subprocess.run([sys.executable, '-B', '-c', setup, '["test-logic"]',
                                                 '--reuse-evidence', *artifacts], env=environment,
                                                capture_output=True, text=True)
                        self.assertEqual(result.returncode, 0 if fault == 'matching' else gate_exit,
                                         result.stdout + result.stderr)
                        self.assertEqual(invocations.exists(), fault != 'matching')
                        if fault != 'matching':
                            option = ' -D' + artifacts[0].removeprefix('--') if artifacts else ''
                            self.assertEqual(invocations.read_text().splitlines(),
                                             ['build test-logic' + option + ' --summary all'])

    def test_compiled_handoff_loads_without_the_optional_detector(self):
        code = '''import builtins
original = builtins.__import__
def unavailable(name, *args, **kwargs):
    if name == 'suite_inputs': raise ImportError('detector unavailable')
    return original(name, *args, **kwargs)
builtins.__import__ = unavailable
import build_artifact
print('compiled handoff available')
'''
        result = subprocess.run([sys.executable, '-B', '-c', code], capture_output=True, text=True,
                                env=dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parent)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'compiled handoff available')

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
                            GITHUB_REF='refs/heads/feature', ImageOS='image', ImageVersion='1'), \
                    patch.object(evidence, 'git', return_value=''), \
                    patch.object(evidence, 'digest', return_value='tool-hash'), \
                    patch.object(evidence, 'source_inputs', return_value={'declarations': {
                        'test': {'executables': ['test-tests']}}}), \
                    patch.object(evidence, 'runtime_inputs', return_value={}):
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
                        for workflow, event in [('.github/workflows/qualify-macos.yml', 'workflow_dispatch'),
                                                ('.github/workflows/daily-macos.yml', 'schedule'),
                                                ('.github/workflows/check.yml', 'workflow_dispatch')]:
                            with patch.dict(os.environ, GITHUB_WORKFLOW_REF='owner/repo/' + workflow + '@main',
                                            GITHUB_EVENT_NAME=event), \
                                    self.assertRaisesRegex(ValueError, 'qualification always requires fresh'):
                                evidence.identity(['test'], 'all')
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
            inputs = dict(format=3, source={'files': {'src/tests.zig': 'hash'}}, targets=['test'], part='all',
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
                    patch.object(evidence, 'api', return_value=dict(tree=dict(sha=receipt['source_tree']))), \
                    patch.object(evidence.subprocess, 'run'), \
                    patch.object(evidence, 'source_inputs', return_value=inputs['source']):
                self.assertEqual(evidence.verify(archive, artifact, run, inputs), receipt)
                old = dict(artifact, id=123, expired=False, size_in_bytes=len(archive),
                           created_at='2026-10-18T10:00:00Z')
                for defect in ('failure', 'cancelled', 'expired', 'invalid', 'valid'):
                    recent = dict(old, id=124, workflow_run=dict(id=124), expired=defect == 'expired',
                                  created_at='2026-10-19T10:00:00Z')

                    def historical_api(path, binary=False):
                        if '/actions/artifacts?' in path:
                            return {'artifacts': [old] if defect == 'valid' else [old, recent]}
                        if '/actions/runs/' in path:
                            if path.endswith('/124'):
                                return dict(run, id=124, conclusion=defect if defect != 'invalid' else 'success')
                            return dict(run, html_url='https://github.com/owner/repo/actions/runs/123')
                        if binary:
                            return archive
                        return dict(tree=dict(sha=receipt['source_tree']))

                    with self.subTest(latest=defect), \
                            patch.dict(os.environ, GITHUB_RUN_ID='999', GITHUB_STEP_SUMMARY=str(Path(directory) / 'summary')), \
                            patch.object(evidence, 'api', side_effect=historical_api):
                        self.assertEqual(evidence.restore(inputs), defect == 'valid',
                                         'Only the newest valid retained result can permit reuse')
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
                                     ('part', 'execution'), ('tools', 'changed-sdk'),
                                     ('system', 'Darwin'), ('machine', 'arm64'),
                                     ('compiler', 'other-compiler'), ('runtime', {'nofile': [256, 256]}),
                                     ('source', {'options': {'optimize': 'Debug'}})]:
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
        inputs = dict(format=3, source={}, workflow='owner/repo/.github/workflows/check.yml',
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
                           source_tree='expected',
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
            inputs = dict(format=3, source={}, targets=['test'], part='all',
                          workflow='owner/repo/.github/workflows/check.yml',
                          event='pull_request', branch='feature', executables=[str(binary)])
            run = dict(id=1, run_attempt=1, conclusion='success', event='pull_request',
                       head_sha=head, head_branch='feature', path='.github/workflows/check.yml',
                       head_repository=dict(full_name='owner/repo'),
                       pull_requests=[dict(base=dict(sha=base), head=dict(sha=head))])
            receipt = dict(inputs=inputs, run_id=1, run_attempt=1, verdict='passed', source_sha=source,
                           source_tree=tree,
                           executables={str(binary): evidence.digest(binary)})
            stream = io.BytesIO()
            with zipfile.ZipFile(stream, 'w') as zipped:
                zipped.writestr('evidence.json', json.dumps(receipt))
                zipped.writestr('executables/test', binary.read_bytes())
            data = stream.getvalue()
            artifact = dict(digest='sha256:' + hashlib.sha256(data).hexdigest(), workflow_run=dict(id=1))
            commit = dict(tree=dict(sha=tree), parents=[dict(sha=base), dict(sha=head)])
            with patch.dict(os.environ, GITHUB_REPOSITORY='owner/repo'), \
                    patch.object(evidence, 'api', return_value=commit), \
                    patch.object(evidence, 'source_inputs', return_value=inputs['source']):
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
