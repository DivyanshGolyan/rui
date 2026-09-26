#!/usr/bin/env python3
"""Focused disposable QuickJS worker checks (not a Workflow/Host integration)."""
import json
import pathlib
import resource
import struct
import subprocess
import sys
import tempfile
import time

binary = sys.argv[1]
driver = sys.argv[2]
probe = sys.argv[3]


def invoke(mode, source):
    with tempfile.TemporaryDirectory() as directory:
        path = pathlib.Path(directory)
        (path / 'source').write_text(source)
        return subprocess.run([driver, binary, str(path / 'source'), mode, str(64 * 1024 * 1024)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=7)


def expression(source):
    return f'export default async function workflow(_, input) {{ return ({source}); }}'


def reject_check(source, reason):
    result = invoke('check', source)
    assert result.returncode == 1, (source, result.returncode, result.stderr)
    assert b'workflow.js' in result.stderr and reason.encode() in result.stderr, result.stderr
    assert not result.stdout


def value(source):
    result = invoke('run', expression(source))
    assert result.returncode == 0, (source, result.returncode, result.stderr)
    return json.loads(result.stdout)


assert invoke('check', 'throw Error("must never execute"); export default async function workflow() {}').returncode == 0
reject_check('function (', 'SyntaxError')
assert invoke('check', 'export default async function workflow() { while(true) {} }').returncode == 0
# This assertion goes red on the former global-script compile-only path (exit 0).
reject_check('1 + 2', 'direct default async function required')
for invalid in ('export const other = async () => 1', 'export default 42',
                'export default async () => 42',
                'const main = async () => 42; export default main',
                'export default function workflow() {}',
                'export default async function* workflow() {}',
                'export default class workflow {}'):
    reject_check(invalid, 'direct default async function required')
reject_check('import x from "elsewhere"; export default async function workflow() {}', 'imports are unavailable')
reject_check('export * from "elsewhere"; export default async function workflow() {}', 'imports are unavailable')
reject_check('export { x } from "elsewhere"; export default async function workflow() {}', 'imports are unavailable')
reject_check('export default async function workflow() { return import("elsewhere") }', 'imports are unavailable')
reject_check('export default async function workflow() { return import.meta }', 'imports are unavailable')
reject_check('export default async function workflow() { return import("workflow.js") }', 'imports are unavailable')
assert invoke('check', 'export default async function workflow() { return "import(x)" }').returncode == 0
assert invoke('check', 'class Helper { static { throw Error("must not run") } }\n'
                       'export default async function(_, args) { return args }').returncode == 0
assert invoke('check', '// export default 42\nexport default async function(_, args = (()=>{throw 1})()) { return args }').returncode == 0
assert value('1 + 2') == 3
assert value('Promise.resolve({answer: "中😀"})') == {'answer': '中😀'}
assert value('[typeof Promise.race, typeof Promise.any, typeof Promise.allSettled]') == [
    'undefined', 'undefined', 'function']
assert value('({env: typeof process, fs: typeof require, clock: typeof Date, random: typeof Math.random, fn: typeof Function})') == {
    'env': 'undefined', 'fs': 'undefined', 'clock': 'undefined', 'random': 'undefined', 'fn': 'undefined'}
assert invoke('run', expression('(()=>{}).constructor("return 1")()')).returncode == 1
assert invoke('run', expression('(async()=>{}).constructor("return 1")()')).returncode == 1
assert invoke('run', expression('(()=>{throw Error("failure")})()')).returncode == 1
assert invoke('run', expression('(()=>{while(true) {}})()')).returncode == 1
assert invoke('run', expression('Promise.resolve().then(function again() { return Promise.resolve().then(again) })')).returncode == 1
assert invoke('run', expression('({get secret(){return 42}})')).returncode == 1
assert invoke('run', expression('(()=>{let x={};x.self=x;return x})()')).returncode == 1
assert invoke('run', expression('[1,,3]')).returncode == 1
assert invoke('run', expression('(()=>{let x=[1];x.extra=2;return x})()')).returncode == 1
assert invoke('run', expression('(()=>{let x={a:1};Object.defineProperty(x,"hidden",{value:2});return x})()')).returncode == 1
assert invoke('run', expression('(()=>{let x={a:1};x[Symbol("hidden")]=2;return x})()')).returncode == 1
assert invoke('run', expression('(()=>{let x=[1];Object.setPrototypeOf(x,{0:2});return x})()')).returncode == 1
assert invoke('run', expression('({bad:undefined})')).returncode == 1
assert invoke('run', expression('({bad:Infinity})')).returncode == 1
assert invoke('run', expression('(()=>{let x=new Number(7);Object.setPrototypeOf(x,null);return x})()')).returncode == 1
assert invoke('run', expression('(()=>{let x=new Boolean(true);Object.setPrototypeOf(x,null);return x})()')).returncode == 1
assert invoke('run', expression('({nested:Promise.resolve(1)})')).returncode == 1
assert value('({ordinary:{answer:42}, bare:Object.assign(Object.create(null),{ok:true})})') == {
    'ordinary': {'answer': 42}, 'bare': {'ok': True}}
assert value('(()=>{let leaf={answer:42};return [leaf,leaf,{nested:[3,1]}]})()') == [
    {'answer': 42}, {'answer': 42}, {'nested': [3, 1]}]
assert value('(()=>{Object.prototype.toJSON=()=>"poison"; return {answer:42}})()') == {'answer': 42}
assert value('"x".repeat(600000)') == 'x' * 600000
assert value('"a".repeat(600) + "b".repeat(600)') == 'a' * 600 + 'b' * 600
assert value('({mixed: "a".repeat(600) + "中" + "😀", split: "\\ud83d" + "\\ude00"})') == {
    'mixed': 'a' * 600 + '中😀', 'split': '😀'}
shared = value('(()=>{let leaf={x:"x".repeat(1000)};return Array(5000).fill(leaf)})()')
assert len(shared) == 5000 and shared[0] == shared[-1] == {'x': 'x' * 1000}
assert value('Promise.resolve().then(async()=>{let x=0;for(let i=0;i<10000;i++){await 0;x++}return x})') == 10000
detached = 'Promise.resolve().then(function again() { Promise.resolve().then(again) });'
# A settled module/returned root does not wait for unrelated continuations.
assert json.loads(invoke('run', detached + 'export default async function workflow() { return 42 }').stdout) == 42
assert value('(()=>{' + detached + ' return 42})()') == 42
assert invoke('run', 'export default async function workflow() {' +
              detached + ' throw Error("root failed") }').returncode == 1
assert invoke('run', expression('Promise.resolve().then(function again() {' +
              ' return Promise.resolve().then(again) })')).returncode == 1
assert value('"中😀\\u0000\\b\\f\\n\\r\\t\\\"\\\\"') == '中😀\x00\b\f\n\r\t"\\'
assert invoke('run', expression('String.fromCharCode(0xd800,0x61,0xdc00)')).returncode == 1
# The 3 MiB engine string expands beyond the complete 16 MiB engine budget;
# output must therefore be encoded directly into bounded native chunks.
escaped = '\x01' * (3 * 1024 * 1024)
assert value('"\\u0001".repeat(3*1024*1024)') == escaped
# This allocation exceeds the engine's 16 MiB limit independently of the
# native source buffer and output scratch budget; a later child still runs.
assert invoke('run', expression('"x".repeat(20*1024*1024)')).returncode == 1
# The worker may write a complete chunk before encountering the invalid
# nested descriptor, but the parent must not publish any prefix as success.
partial = invoke('run', expression(
    '({prefix:"x".repeat(20000), invalid:{get value(){throw Error("getter ran")}}})'))
assert partial.returncode == 1 and not partial.stdout
assert value('13') == 13


def prepared_string(text):
    encoded = text.encode()
    return b'\x04' + struct.pack('<Q', len(encoded)) + encoded


def prepared_key(text):
    encoded = text.encode()
    return struct.pack('<Q', len(encoded)) + encoded


def prepared_value(value):
    if value is None:
        return b'\x00'
    if value is False:
        return b'\x01'
    if value is True:
        return b'\x02'
    if isinstance(value, (int, float)):
        return b'\x03' + struct.pack('<d', float(value))
    if isinstance(value, str):
        return prepared_string(value)
    if isinstance(value, list):
        return b'\x05' + struct.pack('<I', len(value)) + b''.join(map(prepared_value, value))
    if isinstance(value, dict):
        return (b'\x06' + struct.pack('<I', len(value)) +
                b''.join(prepared_key(key) + prepared_value(item)
                         for key, item in value.items()))
    raise TypeError(value)


def input_result(payload, source='input'):
    with tempfile.TemporaryDirectory() as directory:
        path = pathlib.Path(directory)
        (path / 'source').write_text(expression(source))
        (path / 'input').write_bytes(payload)
        return subprocess.run([driver, binary, str(path / 'source'), 'run-input',
                               str(64 * 1024 * 1024), str(path / 'input')],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=7)


def input_value(payload, source='input'):
    result = input_result(b'\x05\x01\x00\x00\x00' + payload, source)
    assert result.returncode == 0, (result.returncode, result.stderr)
    return json.loads(result.stdout)


assert input_value(prepared_value({'answer': [True, None, 2.5]})) == {
    'answer': [True, None, 2.5]}
assert input_value(prepared_value({'answer': 42}),
                   '[Object.keys(_).length, input.answer]') == [0, 42]
assert json.loads(input_result(prepared_value([]), 'typeof input').stdout) == 'undefined'
assert json.loads(input_result(prepared_value([7, 31]), '[input, arguments[2]]').stdout) == [7, 31]
assert input_result(prepared_value({'answer': 42}), 'input').returncode == 1  # root is arguments, not one argument
# A scalar crosses the reader's 4096-byte window in both validation passes.
boundary = 'x' * 4095 + '中😀'
assert input_value(prepared_value(boundary), 'input.slice(-3)') == '中😀'
large_key = 'k' * (1024 * 1024)
assert input_value(prepared_value({large_key: True}), 'Object.keys(input)[0].length') == len(large_key)
duplicate = (b'\x06\x02\x00\x00\x00' + prepared_key('same') + b'\x00' +
             prepared_key('same') + b'\x02')
assert input_result(b'\x05\x01\x00\x00\x00' + duplicate, '42').returncode == 1
for malformed in (b'\x07', b'\x00\x00', b'\x03' + struct.pack('<d', float('inf')),
                  b'\x04\x03\x00\x00\x00\x00\x00\x00\x00\xed\xa0\x80',
                  b'\x04\x05\x00\x00\x00\x00\x00\x00\x00x'):
    assert input_result(b'\x05\x01\x00\x00\x00' + malformed, '42').returncode == 1
# Defining properties must not route through setters installed by author code.
assert input_value(prepared_value({'poison': 7}),
                   '(()=>{Object.prototype.__defineSetter__("poison",()=>{throw 1}); return input.poison})()') == 7
assert input_value(prepared_value('first')) == 'first'
assert input_value(prepared_value('second')) == 'second'
# Compile-only requires source on descriptor 3, but no prepared input on 4.
assert invoke('check', expression('input')).returncode == 0

with tempfile.TemporaryDirectory() as directory:
    source = pathlib.Path(directory) / 'source.js'

    def owned(executable, mode, budget=1000000, extra=None):
        args = [driver, str(executable), str(source), mode, str(budget)]
        if extra is not None:
            args.append(str(extra))
        return subprocess.run(args,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=30 if mode == 'repeat' else 7)

    source.write_text('throw Error("must never execute"); export default async function workflow() {}')
    assert owned(binary, 'check').returncode == 0
    source.write_text('function (')
    assert owned(binary, 'check').returncode == 1
    source.write_text(expression('Promise.resolve({answer:"中😀"})'))
    assert json.loads(owned(binary, 'run').stdout) == {'answer': '中😀'}
    assert owned(binary, 'run', 2).returncode == 1
    source.write_text(expression('(()=>{while(true) {}})()'))
    start = time.monotonic()
    assert owned(binary, 'run').returncode == 1
    assert time.monotonic() - start < 5
    start = time.monotonic()
    assert owned(binary, 'cancel').returncode == 1
    assert time.monotonic() - start < 1
    source.write_text('/*' + 'x' * 600000 + '*/ ' + expression('9'))
    assert owned(binary, 'run').stdout == b'9'
    source.write_text('/*' + 'x' * (9 * 1024 * 1024) + '*/ ' + expression('9'))
    assert owned(binary, 'run').stdout == b'9'  # beyond the obsolete 8 MiB source guard
    with source.open('wb') as large_source:
        for _ in range(64):
            large_source.write(b' ' * (1024 * 1024))
    assert owned(binary, 'check').returncode == 1  # native allocation bound, no truncated success
    source.write_text(expression('2+3'))
    assert owned(binary, 'run').stdout == b'5'  # next lifecycle reuses no VM
    assert owned(binary, 'repeat').stdout == b'5'  # 1,000 calls in one parent
    prepared = pathlib.Path(directory) / 'prepared'
    prepared.write_bytes(prepared_value([{'answer': 42}]))
    source.write_text(expression('input.answer'))
    assert owned(binary, 'run-input', extra=prepared).stdout == b'42'
    assert owned(binary, 'run-input-rw', extra=prepared).returncode == 1
    source.write_text(expression('2+3'))

    # Diagnostics are not protocol, but must be drained concurrently so a
    # noisy child cannot block before producing its stdout frame and exit.
    fake = pathlib.Path(directory) / 'fake-child'
    fake.write_text('#!/bin/sh\ndd if=/dev/zero bs=65536 count=4 >&2 2>/dev/null\n'
                    'printf "\\001\\000\\000\\0005\\000\\000\\000\\000"\n')
    fake.chmod(0o700)
    assert owned(fake, 'run').stdout == b'5'

    # A fake child emitting a plausible prefix must not be accepted before
    # normal exit, EOF, complete frame and declared length have all agreed.
    marker = pathlib.Path(directory) / 'launched'
    fake.write_text(f'#!/bin/sh\ntouch "{marker}"\n')
    fake.chmod(0o700)
    assert owned(fake, 'cancel').returncode == 1
    assert not marker.exists()  # a committed cancellation never launches code
    fake.write_text(f'#!/bin/sh\ntouch "{marker}"\nwhile :; do :; done\n')
    start = time.monotonic()
    assert owned(fake, 'live-cancel').returncode == 1
    assert marker.exists()  # cancellation was observed after successful spawn
    assert time.monotonic() - start < 1
    # Block the parent's synchronous output reservation callback rather than a
    # real filesystem. The child becomes a zombie at the deadline because the
    # watchdog must be joined before waitpid, while the owner stays blocked.
    child_pid = pathlib.Path(directory) / 'child-pid'
    fake.write_text(f'''#!/bin/sh
echo $$ > "{child_pid}"
printf "\\001\\000\\000\\000x"
while :; do :; done
''')
    process = subprocess.Popen(
        [driver, str(fake), str(source), 'stall-write', '1000000'],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    for _ in range(100):
        if child_pid.exists():
            break
        time.sleep(.01)
    assert child_pid.exists()
    pid = int(child_pid.read_text())
    if sys.platform == 'linux':
        deadline = time.monotonic() + 5.7
        state = ''
        while time.monotonic() < deadline:
            try:
                state = pathlib.Path(f'/proc/{pid}/stat').read_text().split()[2]
            except FileNotFoundError:
                state = 'gone'
            if state in ('Z', 'gone'):
                break
            time.sleep(.01)
        assert state == 'Z', state  # terminated, not reaped while output is gated
        assert process.poll() is None
    assert process.wait(timeout=8) == 1
    if sys.platform == 'linux':
        assert not pathlib.Path(f'/proc/{pid}').exists()  # joined, then reaped
    # Cancellation is independently observed while framed output keeps arriving.
    marker.unlink(missing_ok=True)
    fake.write_text(f'''#!/bin/sh
echo $$ > "{marker}"
while :; do printf "\\001\\000\\000\\000x"; done
''')
    start = time.monotonic()
    assert owned(fake, 'live-cancel').returncode == 1
    assert marker.exists()
    assert time.monotonic() - start < 1
    if sys.platform == 'linux':
        assert not pathlib.Path(f'/proc/{int(marker.read_text())}').exists()
    fake.write_text('#!/bin/sh\nprintf "\\001\\000\\000\\000x\\000\\000\\000\\000"\nexit 1\n')
    assert owned(fake, 'run').returncode == 1
    fake.write_text('#!/bin/sh\nprintf "\\002\\000\\000\\000x"\n')
    assert owned(fake, 'run').returncode == 1
    fake.write_text('#!/bin/sh\nprintf "\\001\\000\\000\\000xy\\000\\000\\000\\000"\n')
    assert owned(fake, 'run').returncode == 1
    fake.write_text('#!/bin/sh\nexec 1>&-\nwhile :; do :; done\n')
    start = time.monotonic()
    assert owned(fake, 'run').returncode == 1
    assert 4.5 < time.monotonic() - start < 7
    assert owned(binary, 'run').stdout == b'5'
    assert owned(probe, 'check').returncode == 0
    assert json.loads(owned(probe, 'run').stdout) == {'env': 0, 'extraFds': 2}
    normal = resource.getrlimit(resource.RLIMIT_NOFILE)
    try:
        resource.setrlimit(resource.RLIMIT_NOFILE, (256, normal[1]))
        assert json.loads(owned(probe, 'run').stdout) == {'env': 0, 'extraFds': 2}
    finally:
        resource.setrlimit(resource.RLIMIT_NOFILE, normal)
print(f'evaluator boundary: compile-only, result, CPU, framing, and cleanup passed on {sys.platform}')
