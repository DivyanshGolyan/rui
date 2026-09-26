#!/usr/bin/env python3
"""Exercise the contained module worker before the parent protocol adopts it."""
import json
import pathlib
import struct
import subprocess
import sys
import tempfile

binary = sys.argv[1]


def expression(body):
    return f'export default async function workflow(_, input) {{ return ({body}); }}'


def invoke(mode, source, prepared=b'\x05\x00\x00\x00\x00'):
    with tempfile.TemporaryDirectory() as directory:
        path = pathlib.Path(directory)
        (path / 'source').write_text(source)
        (path / 'prepared').write_bytes(prepared)
        # The future parent grants only read-only source and prepared descriptors.
        launch = 'exec 3< "$1"; if [ "$4" = run-prepared ]; then exec 4< "$2"; fi; exec "$3" "$4"'
        return subprocess.run(['/bin/sh', '-c', launch, 'worker',
                               str(path / 'source'), str(path / 'prepared'), binary, mode],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={}, timeout=5)


def value(body, prepared=b'\x05\x00\x00\x00\x00'):
    result = invoke('run-prepared', expression(body), prepared)
    assert result.returncode == 0, (body, result.returncode, result.stderr)
    chunks = []
    data = result.stdout
    while True:
        assert len(data) >= 4
        size, = struct.unpack('<I', data[:4])
        data = data[4:]
        if not size:
            assert not data
            return json.loads(b''.join(chunks))
        assert len(data) >= size
        chunks.append(data[:size])
        data = data[size:]


assert invoke('check-prepared', 'throw Error("must not run"); export default async function workflow() {}').returncode == 0
for invalid in ('1 + 2', 'export default 42',
                'export default async () => 1',
                'import x from "elsewhere"; export default async function workflow() {}',
                'export default async function workflow() { return import("elsewhere") }'):
    rejected = invoke('check-prepared', invalid)
    assert rejected.returncode != 0 and not rejected.stdout, (invalid, rejected.stderr)
assert value('({answer: "中😀", missing: typeof process})') == {
    'answer': '中😀', 'missing': 'undefined'}
assert value('input.answer', b'\x05\x01\x00\x00\x00\x06\x01\x00\x00\x00'
             + struct.pack('<Q', 6) + b'answer\x03' + struct.pack('<d', 42)) == 42
assert value('"\\u0001".repeat(3*1024*1024)') == '\x01' * (3 * 1024 * 1024)
assert value('(()=>{let leaf={answer:42};return [leaf,leaf,{nested:[3,1]}]})()') == [
    {'answer': 42}, {'answer': 42}, {'nested': [3, 1]}]
assert value('({letter:"中😀", escaped:"\\ud83d\\ude00", finite:1.25})') == {
    'letter': '中😀', 'escaped': '😀', 'finite': 1.25}
detached = 'Promise.resolve().then(function again() { Promise.resolve().then(again) });'
# A settled module/returned root does not wait for unrelated continuations.
module = invoke('run-prepared', detached + 'export default async function workflow() { return 42 }')
assert module.returncode == 0 and module.stdout == b'\x02\x00\x00\x0042\x00\x00\x00\x00'
assert value('(()=>{' + detached + ' return 42})()') == 42
assert invoke('run-prepared', 'export default async function workflow() {' +
              detached + ' throw Error("root failed") }').returncode != 0
assert invoke('run-prepared', expression('Promise.resolve().then(function again() {' +
              ' return Promise.resolve().then(again) })')).returncode != 0
for invalid in ('({get secret(){return 42}})', '[1,,3]',
                '(()=>{let x={}; x.self=x; return x})()',
                '(()=>{let x=[1];x.extra=2;return x})()',
                '(()=>{let x={a:1};Object.defineProperty(x,"hidden",{value:2});return x})()',
                '(()=>{let x={a:1};x[Symbol("hidden")]=2;return x})()',
                '(()=>{let x=[1];Object.setPrototypeOf(x,{0:2});return x})()',
                '({bad:undefined})', '({bad:Infinity})',
                '(()=>{}).constructor("return 1")()'):
    assert invoke('run-prepared', expression(invalid)).returncode != 0
# A late invalid property may leave framed data, but never a terminal frame:
# the parent must refuse it rather than publishing the valid prefix.
partial = invoke('run-prepared', expression(
    '({prefix:"x".repeat(20000), invalid:{get value(){throw Error("getter ran")}}})'))
assert partial.returncode != 0 and len(partial.stdout) >= 16388
assert not partial.stdout.endswith(b'\x00\x00\x00\x00')
assert value('13') == 13
print('evaluator worker: module policy, prepared arguments and streamed output passed')
