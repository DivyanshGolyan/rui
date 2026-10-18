"""Compiler-discovered file closure for retained unit artifacts; unknown inputs fail closed."""
import json
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def closure(root, manifests, output, active=(), external=None, generated=None):
    if output in active:
        raise ValueError("Generated input cycle")
    if output not in manifests:
        raise ValueError(f"Unowned generated input {output}")
    if not manifests[output]:
        if generated is None or external is None or generated.is_symlink():
            raise ValueError(f"Unowned generated contents {output}")
        with generated.open('rb') as stream:
            value = hashlib.file_digest(stream, 'sha256').hexdigest()
        external['generated/' + value] = value
        return []
    files = set()
    for entry in manifests[output]:
        prefix, path = entry['prefix'], Path(entry['path'])
        if entry.get('directory') or entry.get('metadata'):
            raise ValueError(f"Unenumerated directory/metadata input {path}")
        if prefix == 4:
            source = root / path
        elif prefix == 0 and path.is_absolute():
            source = path
        elif prefix == 1 and external is not None:
            source = Path(shutil.which('zig')).resolve().parent / 'lib' / path
        elif prefix == 3 and path.parts[0] == 'b' and path.name == 'builtin.zig' and external is not None:
            source = Path(os.environ.get('ZIG_GLOBAL_CACHE_DIR', Path.home() / '.cache/zig')) / path
            with source.open('rb') as stream:
                external['builtin/' + path.as_posix()] = hashlib.file_digest(stream, 'sha256').hexdigest()
            continue
        elif prefix in (2, 3) and len(path.parts) >= 3 and path.parts[0] == 'o':
            cache = root / '.zig-cache' if prefix == 2 else Path(
                os.environ.get('ZIG_GLOBAL_CACHE_DIR', Path.home() / '.cache/zig'))
            files.update(closure(root, manifests, path.parts[1], (*active, output), external, cache / path))
            continue
        else:
            raise ValueError(f"Unowned input {prefix}:{path}")
        if source.is_symlink():
            raise ValueError(f"Unowned input {source}")
        if source.is_relative_to(root / '.zig-cache/o'):
            generated = source.relative_to(root / '.zig-cache/o').parts[0]
            files.update(closure(root, manifests, generated, (*active, output), external, source))
        elif external is not None and (prefix == 1 or source.is_relative_to(root / 'zig-pkg')):
            label = ('compiler/' + path.as_posix() if prefix == 1 else source.relative_to(root).as_posix())
            with source.open('rb') as stream:
                external[label] = hashlib.file_digest(stream, 'sha256').hexdigest()
        elif external is not None and any(source.is_relative_to(base) for base in
                                         (Path('/usr/include'), Path('/usr/lib'), Path('/Applications/Xcode.app'))):
            with source.open('rb') as stream:
                external['native/' + source.as_posix()] = hashlib.file_digest(stream, 'sha256').hexdigest()
        elif source.is_relative_to(root):
            files.add(source.relative_to(root).as_posix())
        else:
            raise ValueError(f"Unowned input {source}")
    return sorted(files)


def collect(outputs):
    root = Path.cwd().resolve()
    # Use the compiler's supported decoder, matching discovered_hash to the
    # emitted o/<digest>/ path. Never parse binary manifests or replicate hashes.
    manifests = sorted(path for path in Path('.zig-cache/h').glob('*')
                       if re.fullmatch('[0-9a-f]{32}', path.name))
    with tempfile.TemporaryDirectory() as directory:
        decoded = Path(directory) / 'cache.zon'
        with decoded.open('wb') as stream:
            subprocess.run(['zig', 'cache-cat', *map(str, manifests)], stdout=stream, check=True)
        data = subprocess.check_output(['zig', 'run', 'tests/ci/cache_inputs.zig', '--', str(decoded)])
    rows = [json.loads(line) for line in data.splitlines()]
    index = {}
    for row in rows:
        key = row['discovered_hash']
        # Equal output digests with disagreeing inventories are not proof.
        if key in index and index[key] != row['files']:
            raise ValueError(f'Ambiguous compiler input manifest {key}')
        index[key] = row['files']
    result = {}
    for name, output in outputs:
        path = Path(output).resolve().relative_to(root / '.zig-cache/o')
        try:
            external = {}
            files = closure(root, index, path.parts[0], external=external)
            result[name] = dict(files=files, external=external)
        except ValueError as error:
            result[name] = dict(unavailable=str(error))
    return result


if __name__ == '__main__':
    destination, *pairs = sys.argv[1:]
    try:
        result = collect(list(zip(pairs[::2], pairs[1::2], strict=True)))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        # Collection is an optional optimization, never authority to skip tests.
        result = {'unavailable': str(error)}
    Path(destination).write_text(json.dumps(result, sort_keys=True))
