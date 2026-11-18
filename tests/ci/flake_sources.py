#!/usr/bin/env python3
"""Inventory recognizable flake sources and ratchet their exact per-file counts.

Bootstrap from the origin/main merge base when the allowance does not yet exist.
Run with --seed to print the trusted bootstrap as JSON.
"""
import argparse
import ast
from collections import Counter
from functools import lru_cache
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
    counts['fixed_sleep'] = sum(sleep_ordering([(path, source)]).values())
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
        if 'fixed_sleep' in rules:
            parse_sleep_allowance({path: rules['fixed_sleep']})
        if any(k not in RULES or (not (k == 'fixed_sleep' and isinstance(v, dict)) and (type(v) is not int or v <= 0)) for k, v in rules.items()):
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
            if rule == 'fixed_sleep':
                continue
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
    data = json.loads(git(root, 'show', f'{base}:{ALLOWANCE}')) if paths else {}
    if paths:
        legacy = isinstance(data, dict) and any(
            isinstance(rules, dict) and type(rules.get('fixed_sleep')) is int
            for rules in data.values())
        if not legacy:
            return validate(data)
        stripped = {}
        for path, rules in data.items():
            if not isinstance(rules, dict):
                raise ValueError(f'invalid allowance rules: {path!r}')
            rules = dict(rules)
            if type(rules.get('fixed_sleep')) is int:
                if rules['fixed_sleep'] <= 0:
                    raise ValueError(f'invalid legacy fixed sleep count: {path}')
                del rules['fixed_sleep']
            if rules:
                stripped[path] = rules
        validate(stripped)
    sources = trusted_sources(root, base)
    inventory = inventory_sources(sources)
    if paths:
        inventory = stripped
    else:
        for rules in inventory.values():
            rules.pop('fixed_sleep', None)
    old = {}
    harness = sources.get('tests/ci/test_harness_contracts.py')
    if harness:
        matches = [node.value for node in ast.parse(harness).body if isinstance(node, ast.Assign)
                   and getattr(node.targets[0], 'id', None) == 'SLEEP_ORDERED']
        if len(matches) != 1:
            raise ValueError('trusted base has no single SLEEP_ORDERED allowlist')
        old = ast.literal_eval(matches[0])
    found = sleep_ordering(sources.items())
    for key in set(found) | set(old):
        count = max(found.get(key, 0), old.get(key, (0, ''))[0])
        reason = old.get(key, (0, 'Existing fixed sleep recorded at migration'))[1]
        inventory.setdefault(key[0], {}).setdefault('fixed_sleep', {})[key[1]] = [count, reason]
    return validate({path: rules for path, rules in inventory.items() if rules})


ZIG_POLL_HELPER = ("src/testing/poll.zig", "waitUntil")
PYTHON_POLL_HELPER = ("tests/integration/host_process.py", "wait_for")
ZIG_SLEEP = re.compile(r"\b(?:sleep|nanosleep|usleep)\s*\(|\bpoll\(\s*&\[_\][\w.]*pollfd\{\}\s*,\s*0\s*,")
ZIG_SKIPPED = re.compile(r'//[^\n]*|\\\\[^\n]*|"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'')
ZIG_TEST = re.compile(r'\s*test\s*(?:"((?:\\.|[^"\\])*)"|(\w+))?\s*')
ZIG_DECLARATION = re.compile(r"\b(?:fn|const|var)\s+(\w+)")
ZIG_EXPRESSION = re.compile(r"(?:\.|\berror)\s*$")
ZIG_TEST_ONLY = re.compile(r"(?:^|/)(?:tests|testing)/|tests?\.zig$")


@lru_cache(maxsize=512)
def zig_blocks(text):
    code = ZIG_SKIPPED.sub(lambda match: " " * len(match[0]), text)
    names = ZIG_SKIPPED.sub(lambda match: match[0] if match[0][0] == '"' else " " * len(match[0]), text)
    tests, declarations, open_blocks, head, top_head = [], [], [], 0, 0
    for index, char in enumerate(code):
        if char == "{":
            open_blocks.append((head, index))
            head = index + 1
        elif char == "}":
            block_head, start = open_blocks.pop()
            if test := ZIG_TEST.fullmatch(names, block_head, start):
                tests.append((start, index, test[1] or test[2] or "<unnamed test>"))
            if not open_blocks and not ZIG_EXPRESSION.search(code, top_head, start):
                if declaration := ZIG_DECLARATION.search(code, top_head, start):
                    declarations.append((start, index, declaration[1]))
                top_head = index + 1
            head = index + 1
        elif char == ";":
            head = index + 1
            if not open_blocks:
                top_head = index + 1
    return code, tuple(tests), tuple(declarations)


def zig_sleep_ordering(path, text):
    code, tests, declarations = zig_blocks(text)
    test_only = ZIG_TEST_ONLY.search(path) is not None
    offenses = Counter()
    for match in ZIG_SLEEP.finditer(code):
        if code[:match.start()].rstrip().endswith("fn"):
            continue
        within = [name for start, end, name in tests if start < match.start() < end]
        if within:
            offenses[(path, within[-1])] += 1
        elif test_only:
            offenses[(path, next((name for start, end, name in declarations if start < match.start() < end),
                                 "<top level>"))] += 1
    offenses.pop(ZIG_POLL_HELPER, None)
    return offenses


@lru_cache(maxsize=512)
def sleep_python_tree(text):
    return ast.parse(text)


def python_sleep_ordering(path, text):
    offenses = Counter()

    def visit(node, name):
        for child in ast.iter_child_nodes(node):
            child_name = name
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                if name is None:
                    child_name = child.name
                elif isinstance(node, ast.ClassDef) and "." not in name:
                    child_name = f"{name}.{child.name}"
            elif (isinstance(child, ast.Call) and isinstance(child.func, ast.Attribute) and child.func.attr == "sleep"
                  and getattr(child.func.value, "id", None) in ("time", "asyncio")):
                offenses[(path, name or "<module>")] += 1
            visit(child, child_name)

    visit(sleep_python_tree(text), None)
    offenses.pop(PYTHON_POLL_HELPER, None)
    return offenses


def sleep_ordering(sources):
    offenses = Counter()
    for path, text in sources:
        if path.endswith(".zig"):
            offenses += zig_sleep_ordering(path, text)
        elif path.startswith("tests/") and path.endswith(".py"):
            offenses += python_sleep_ordering(path, text)
        elif path.endswith(".test.ts"):
            code = mask(text, "ts")
            count = len(re.findall(r'\b(?:await\s+setTimeout\s*\(|(?:await\s+)?new\s+Promise\s*\([^;]*?\bsetTimeout\s*\()', code))
            if count:
                offenses[(path, "<file>")] = count
    return offenses


def sleep_keys(sources):
    keys = set()
    for path, text in sources:
        if path.endswith(".zig") and target(path):
            _, tests, declarations = zig_blocks(text)
            keys.update((path, name) for _, _, name in tests)
            if ZIG_TEST_ONLY.search(path):
                keys.update((path, name) for _, _, name in declarations)
        elif path.startswith("tests/") and path.endswith(".py"):
            for node in sleep_python_tree(text).body:
                if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                    keys.add((path, node.name))
                if isinstance(node, ast.ClassDef):
                    keys.update((path, f"{node.name}.{child.name}") for child in node.body
                                if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)))
    return keys


def tree_sources(root=ROOT):
    return iter(read_sources(root).items())


def review_base_sources(root=ROOT):
    base = git(root, "merge-base", "HEAD", "origin/main").strip()
    return iter(trusted_sources(root, base).items())


def review_base_ceiling(root=ROOT, sources=None):
    sources = sources or dict(review_base_sources(root))
    ceiling = sleep_ordering(sources.items())
    base = git(root, "merge-base", "HEAD", "origin/main").strip()
    try:
        data = json.loads(git(root, "show", f"{base}:{ALLOWANCE}"))
    except subprocess.CalledProcessError:
        data = {}
    has_allowance = bool(git(root, 'ls-tree', '--name-only', base, '--', ALLOWANCE).strip())
    if has_allowance and all(not isinstance(rules.get('fixed_sleep'), int) for rules in data.values()):
        for key, (count, _) in sleep_allowances(data).items():
            ceiling[key] = max(ceiling[key], count)
        return ceiling
    allowlists = [node.value for node in ast.parse(sources["tests/ci/test_harness_contracts.py"]).body
                  if isinstance(node, ast.Assign) and getattr(node.targets[0], "id", None) == "SLEEP_ORDERED"]
    if len(allowlists) != 1:
        raise AssertionError("review base has no single SLEEP_ORDERED allowlist")
    for key, (count, _) in ast.literal_eval(allowlists[0]).items():
        ceiling[key] = max(ceiling[key], count)
    return ceiling


def moved_ceiling(offenses, trusted, present, base):
    ceiling = Counter(trusted)
    for (path, name), count in trusted.items():
        if (path, name) in offenses or (path, name) in present:
            continue
        moved = [key for key in offenses if key[1] == name and key not in trusted and key not in base]
        if len(moved) == 1:
            ceiling[moved[0]] = max(ceiling[moved[0]], count)
    return ceiling


def sleep_allowlist_problems(offenses, allowed, trusted):
    problems = []
    for key in sorted(set(offenses) | set(allowed)):
        found, listed = offenses.get(key, 0), allowed.get(key, (0, ""))[0]
        if found > listed:
            problems.append(f"{key}: {found} test sleep(s) outside wait_for/waitUntil, {listed} allowed; "
                            "poll through the helper, gate on an event, or list it with a reason")
        elif found < listed:
            problems.append(f"{key}: {listed} allowed but {found} found; lower or remove its allowlist entry")
        if listed > trusted.get(key, 0):
            problems.append(f"{key}: allowance {listed} exceeds the {trusted.get(key, 0)} found at the "
                            "review base; the allowlist only shrinks")
    return problems





def parse_sleep_allowance(value):
    if not isinstance(value, dict):
        raise ValueError("fixed sleep test allowances must be an object")
    result = {}
    for path, entries in value.items():
        if not isinstance(path, str) or not target(path) or not isinstance(entries, dict) or not entries:
            raise ValueError(f"invalid fixed sleep allowance path: {path!r}")
        for name, entry in entries.items():
            if (not isinstance(name, str) or not name or not isinstance(entry, list) or len(entry) != 2
                    or type(entry[0]) is not int or entry[0] <= 0 or not isinstance(entry[1], str)
                    or not entry[1].strip() or "\n" in entry[1]):
                raise ValueError(f"invalid fixed sleep allowance: {path}: {name!r}")
            result[path, name] = tuple(entry)
    return result

def sleep_allowances(data):
    return parse_sleep_allowance({path: rules["fixed_sleep"] for path, rules in data.items()
                                  if isinstance(rules.get("fixed_sleep"), dict)})

def load_sleep_allowance(root=ROOT):
    return sleep_allowances(validate(json.loads((root / ALLOWANCE).read_text())))

def main(argv=None, root=ROOT):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seed', action='store_true', help='print the trusted origin/main allowance')
    args = parser.parse_args(argv)
    trusted = trusted_allowance(root)
    if args.seed:
        print(json.dumps(trusted, indent=2, sort_keys=True))
        return 0
    allowed = validate(json.loads((root / ALLOWANCE).read_text()))
    actual = scan(root)
    actual = {key: count for key, count in actual.items() if key[1] != 'fixed_sleep'}
    flat_allowed = {(path, rule): count for path, rules in allowed.items() for rule, count in rules.items()
                    if rule != 'fixed_sleep'}
    failures = check(actual, flat_allowed)
    failures.extend(message for message in compare(allowed, allowed, trusted) if 'exceeds trusted' in message)
    tree = list(tree_sources(root))
    base = dict(review_base_sources(root))
    offenses = sleep_ordering(tree)
    ceiling = moved_ceiling(offenses, review_base_ceiling(root, sources=base), sleep_keys(tree), sleep_keys(base.items()))
    failures.extend(sleep_allowlist_problems(offenses, sleep_allowances(allowed), ceiling))
    print('\n'.join(failures))
    return int(bool(failures))


if __name__ == '__main__':
    raise SystemExit(main())
