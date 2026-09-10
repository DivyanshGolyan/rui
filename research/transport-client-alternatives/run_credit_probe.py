#!/usr/bin/env python3
"""Run the protocol probe against the sibling experiment's immutable nghttp2 build."""
import argparse, fcntl, hashlib, json, pathlib, platform, subprocess, tempfile
p = argparse.ArgumentParser()
p.add_argument('--prefix', type=pathlib.Path, default=pathlib.Path('/tmp/onepage-transport-memory-build/ng'))
p.add_argument('--output', type=pathlib.Path, required=True)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=False)
source = pathlib.Path(__file__).with_name('credit_probe.c').resolve()
lib = a.prefix / 'lib/libnghttp2.a'
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
with open('/tmp/onepage-memory-experiments.lock', 'a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    with tempfile.TemporaryDirectory(prefix='onepage-credit-probe-') as tmp:
        binary = pathlib.Path(tmp) / 'probe'
        command = ['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', '-I'+str(a.prefix/'include'), str(source), str(lib), '-o', str(binary)]
        subprocess.run(command, check=True, timeout=60)
        result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)
        (a.output/'results.jsonl').write_text(result.stdout)
        metadata = dict(platform=platform.platform(), machine=platform.machine(), compiler=subprocess.check_output(['cc','--version'], text=True), command=command, source_sha256=sha(source), library_sha256=sha(lib), binary_sha256=sha(binary), scope='in-memory HTTP/2 only; no TLS, socket, scratch, memory or latency qualification')
        (a.output/'metadata.json').write_text(json.dumps(metadata, indent=2)+'\n')
        print(result.stdout, end='')
