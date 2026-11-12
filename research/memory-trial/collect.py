"""Collect a small, local Host memory evidence bundle on macOS."""
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', required=True, type=pathlib.Path)
p.add_argument('--instruments', action='store_true')
a = p.parse_args()
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=False)

def run(*args):
    subprocess.run(args, cwd=root, check=True)

def capture(*args):
    return subprocess.check_output(args, cwd=root, text=True).strip()

# Build before copying, so the measured executable belongs to this checkout.
run('zig', 'build', '-Doptimize=ReleaseSafe')
binary = out / 'rui'
shutil.copy2(root / 'zig-out/bin/rui', binary)
run('xcrun', 'dsymutil', str(binary), '-o', str(out / 'rui.dSYM'))
with (out / 'types.txt').open('w') as f:
    subprocess.run(['xcrun', 'dwarfdump', '--regex', '--name=ExecutionSlot|CustodyRecord',
                    '--show-children', str(out / 'rui.dSYM')], check=True, stdout=f)
(out / 'source.patch').write_text(capture('git', 'diff', 'HEAD', '--', 'src', 'build.zig', 'build.zig.zon'))
shutil.copytree(pathlib.Path(__file__).parent, out / 'collector', ignore=shutil.ignore_patterns('__pycache__'))
metadata = {'commit': capture('git', 'rev-parse', 'HEAD'),
            'worktree_status': capture('git', 'status', '--short'),
            'zig': capture('zig', 'version'), 'platform': capture('uname', '-a'),
            'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'scope': '8 slots, one 100000-byte local HTTP answer; no production qualification'}
(out / 'provenance.json').write_text(json.dumps(metadata, indent=2))
for mode in ['baseline', 'logged']:
    args = [sys.executable, str(pathlib.Path(__file__).with_name('run.py')), str(binary), str(out / mode)]
    if mode == 'logged': args.append('--logging')
    run(*args)
if a.instruments:
    profile = out / 'rui-profile'
    shutil.copy2(binary, profile)
    entitlements = out / 'profile.entitlements'
    entitlements.write_text('<?xml version="1.0"?><plist version="1.0"><dict>'
                            '<key>com.apple.security.get-task-allow</key><true/></dict></plist>')
    run('codesign', '--force', '--sign', '-', '--entitlements', str(entitlements), str(profile))
    run(sys.executable, str(pathlib.Path(__file__).with_name('run.py')),
        str(profile), str(out / 'instruments'), '--instruments')
print(f'Evidence saved to {out}')
