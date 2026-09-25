#!/usr/bin/env python3
"""Focused disposable QuickJS worker checks (not a Workflow/Host integration)."""
import json
import struct
import subprocess
import sys

binary = sys.argv[1]


def invoke(mode, source):
    return subprocess.run([binary, mode], input=source.encode(), stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, env={}, timeout=5)


def value(source):
    result = invoke('run', source)
    assert result.returncode == 0, (source, result.returncode, result.stderr)
    assert len(result.stdout) >= 8
    size, = struct.unpack('<Q', result.stdout[:8])
    assert len(result.stdout) == 8 + size
    return json.loads(result.stdout[8:])


assert invoke('check', 'throw Error("must never execute")').returncode == 0
assert invoke('check', 'function (').returncode != 0
assert invoke('check', 'while(true) {}').returncode == 0
assert value('1 + 2') == 3
assert value('Promise.resolve({answer: "中😀"})') == {'answer': '中😀'}
assert value('({env: typeof process, fs: typeof require, clock: typeof Date, random: typeof Math.random})') == {
    'env': 'undefined', 'fs': 'undefined', 'clock': 'undefined', 'random': 'undefined'}
assert invoke('run', 'throw Error("failure")').returncode != 0
assert invoke('run', 'while (true) {}').returncode != 0
assert invoke('run', 'Promise.resolve().then(function again() { return Promise.resolve().then(again) })').returncode != 0
assert invoke('run', '({get secret(){return 42}})').returncode != 0
assert invoke('run', '(()=>{let x={};x.self=x;return x})()').returncode != 0
assert invoke('run', '[1,,3]').returncode != 0
assert invoke('run', '(()=>{let x=[1];x.extra=2;return x})()').returncode != 0
assert invoke('run', '(()=>{let x={a:1};Object.defineProperty(x,"hidden",{value:2});return x})()').returncode != 0
assert value('Object.prototype.toJSON=()=>"poison"; ({answer:42})') == {'answer': 42}
assert value('"x".repeat(600000)') == 'x' * 600000
print('standalone evaluator worker: compile-only and strict data passed')
