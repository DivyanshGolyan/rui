#!/usr/bin/env python3
"""Run with verified nghttp2 headers and a recorded static library snapshot."""
import argparse
import fcntl
import hashlib
import json
import pathlib
import platform
import subprocess
import tempfile

HERE = pathlib.Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(prefix, output):
    pin = json.loads((HERE / 'header-pin.json').read_text())
    evidence = json.loads((HERE / 'source-evidence.json').read_text())
    api = next(row for row in evidence['sources']
               if row['url'].endswith('/v1.70.0/lib/includes/nghttp2/nghttp2.h'))
    expected = {'nghttp2.h': api['sha256'],
                'nghttp2ver.h': pin['generated_header_sha256']}
    source = HERE / 'credit_probe.c'
    with open('/tmp/rui-memory-experiments.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with tempfile.TemporaryDirectory(prefix='rui-credit-probe-') as tmp:
            stage = pathlib.Path(tmp)
            include = stage / 'include' / 'nghttp2'
            include.mkdir(parents=True)
            headers = {}
            # Compile immutable copies of the verified bytes, not a mutable prefix.
            for name, digest in expected.items():
                original = prefix / 'include' / 'nghttp2' / name
                copied = include / name
                copied.write_bytes(original.read_bytes())
                actual = sha(copied)
                if actual != digest:
                    raise ValueError(f'{original}: header mismatch for audited {pin["version"]}')
                headers[name] = dict(prefix_path=str(original), compiled_path=str(copied), sha256=actual)
            lib = stage / 'libnghttp2.a'
            original_lib = prefix / 'lib' / 'libnghttp2.a'
            lib.write_bytes(original_lib.read_bytes())
            library_sha = sha(lib)
            binary = stage / 'probe'
            dependencies = stage / 'probe.d'
            command = ['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2',
                       '-MMD', '-MF', str(dependencies), '-I'+str(stage/'include'),
                       str(source), str(lib), '-o', str(binary)]
            subprocess.run(command, check=True, timeout=60)
            dependency_text = dependencies.read_text().replace('\\\n', '')
            for header in headers.values():
                if header['compiled_path'] not in dependency_text:
                    raise ValueError('compiler did not consume the verified nghttp2 headers')
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)
            runtime_version = json.loads(result.stdout.splitlines()[0])['nghttp2']
            if runtime_version != pin['version']:
                raise ValueError(f'linked library version {runtime_version} differs from audited {pin["version"]}')
            metadata = dict(platform=platform.platform(), machine=platform.machine(),
                            compiler=subprocess.check_output(['cc', '--version'], text=True),
                            command=command, source_sha256=sha(source),
                            library_prefix_path=str(original_lib), library_sha256=library_sha,
                            binary_sha256=sha(binary), compiled_headers=headers,
                            header_pin=pin, api_header_source=api, runtime_version=runtime_version,
                            scope='in-memory HTTP/2 only; no TLS, socket, scratch, memory or latency qualification')
            # Reject stale dependencies before publishing any successful result directory.
            output.mkdir(parents=True, exist_ok=False)
            (output / 'results.jsonl').write_text(result.stdout)
            (output / 'metadata.json').write_text(json.dumps(metadata, indent=2)+'\n')
            print(result.stdout, end='')


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--prefix', type=pathlib.Path, default=pathlib.Path('/tmp/rui-transport-memory-build/ng'))
    p.add_argument('--output', type=pathlib.Path, required=True)
    a = p.parse_args()
    if a.output.exists():
        p.error('output directory already exists')
    run(a.prefix.resolve(), a.output)
