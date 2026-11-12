#!/usr/bin/env python3
"""Integration checks for exact compiled dependency identity; requires built nghttp2."""
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
PREFIX = pathlib.Path('/tmp/rui-transport-memory-build/ng')


class CompiledDependencyIdentity(unittest.TestCase):
    def test_prefix_identity_is_checked_before_results_are_published(self):
        with tempfile.TemporaryDirectory(prefix='rui-header-test-') as tmp:
            root = pathlib.Path(tmp)
            prefix = root / 'prefix'
            headers = prefix / 'include' / 'nghttp2'
            headers.mkdir(parents=True)
            (prefix / 'lib').mkdir()
            (prefix / 'lib' / 'libnghttp2.a').symlink_to(PREFIX / 'lib' / 'libnghttp2.a')
            cases = ['matching', 'changed_api', 'stale_version', 'missing_version']
            for case in cases:
                with self.subTest(case=case):
                    for name in ['nghttp2.h', 'nghttp2ver.h']:
                        shutil.copyfile(PREFIX / 'include' / 'nghttp2' / name, headers / name)
                    if case == 'changed_api':
                        with (headers / 'nghttp2.h').open('a') as f:
                            f.write('\n/* independently modified header */\n')
                    elif case == 'stale_version':
                        p = headers / 'nghttp2ver.h'
                        p.write_text(p.read_text().replace('1.70.0', '1.69.0'))
                    elif case == 'missing_version':
                        (headers / 'nghttp2ver.h').unlink()
                    output = root / case
                    command = [sys.executable, str(HERE / 'run_credit_probe.py'),
                               '--prefix', str(prefix), '--output', str(output)]
                    result = subprocess.run(command, capture_output=True, text=True, timeout=90)
                    if case != 'matching':
                        self.assertNotEqual(result.returncode, 0)
                        self.assertFalse(output.exists())
                        self.assertIn('header mismatch' if case != 'missing_version' else 'FileNotFoundError', result.stderr)
                        continue
                    self.assertEqual(result.returncode, 0, result.stderr)
                    metadata = json.loads((output / 'metadata.json').read_text())
                    self.assertEqual(metadata['runtime_version'], '1.70.0')
                    for name, identity in metadata['compiled_headers'].items():
                        self.assertEqual(identity['sha256'], hashlib.sha256((headers / name).read_bytes()).hexdigest())
                        self.assertNotEqual(identity['compiled_path'], identity['prefix_path'])
                    self.assertEqual(metadata['library_sha256'], hashlib.sha256((PREFIX / 'lib' / 'libnghttp2.a').read_bytes()).hexdigest())
                    saved = (output / 'metadata.json').read_bytes()
                    repeated = subprocess.run(command, capture_output=True, text=True, timeout=90)
                    self.assertNotEqual(repeated.returncode, 0)
                    self.assertEqual((output / 'metadata.json').read_bytes(), saved)


if __name__ == '__main__':
    unittest.main()
