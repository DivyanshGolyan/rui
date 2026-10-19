"""Observe only the private pane's tmux keys, then exec the exact Rui build."""
import argparse
import hashlib
import importlib.machinery
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import time
import traceback

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[3]
CACHE = ROOT / '.amp/in/prefix-diagnosis-cache'
HELPER = ROOT / '.cursor/skills/verify-rui/scripts/verify-rui'
os.environ['VERIFY_RUI_CACHE'] = str(CACHE)
loader = importlib.machinery.SourceFileLoader('environment_helper', str(HELPER))
spec = importlib.util.spec_from_loader(loader.name, loader)
helper = importlib.util.module_from_spec(spec)
loader.exec_module(helper)
HINT = 'In tmux, Shift-Enter sends · Alt-J adds a line'


def wait(check):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        found = check()
        if found:
            return found
        time.sleep(.025)
    raise TimeoutError('environment control condition absent')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--sha', required=True)
    parser.add_argument('--label', required=True)
    args = parser.parse_args()
    out = HERE / ('tmux-environment-' + args.label)
    out.mkdir(exist_ok=False)
    summary = {'sha': args.sha, 'helper_sha256': hashlib.sha256(HELPER.read_bytes()).hexdigest(), 'rows': []}

    def call(*argv):
        result = subprocess.run([sys.executable, str(HELPER), *map(str, argv)], capture_output=True, text=True,
                                timeout=120, env={**os.environ, 'VERIFY_RUI_UNTRUSTED': 'must-not-reach-target'})
        helper.append_jsonl(out / 'commands.jsonl', {'argv': list(map(str, argv)), 'rc': result.returncode,
                                                   'stdout': result.stdout, 'stderr': result.stderr})
        assert result.returncode == 0, result.stderr
        return result.stdout

    run = None
    try:
        call('new', args.sha, '--seed', '0', '--label', args.label, '--run-root', out / 'run')
        run = helper.Run(out / 'run')
        call('doctor', run.root, '--expect-sha', args.sha)
        for surface, no_tap in [('pty', False), ('tmux-detached', False), ('tmux-attached', False),
                                ('tmux-detached', True), ('tmux-attached', True)]:
            name = surface + ('-direct' if no_tap else '-tap')
            row = {'surface': surface, 'no_tap': no_tap, 'passed': False}
            try:
                env_file = out / (name + '-inner-environment.json')
                observer = ('import json,os,pathlib,sys; '
                            'pathlib.Path(sys.argv[1]).write_text(json.dumps({'
                            '"TMUX":os.environ.get("TMUX"),"TMUX_PANE":os.environ.get("TMUX_PANE"),'
                            '"foreign_present":"VERIFY_RUI_UNTRUSTED" in os.environ})); '
                            'os.execv(sys.argv[2],sys.argv[2:])')
                call('term', run.root, name, '--surface', surface, '--size', '100x30',
                     *(['--no-tap'] if no_tap else []), '--', sys.executable, '-c', observer, str(env_file),
                     str(run.rui), 'session', 'resume', '--store', str(run.store), '--', 'demo')
                wait(env_file.exists)
                row['inner_environment'] = json.loads(env_file.read_text())
                term = run.term_dir(name)
                record = helper.term_record(run, name)

                def screen():
                    if no_tap:
                        return run.tmux('capture-pane', '-p', '-t', record['tmux_target']).stdout
                    frames = helper.read_jsonl(term / 'frames.jsonl')
                    return frames[-1]['screen'] if frames else ''

                wait(lambda: '›' in screen())
                call('send', run.root, name, '--text', 'x')
                row['draft_frame'] = wait(lambda: (s := screen()) if '› x' in (s := screen()) else None)
                inner = row['inner_environment']
                assert not inner['foreign_present']
                if surface == 'pty':
                    assert inner['TMUX'] is None and inner['TMUX_PANE'] is None, inner
                    assert HINT not in row['draft_frame']
                else:
                    pane = run.tmux('display-message', '-p', '-t', record['tmux_target'],
                                    '#{socket_path},#{pid},#{session_id} #{pane_id}').stdout.strip().split()
                    row['actual_private_pane'] = pane
                    expected = pane[0].replace(',$', ',')
                    assert inner['TMUX'] == expected and inner['TMUX_PANE'] == pane[1], (inner, pane)
                    assert HINT in row['draft_frame'], row['draft_frame']
                call('send', run.root, name, '--hex', '7f')
                row['empty_frame'] = wait(lambda: (s := screen()) if '› x' not in (s := screen()) and HINT not in s else None)
                row['passed'] = True
            except BaseException:
                row['failure'] = traceback.format_exc()
            finally:
                if (run.term_dir(name) / 'term.json').exists():
                    call('send', run.root, name, '--hex', '03')
                    if no_tap:
                        wait(lambda: run.tmux('display-message', '-p', '-t', record['tmux_target'], '#{pane_dead}').stdout.strip() == '1')
                    else:
                        wait((run.term_dir(name) / 'exit.json').exists)
                summary['rows'].append(row)
                (out / 'summary.json').write_text(json.dumps(summary, indent=1))
        assert all(r['passed'] for r in summary['rows']), summary['rows']
    finally:
        if run:
            summary['cleanup'] = call('cleanup', run.root)
        (out / 'summary.json').write_text(json.dumps(summary, indent=1))
    print(json.dumps(summary, indent=1))


if __name__ == '__main__':
    main()
