#!/usr/bin/env python3
"""Disposable qualification harness, never part of the docs landing candidate."""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import resource
import shlex
import stat
import subprocess
import sys


def snapshot(root):
    result = {}
    for path in sorted(root.rglob('*')):
        info = path.lstat()
        entry = {'mode': stat.S_IMODE(info.st_mode)}
        if path.is_symlink():
            entry['link'] = os.readlink(path)
        elif path.is_file():
            entry['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        elif path.is_dir():
            entry['directory'] = True
        else:
            # A stopped Host can leave its Unix socket. It is not saved work,
            # and cp need not copy sockets on both supported operating systems.
            assert stat.S_ISSOCK(info.st_mode), path
            continue
        result[str(path.relative_to(root))] = entry
    return result


def qualify(previous, candidate):
    import previous_release_upgrade as upgrade
    original_install = upgrade.install
    previous_artifact = None
    exercised = []
    source = (candidate / 'README.md').read_text()
    section = source.split('### Start fresh after a Store format change\n', 1)[1].split('<a id=', 1)[0]
    blocks = re.findall(r'```sh\n(.*?)```', section, re.S)
    assert len(blocks) == 4
    for block in blocks:
        subprocess.run(['bash', '-n'], input=block, text=True, check=True)

    def installed(checkout):
        nonlocal previous_artifact
        binary = original_install(checkout)
        if previous_artifact is None:
            previous_artifact = binary.resolve()
            return binary
        root = Path(os.environ['HOME']).parent
        store = root / 'store'
        marker = store / '.backup-witness'
        marker.mkdir()
        (marker / 'empty').mkdir()
        (marker / 'saved').write_bytes(b'Full directory includes hidden files and empty directories.\n')
        same_format = upgrade.supported_format(previous) == upgrade.supported_format(candidate)
        paths = root / 'recipe-paths'
        baseline = root / 'recipe-before.json'
        environment = dict(os.environ, QUAL_PYTHON=sys.executable,
                           QUAL_SCRIPT=str(Path(__file__).resolve()),
                           QUAL_BASELINE=str(baseline), QUAL_PATHS=str(paths))
        first = blocks[0].replace('STORE="/absolute/path/from/the/error"', 'STORE=' + shlex.quote(str(store)))
        script = '\n'.join([
            'set -euo pipefail', 'printf "Recipe phase: initial status\\n"', first,
            'if "$RUI" host status --store "$STORE" | grep -q "Host: ready"; then',
            'printf "Ready probe pipeline statuses: %s\\n" "${PIPESTATUS[*]}"',
            'printf "Recipe phase: stopping original Host\\n"', blocks[1],
            'else', 'printf "Ready probe declined; pipeline statuses: %s\\n" "${PIPESTATUS[*]}"', 'fi',
            'printf "Recipe phase: waiting for original ownership release\\n"',
            'until "$RUI" host status --store "$STORE" | grep -q "Host: unavailable"; do sleep 0.025; done',
            'printf "Recipe phase: stopped Store snapshot and backup\\n"',
            '"$QUAL_PYTHON" "$QUAL_SCRIPT" snapshot "$STORE" "$QUAL_BASELINE"',
            blocks[2], 'printf "Recipe phase: fresh Store start and selection\\n"', blocks[3],
            'printf "%s\\n%s\\n" "$BACKUP" "$FRESH_STORE" > "$QUAL_PATHS"',
            '"$RUI" host status',
        ])
        original_inode = store.stat().st_ino
        try:
            if same_format:
                # Exercise the running-Host block with a compatible retained
                # installation. Legacy input is already stopped instead.
                subprocess.run([previous_artifact, 'host', 'start', '--store', store], check=True, timeout=16)
                probe = subprocess.run(['bash', '-c', '''set -o pipefail
bad=0
for ((i=0; i<100; i++)); do
  if "$1" host status --store "$2" | grep -q "Host: ready"; then :
  else printf 'Ready pipeline misclassified: %s\n' "${PIPESTATUS[*]}"; ((bad++)); fi
done
printf 'Diagnostic ready pipeline misclassifications: %s/100\n' "$bad"
test "$bad" -eq 0
''', 'ready-pipeline-probe', str(binary), str(store)], capture_output=True, text=True, timeout=20)
                print(probe.stdout + probe.stderr, flush=True)
                assert probe.returncode == 0, 'ready status pipeline can skip the required Host stop'
            try:
                result = subprocess.run(['bash', '-c', script], env=environment,
                                        capture_output=True, text=True, timeout=45)
            except subprocess.TimeoutExpired as error:
                print('Timed-out recipe output:\n' + (error.stdout or b'').decode(errors='replace')
                      + (error.stderr or b'').decode(errors='replace'), flush=True)
                raise
            print(result.stdout + result.stderr, flush=True)
            assert result.returncode == 0, result
            backup_parent, fresh = (Path(value) for value in paths.read_text().splitlines())
            backup = backup_parent / 'store'
            expected = json.loads(baseline.read_text())
            assert stat.S_IMODE(backup_parent.stat().st_mode) == 0o700
            assert snapshot(backup) == expected, 'full backup differs from stopped source'
            assert snapshot(store) == expected, 'fresh-start recipe changed original files'
            assert store.stat().st_ino == original_inode, 'original Store was renamed or replaced'
            assert fresh != store and fresh != backup and not fresh.is_relative_to(store)
            assert f'Store: {fresh}\n' in result.stdout, 'fresh Store was not selected as default'
            listed = subprocess.run([binary, 'sessions', '--store', fresh, '--all'],
                                    capture_output=True, text=True, check=True, timeout=5)
            assert 'No configured Sessions in this scope' in listed.stdout, listed.stdout
            upgrade.stop_detached(binary, fresh)

            # Probe a separate copy, not the backup or original: compatible
            # bytes do not authorize opening the Store at a different path.
            probe = root / 'identity-probe'
            subprocess.run(['cp', '-R', '-p', str(backup), str(probe)], check=True)
            refused = subprocess.run([previous_artifact, 'serve', '--store', probe,
                                      '--active-capacity', '8', '--codex'],
                                     capture_output=True, text=True, timeout=5)
            assert refused.returncode != 0 and 'WrongStoreIdentity' in refused.stderr, refused
            assert snapshot(backup) == expected and snapshot(store) == expected

            # Explicit operator restoration in this disposable fixture only:
            # preserve the complete current directory before copying back.
            preserved = root / 'preserved-before-restoration'
            subprocess.run(['cp', '-R', '-p', str(store), str(preserved)], check=True)
            assert snapshot(preserved) == expected
            subprocess.run(['cp', '-R', '-p', str(backup) + '/.', str(store)], check=True)
            assert snapshot(store) == expected
            subprocess.run([previous_artifact, 'setup', '--store', store], check=True, timeout=5)
            report = dict(previous_format=upgrade.supported_format(previous),
                          candidate_format=upgrade.supported_format(candidate),
                          all_four_blocks_executed=same_format,
                          private_full_backup=True, original_untouched_by_recipe=True,
                          fresh_ready_and_default=True, fresh_has_no_imported_sessions=True,
                          copied_identity_refused=True, preserved_original_path_restoration=True,
                          backup_manifest_sha256=hashlib.sha256(baseline.read_bytes()).hexdigest(),
                          installed_candidate_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                          retained_compatible_sha256=hashlib.sha256(previous_artifact.read_bytes()).hexdigest())
            exercised.append(report)
            print('RECIPE PASS: ' + json.dumps(report, sort_keys=True), flush=True)
        finally:
            upgrade.dispose_all(
                lambda: upgrade.stop_detached(binary, store),
                *(lambda selected=path: upgrade.stop_detached(binary, selected)
                  for path in Path(os.environ['HOME']).glob('rui-store.*')),
            )
        return binary

    upgrade.install = installed
    sys.argv = ['previous_release_upgrade.py', str(previous), str(candidate)]
    try:
        # Existing owner proves exact saved answer/configuration, original-path
        # recovery, no replay and preserving unsupported-format refusal.
        upgrade.main()
    finally:
        upgrade.install = original_install
    assert len(exercised) == 1
    return exercised[0]


if __name__ == '__main__':
    if sys.argv[1] == 'snapshot':
        Path(sys.argv[3]).write_text(json.dumps(snapshot(Path(sys.argv[2])), sort_keys=True))
    else:
        previous, candidate = (Path(value).resolve() for value in sys.argv[1:])
        sys.path.insert(0, str(candidate / 'tests/integration'))
        head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=candidate, text=True).strip()
        assert head == os.environ['DOCS_CANDIDATE_SHA'], head
        os.environ.setdefault('ZIG_GLOBAL_CACHE_DIR', str(Path.home() / '.cache/zig'))
        resource.setrlimit(resource.RLIMIT_NOFILE, (256, resource.getrlimit(resource.RLIMIT_NOFILE)[1]))
        print('Native recipe qualification: ' + json.dumps(dict(
            source=head, system=platform.system(), machine=platform.machine(),
            nofile=resource.getrlimit(resource.RLIMIT_NOFILE),
            recipe_sha256=hashlib.sha256((candidate / 'README.md').read_bytes()).hexdigest(),
            harness_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())), flush=True)
        reports = [qualify(candidate, candidate), qualify(previous, candidate)]
        destination = Path(os.environ['RECIPE_EVIDENCE'])
        destination.mkdir(parents=True, exist_ok=True)
        (destination / 'recipe-results.json').write_text(json.dumps(dict(source=head, reports=reports), indent=2))
        print('PASS: native recipe, same-format control, legacy refusal and exact original-path recovery; disposable roots cleaned', flush=True)
