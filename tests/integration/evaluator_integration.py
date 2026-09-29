#!/usr/bin/env python3
"""Focused disposable QuickJS worker checks (not a Workflow/Host integration)."""
import argparse
import json
import pathlib
import resource
import struct
import subprocess
import sys
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary')
parser.add_argument('driver')
parser.add_argument('probe', nargs='?')
parser.add_argument('--churn-only', action='store_true',
                    help='Run only the 1,000-evaluation native reuse witness')
args = parser.parse_args()
if not args.churn_only and args.probe is None:
    parser.error('probe is required for boundary checks')
binary, driver, probe = args.binary, args.driver, args.probe


def invoke(mode, source):
    with tempfile.TemporaryDirectory() as directory:
        path = pathlib.Path(directory)
        (path / 'source').write_text(source)
        return subprocess.run([driver, binary, str(path / 'source'), mode, str(64 * 1024 * 1024)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=300 if mode == 'churn' else 7)


def expression(source):
    return f'export default async function workflow(capabilities) {{ return ({source}); }}'


def check_repetition(mode):
    result = invoke(mode, expression('2+3'))
    assert result.returncode == 0, (mode, result.returncode, result.stderr)
    assert result.stdout == b'5', (mode, result.stdout)


if args.churn_only:
    check_repetition('churn')
    print(f'evaluator churn: 1,000 same-parent exact results and descriptor balance passed on {sys.platform}')
    sys.exit(0)


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
                       'export default async function(capabilities) { return capabilities }').returncode == 0
assert invoke('check', '// export default 42\nexport default async function(capabilities = (()=>{throw 1})()) { return capabilities }').returncode == 0
assert value('1 + 2') == 3
assert value('Promise.resolve({answer: "中😀"})') == {'answer': '中😀'}
assert value('arguments.length') == 1
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

# Inspect the actual worker's complete encoding, including keys. The ordinary
# json.loads helper would silently accept duplicate members at any depth.
def unique_object(pairs):
    result = {}
    for key, value_ in pairs:
        assert key not in result, key
        result[key] = value_
    return result


encoded = invoke('run', expression(r'({["a\n\"\\中"]:{nested:[1,true,null,{"\u0061":2}]}})'))
assert encoded.returncode == 0, encoded.stderr
assert json.loads(encoded.stdout, object_pairs_hook=unique_object) == {
    'a\n"\\中': {'nested': [1, True, None, {'a': 2}]}}
assert b'\\u000a' in encoded.stdout and b'\\"' in encoded.stdout and '中'.encode() in encoded.stdout
aliased = invoke('run', expression(r'({a:1,["\u0061"]:2})'))
assert aliased.returncode == 0, aliased.stderr
assert json.loads(aliased.stdout, object_pairs_hook=unique_object) == {'a': 2}
assert value('1.7976931348623157e308') == float('1.7976931348623157e308')
assert value('5e-324') == float('5e-324')
assert invoke('run', expression('1e309')).returncode == 1
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

# Compile-only requires source on descriptor 3, but no prepared input on 4.
assert invoke('check', expression('capabilities')).returncode == 0

with tempfile.TemporaryDirectory() as directory:
    source = pathlib.Path(directory) / 'source.js'

    def owned(executable, mode, budget=1000000, extra=None):
        args = [driver, str(executable), str(source), mode, str(budget)]
        if extra is not None:
            args.append(str(extra))
        return subprocess.run(args,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=7)

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
    check_repetition('repeat')  # Ten real calls in one parent; long churn is separate.
    prepared = pathlib.Path(directory) / 'prepared'
    # The descriptor is passed read-only but its bytes are not entry arguments.
    prepared.write_bytes(b'\x05\x02\x00\x00\x00\x03' + struct.pack('<d', 7)
                         + b'\x03' + struct.pack('<d', 31))
    source.write_text(expression('[arguments.length, typeof arguments[1], Object.keys(capabilities).length]'))
    assert json.loads(owned(binary, 'run-input', extra=prepared).stdout) == [1, 'undefined', 0]
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
