#!/usr/bin/env python3
"""Inventory recognizable flake sources and ratchet their exact per-file counts.

Bootstrap from the origin/main merge base when the allowance does not yet exist.
Run with --seed to print the trusted bootstrap as JSON.
"""
import argparse
import ast
from collections import Counter
import io
import json
from pathlib import Path
import re
import subprocess
import tokenize

ROOT = Path(__file__).resolve().parents[2]
ALLOWANCE = 'tests/ci/flake_sources.json'
RULES = ('fixed_sleep', 'unsignaled_poll', 'flake_masking', 'test_double')


def target(path):
    p = Path(path)
    return (p.suffix == '.zig' or (path.startswith('tests/') and p.suffix == '.py') or
            (p.parent.as_posix() == 'clients/ts/test' and p.name.endswith('.test.ts')))


def mask(source, language):
    """Replace comments and literals with spaces while preserving positions."""
    if language == 'py':
        lines = source.splitlines(keepends=True)
        offsets = [0]
        for line in lines:
            offsets.append(offsets[-1] + len(line))
        chars = list(source)
        try:
            for token in tokenize.generate_tokens(io.StringIO(source).readline):
                if token.type in (tokenize.STRING, tokenize.COMMENT):
                    start = offsets[token.start[0] - 1] + token.start[1]
                    end = offsets[token.end[0] - 1] + token.end[1]
                    for i in range(start, end):
                        if chars[i] != '\n':
                            chars[i] = ' '
        except (tokenize.TokenError, IndentationError) as exc:
            raise ValueError(f'invalid Python source: {exc}') from exc
        return ''.join(chars)
    pattern = r'//[^\n]*|/\*[\s\S]*?\*/|\\\\[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|`(?:\\.|[^`\\])*`'
    return re.sub(pattern, lambda m: re.sub(r'[^\n]', ' ', m.group()), source)


def zig_tests(code):
    """Keep Zig test block bodies, including nested braces, and discard production."""
    chars = ['\n' if c == '\n' else ' ' for c in code]
    for match in re.finditer(r'\btest\s+(?:[A-Za-z_]\w*\s*)?\{', code):
        start = match.end() - 1
        depth = 1
        end = start + 1
        while end < len(code) and depth:
            depth += (code[end] == '{') - (code[end] == '}')
            end += 1
        if depth:
            raise ValueError('unclosed Zig test block')
        chars[start:end] = code[start:end]
    return ''.join(chars)


def inventory(source, path):
    language = 'py' if path.endswith('.py') else 'zig' if path.endswith('.zig') else 'ts'
    code = mask(source, language)
    if language == 'zig' and not (path.startswith('tests/') or path.endswith('_test.zig') or '/test/' in path or '/tests/' in path or '/testing/' in path or path.endswith('/tests.zig') or '_tests/' in path or path.startswith('src/testing/')):
        code = zig_tests(code)
    counts = Counter()
    if language == 'py':
        tree = ast.parse(source)

        def call_name(node):
            return ast.unparse(node.func) if isinstance(node, ast.Call) else ''

        for node in ast.walk(tree):
            if isinstance(node, ast.Call):
                name = call_name(node)
                if re.fullmatch(r'(?:subprocess\.(?:run|call|check_call|check_output|Popen)|os\.system)', name):
                    counts['flake_masking'] += sum(1 for child in ast.walk(node)
                        if isinstance(child, ast.Constant) and isinstance(child.value, str)
                        and re.fullmatch(r'--(?:retries|reruns)(?:=.*)?', child.value))
                if re.fullmatch(r'(?:time|asyncio)\.sleep', name):
                    counts['fixed_sleep'] += 1
                if re.fullmatch(r'(?:unittest\.)?mock\.patch(?:\.object|\.dict|\.multiple)?|patch(?:\.object|\.dict|\.multiple)?', name):
                    counts['test_double'] += 1
                elif re.fullmatch(r'monkeypatch\.(?:setattr|setitem|delattr|delitem)', name) and node.args:
                    target_name = ast.unparse(node.args[0]).strip("'\"")
                    if re.match(r'(?:rui|host_process)(?:\.|$)', target_name) or target_name in ('globals()', 'builtins', '__builtins__'):
                        counts['test_double'] += 1
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                for decorator in node.decorator_list:
                    name = ast.unparse(decorator.func if isinstance(decorator, ast.Call) else decorator)
                    if re.search(r'(?:^|\.)(?:flaky|retry|rerun)(?:_|$)', name):
                        counts['flake_masking'] += 1
            if isinstance(node, (ast.While, ast.For, ast.AsyncFor)):
                condition = ast.unparse(node.test) if isinstance(node, ast.While) else ast.unparse(node.iter)
                body = ' '.join(ast.unparse(item) for item in node.body)
                if (re.search(r'\b(?:run|execute|retry|rerun)_?test\w*\s*\(', body, re.I)
                        and (re.search(r'\b(?:retry|retries|rerun|attempts?)\b', condition, re.I)
                             or (isinstance(node, (ast.For, ast.AsyncFor))
                                 and re.search(r'\b(?:attempt|retry|retries)\w*\b', ast.unparse(node.target), re.I)
                                 and any(isinstance(item, ast.Try) for item in ast.walk(node))))):
                    counts['flake_masking'] += 1
                if (re.search(r'\b(?:deadline|time\.(?:monotonic|time|perf_counter)\s*\()', condition, re.I)
                        and re.search(r'\b(?:read|inspect|observe|exists|poll|get|status)\w*\s*\(', body, re.I)
                        and not re.search(r'\b(?:wait|join|wait_for|select|recv|recvfrom|accept)\w*\s*\(', body, re.I)):
                    counts['unsignaled_poll'] += 1
    else:
        def count(rule, pattern):
            counts[rule] += len(list(re.finditer(pattern, code, re.MULTILINE)))
        if language == 'zig':
            count('fixed_sleep', r'\b(?:Io|io|std\s*\.\s*Thread|std\s*\.\s*testing\s*\.\s*io)\s*\.\s*sleep\s*\(')
        else:
            # A timer callback alone may schedule work; awaiting a timer is a delay.
            count('fixed_sleep', r'\b(?:await\s+setTimeout\s*\(|(?:await\s+)?new\s+Promise\s*\([^;]*?\bsetTimeout\s*\()')
        # Walk balanced loop bodies so nested branches do not hide state reads or waits.
        for loop in re.finditer(r'\b(?:while|for)\s*\(', code):
            pos = loop.end()
            depth = 1
            while pos < len(code) and depth:
                depth += (code[pos] == '(') - (code[pos] == ')')
                pos += 1
            condition = code[loop.end():pos - 1]
            opening = re.match(r'\s*(?:\|[^|]*\|\s*)?\{', code[pos:])
            if not opening:
                continue
            start = pos + opening.end()
            pos = start
            depth = 1
            while pos < len(code) and depth:
                depth += (code[pos] == '{') - (code[pos] == '}')
                pos += 1
            body = code[start:pos - 1]
            if (re.search(r'\b(?:run|execute|retry|rerun)_?test\w*\s*\(', body, re.I)
                    and (re.search(r'\b(?:retry|retries|rerun|attempts?)\b', condition, re.I)
                         or re.search(r'\b(?:retry|rerun)\w*\s*\(', body, re.I))):
                counts['flake_masking'] += 1
            if (re.search(r'\b(?:deadline|Date\s*\.\s*now|nanoTimestamp|milliTimestamp|monotonic)\b', condition, re.I)
                    and re.search(r'\b(?:read|inspect|observe|exists|poll|get|status)\w*\s*\(', body, re.I)
                    and not re.search(r'\b(?:wait|join|select|recv|recvfrom|accept)\w*\s*\(', body, re.I)):
                counts['unsignaled_poll'] += 1
        if language == 'ts':
            count('flake_masking', r'\btest\s*\([^;]*?\{[^{}]*\b(?:retries|reruns)\s*:')
        count('test_double', r'\b(?:rui|globalThis\s*\.\s*rui)\s*\.\s*\w+\s*=(?!=)|\bglobalThis\s*\.\s*rui\s*=(?!=)')
        if language == 'ts':
            for match in re.finditer(r'\b(?:vi|jest|sinon)\s*\.\s*(?:mock|spyOn|stub)\s*\(', code):
                tail = source[match.end():match.end() + 120]
                if re.match(r'\s*(?:rui\b|["\'][^"\']*rui(?:/|["\']))', tail):
                    counts['test_double'] += 1
    return {rule: counts[rule] for rule in RULES if counts[rule]}


def inventory_sources(sources):
    return {path: result for path, source in sorted(sources.items()) if target(path)
            if (result := inventory(source, path))}


def scan(root=ROOT):
    return {(path, rule): count for path, rules in inventory_sources(read_sources(root)).items()
            for rule, count in rules.items()}


def check(found, allowed):
    """Compare flat (path, rule) counts with the exact checked-in allowance."""
    failures = []
    for key in sorted(set(found) | set(allowed)):
        observed, budget = found.get(key, 0), allowed.get(key, 0)
        if observed != budget:
            path, rule = key
            action = f'lower the allowance to {observed}' if observed < budget else 'remove the added violations'
            failures.append(f'{path}: {rule}: observed {observed}, allowance {budget}; {action}')
    return failures


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True, stderr=subprocess.PIPE)


def trusted_sources(root, base):
    paths = git(root, 'ls-tree', '-r', '--name-only', base).splitlines()
    paths = [p for p in paths if target(p)]
    proc = subprocess.run(['git', '-C', str(root), 'cat-file', '--batch'],
                          input=''.join(f'{base}:{p}\n' for p in paths).encode(),
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    stream = io.BytesIO(proc.stdout)
    sources = {}
    for path in paths:
        header = stream.readline().split()
        if len(header) != 3 or header[1] != b'blob':
            raise ValueError(f'cannot read trusted source {path}: {header!r}')
        sources[path] = stream.read(int(header[2])).decode()
        if stream.read(1) != b'\n':
            raise ValueError(f'invalid git batch response for {path}')
    return sources


def read_sources(root=ROOT):
    root = Path(root)
    excluded = {'.git', '.zig-cache', 'zig-cache', 'zig-out', 'node_modules', '__pycache__', '.venv'}
    return {path.relative_to(root).as_posix(): path.read_text()
            for path in root.rglob('*')
            if path.is_file() and not excluded.intersection(path.relative_to(root).parts)
            and target(path.relative_to(root).as_posix())}


def validate(value):
    if not isinstance(value, dict):
        raise ValueError('allowance must be an object')
    for path, rules in value.items():
        if not isinstance(path, str) or not target(path) or not isinstance(rules, dict) or not rules:
            raise ValueError(f'invalid allowance path or rules: {path!r}')
        if any(k not in RULES or type(v) is not int or v <= 0 for k, v in rules.items()):
            raise ValueError(f'invalid allowance counts: {path}')
    return value


def compare(actual, allowed, trusted):
    def nested(value):
        result = {}
        for key, count in value.items():
            if isinstance(key, tuple):
                path, rule = key
                result.setdefault(path, {})[rule] = count
            else:
                result[key] = count
        return result
    actual, allowed, trusted = map(nested, (actual, allowed, trusted))
    failures = []
    for path in sorted(set(actual) | set(allowed) | set(trusted)):
        for rule in RULES:
            observed = actual.get(path, {}).get(rule, 0)
            budget = allowed.get(path, {}).get(rule, 0)
            ceiling = trusted.get(path, {}).get(rule, 0)
            if observed != budget:
                failures.append(f'{path}: {rule}: observed {observed}, allowance {budget}')
            if budget > ceiling:
                failures.append(f'{path}: {rule}: allowance {budget} exceeds trusted {ceiling}')
    return failures


def trusted_allowance(root=ROOT):
    base = git(root, 'merge-base', 'HEAD', 'origin/main').strip()
    paths = git(root, 'ls-tree', '--name-only', base, '--', ALLOWANCE).strip()
    if paths:
        return validate(json.loads(git(root, 'show', f'{base}:{ALLOWANCE}')))
    return inventory_sources(trusted_sources(root, base))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seed', action='store_true', help='print the trusted origin/main allowance')
    args = parser.parse_args(argv)
    trusted = trusted_allowance()
    if args.seed:
        print(json.dumps(trusted, indent=2, sort_keys=True))
        return 0
    allowed = validate(json.loads((ROOT / ALLOWANCE).read_text()))
    actual = scan(ROOT)
    flat_allowed = {(path, rule): count for path, rules in allowed.items() for rule, count in rules.items()}
    failures = check(actual, flat_allowed)
    failures.extend(message for message in compare(allowed, allowed, trusted) if 'exceeds trusted' in message)
    print('\n'.join(failures))
    return int(bool(failures))


if __name__ == '__main__':
    raise SystemExit(main())
